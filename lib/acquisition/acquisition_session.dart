import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../app/settings.dart';
import '../decode/crypto_codec.dart';
import '../decode/decode_pipeline.dart';
import '../decode/device_identity.dart';
import '../decode/headset_config.dart';
import '../domain/acquisition_health.dart';
import '../domain/acquisition_state.dart';
import '../domain/ble_uuids.dart';
import '../domain/samples.dart';
import '../sessions/dropbox_sync.dart';
import '../sessions/live_session_sync.dart';
import '../sessions/server_bookmark.dart';
import '../sinks/csv_sink.dart';
import '../sinks/lsl_sink.dart';
import '../sinks/network_sink.dart';
import '../sinks/sample_hub.dart';
import 'ble_fsm_policy.dart';
import 'session_subscriptions.dart';
import 'streaming_foreground_service.dart';

/// Owns the BLE acquisition FSM, decode pipeline, and sinks.
class AcquisitionSession {
  AcquisitionSession({
    AppSettings? initialSettings,
    Future<void> Function(AppSettings settings)? persistSettings,
    DropboxSync? dropboxSync,
    LiveSessionSync? liveSync,
    Future<BookmarkStoreState> Function()? loadBookmarks,
    Future<String?> Function(String bookmarkId)? readPassword,
  })  : _settings = initialSettings ?? const AppSettings(),
        _persistSettings = persistSettings {
    _preferredId = _settings.preferredDeviceId;
    _preferredName = _settings.preferredDeviceName;
    _hub = SampleHub(onHealth: _mutateHealth);
    _csv = CsvSink(hub: _hub);
    _lsl = LslSink(hub: _hub, onHealth: _mutateHealth);
    _network = NetworkSink(hub: _hub, onHealth: _mutateHealth);
    _liveSync = liveSync ??
        LiveSessionSync(
          dropbox: dropboxSync ?? DropboxSync(),
          loadBookmarks: loadBookmarks ??
              () async => const BookmarkStoreState(),
          readPassword: readPassword ?? ((_) async => null),
          onStatus: _onLiveSyncStatus,
        );
    _stateController.add(const AcquisitionIdle());
  }

  final Future<void> Function(AppSettings settings)? _persistSettings;
  late final LiveSessionSync _liveSync;

  final _stateController =
      StreamController<AcquisitionState>.broadcast(sync: true);
  final _identityResolver = DeviceIdentityResolver();
  final _decode = DecodePipeline();

  late final SampleHub _hub;
  late final CsvSink _csv;
  late final LslSink _lsl;
  late final NetworkSink _network;

  /// Scan-only listeners (`scanResults`). Never holds link/notify subs.
  final _scanSubs = SessionSubscriptions();

  /// Connection-state + characteristic notify listeners for an active link.
  final _linkSubs = SessionSubscriptions();

  StreamSubscription? _decodeSub;
  StreamSubscription? _scanActiveSub;
  Timer? _rateTimer;
  Timer? _reconnectTimer;

  AppSettings _settings;
  AcquisitionState _state = const AcquisitionIdle();
  AcquisitionHealth _health = const AcquisitionHealth();

  final Map<String, BluetoothDevice> _discovered = {};
  final Map<String, int> _rssi = {};
  BluetoothDevice? _device;
  String? _preferredName;
  String? _preferredId;
  DeviceIdentity? _identity;
  Uint8List? _keyBytes;
  int _eegResolutionBits = CryptoCodec.defaultEegResolutionBits;
  bool _acceptPackets = false;
  bool _userStopRequested = false;
  bool _autoConnectPreferred = false;
  bool _autoConnectClaimed = false;
  bool _pendingDiscoveredClear = false;
  int _reconnectAttempt = 0;
  int _eegWindow = 0;
  int _motionWindow = 0;
  int? _lastEegMonoUs;

  /// Bumped to invalidate in-flight connect/prepare/reconnect work.
  int _opEpoch = 0;

  Stream<AcquisitionState> get stateStream => _stateController.stream;
  AcquisitionState get state => _state;
  AcquisitionHealth get health => _health;
  SampleHub get hub => _hub;
  String? get preferredDeviceId => _preferredId;
  String? get preferredDeviceName => _preferredName;

  /// Test/diagnostic: whether link subscriptions are currently held.
  int get linkSubscriptionCountForTest => _linkSubs.length;

  /// Test/diagnostic: whether scan subscriptions are currently held.
  int get scanSubscriptionCountForTest => _scanSubs.length;

  Future<void> updateSettings(AppSettings settings) async {
    _settings = settings;
    _preferredId = settings.preferredDeviceId ?? _preferredId;
    _preferredName = settings.preferredDeviceName ?? _preferredName;
    if (_state is AcquisitionStreaming || _state is AcquisitionPreparing) {
      await _network.configure(
        settings: settings,
        deviceId: _identity?.btKeyHex,
      );
    }
  }

  Future<void> startScan({bool autoConnectPreferred = false}) async {
    if (!BleFsmPolicy.canStartScan(_state)) return;
    _bumpEpoch();
    await _cancelReconnect();
    await _stopScanRadio();
    // Soft-clear: keep prior devices visible until the first fresh callback.
    _pendingDiscoveredClear = true;
    _autoConnectPreferred = autoConnectPreferred;
    _autoConnectClaimed = false;
    _emit(
      AcquisitionScanning(
        devices: _buildDeviceList(),
        active: true,
        preferredId: _preferredId,
        health: _health,
      ),
    );

    try {
      final adapter = await _ensureAdapterReady();
      if (!adapter) return;

      await _seedAlreadyConnected();
      _publishScanDevices(clearError: true);

      await FlutterBluePlus.startScan(
        withServices: [
          Guid(EmotivBleUuids.control),
          Guid(EmotivBleUuids.serviceB),
        ],
        timeout: const Duration(seconds: 30),
        androidUsesFineLocation: true,
      );

      _scanActiveSub?.cancel();
      _scanActiveSub = FlutterBluePlus.isScanning.listen((scanning) {
        if (!scanning && _state is AcquisitionScanning) {
          final current = _state as AcquisitionScanning;
          if (current.active) {
            _emit(current.copyWith(active: false));
          }
        }
      });

      _scanSubs.add(
        FlutterBluePlus.scanResults.listen((results) {
          if (_pendingDiscoveredClear) {
            _discovered.clear();
            _rssi.clear();
            _pendingDiscoveredClear = false;
            try {
              for (final d in FlutterBluePlus.connectedDevices) {
                _considerScanResult(
                  d,
                  _rssi[d.remoteId.str] ?? 0,
                );
              }
            } catch (_) {}
          }
          for (final r in results) {
            _considerScanResult(
              r.device,
              r.rssi,
              advName: r.advertisementData.advName,
              serviceUuids: r.advertisementData.serviceUuids,
            );
          }
          _publishScanDevices(clearError: true);
          if (_autoConnectPreferred) {
            unawaited(_tryAutoConnectPreferred());
          }
        }),
      );
      _publishScanDevices(clearError: true);
    } catch (e) {
      await _stopScanRadio();
      _emitToScanningWithError('Scan failed: $e');
    }
  }

  /// Scan and connect to the last used headset when it appears.
  Future<void> reconnectPreferred() async {
    final id = _preferredId;
    if (id == null) {
      await startScan();
      return;
    }
    if (!BleFsmPolicy.canConnect(_state)) return;

    await _seedAlreadyConnected();
    final known = _discovered[id];
    if (known != null) {
      await connect(id);
      return;
    }
    await startScan(autoConnectPreferred: true);
  }

  Future<void> stopScan() async {
    await _stopScanRadio();
    _autoConnectPreferred = false;
    _autoConnectClaimed = false;
    _pendingDiscoveredClear = false;
    if (_state is AcquisitionScanning) {
      final current = _state as AcquisitionScanning;
      _emit(current.copyWith(active: false));
    }
  }

  Future<void> connect(String deviceId) async {
    if (!BleFsmPolicy.canConnect(_state)) return;

    final device = _discovered[deviceId];
    if (device == null) {
      _emitToScanningWithError('Unknown device id: $deviceId');
      return;
    }
    _preferredId = deviceId;
    _preferredName = device.platformName;
    _autoConnectPreferred = false;
    _autoConnectClaimed = false;
    _userStopRequested = false;
    _reconnectAttempt = 0;
    final epoch = _bumpEpoch();
    await _stopScanRadio();
    await _connectDevice(device, epoch: epoch);
  }

  Future<void> disconnect() async {
    _userStopRequested = true;
    _bumpEpoch();
    await _cancelReconnect();
    await _orderedTeardown(disconnectBle: true);
    _mutateHealth((h) => h.copyWith(clearBatteryPercent: true));
    _emit(AcquisitionIdle(health: _health));
    // Stop FGS after CSV flush/teardown so the process is not demoted mid-flush.
    await StreamingForegroundService.ensureStopped();
  }

  Future<void> flush() async {
    await _csv.flush();
  }

  Future<void> resetFromFailure() async {
    if (_state is AcquisitionFailed) {
      _emit(AcquisitionIdle(health: _health));
    }
  }

  Future<void> dispose() async {
    _userStopRequested = true;
    _bumpEpoch();
    await _cancelReconnect();
    await _stopScanRadio();
    await _orderedTeardown(disconnectBle: true);
    await StreamingForegroundService.ensureStopped();
    await _liveSync.dispose();
    await _decode.dispose();
    await _hub.dispose();
    await _stateController.close();
  }

  int _bumpEpoch() => ++_opEpoch;

  bool _isEpochCurrent(int epoch) => epoch == _opEpoch;

  Future<void> _connectDevice(
    BluetoothDevice device, {
    required int epoch,
  }) async {
    if (!_isEpochCurrent(epoch)) return;
    _emit(
      AcquisitionConnecting(
        deviceName: device.platformName,
        health: _health,
      ),
    );
    // Pin the process for connect+prepare+stream (kept through Reconnecting).
    await StreamingForegroundService.ensureStarted(device.platformName);
    try {
      // Drop any half-open OS link before a fresh connect attempt.
      try {
        await device.disconnect();
      } catch (_) {}
      if (!_isEpochCurrent(epoch)) return;

      await device.connect(
        timeout: const Duration(seconds: 15),
        license: License.nonprofit,
      );
      if (!_isEpochCurrent(epoch)) {
        try {
          await device.disconnect();
        } catch (_) {}
        return;
      }
      _device = device;
      await _prepareAndStream(
        device,
        epoch: epoch,
        resumeReconnectOnFailure: false,
      );
    } catch (e) {
      if (!_isEpochCurrent(epoch)) return;
      await _forceDisconnect(device);
      await _linkSubs.cancelAll();
      _device = null;
      _emitToScanningWithError('Connect failed: $e');
    }
  }

  Future<void> _prepareAndStream(
    BluetoothDevice device, {
    required int epoch,
    required bool resumeReconnectOnFailure,
  }) async {
    if (!_isEpochCurrent(epoch)) return;
    final name = device.platformName;
    _emit(
      AcquisitionPreparing(
        deviceName: name,
        sessionDir: _health.csvSessionPath ?? '',
        health: _health,
      ),
    );

    try {
      await _decode.start();
      if (!_isEpochCurrent(epoch)) return;
      _decode.resetSession();
      _mutateHealth((h) => h.copyWith(clearDecodeMessage: true));
      await _decodeSub?.cancel();
      _decodeSub = _decode.results.listen(_onDecodeResult);

      // Discover + config/serial extract must happen before CSV/LSL so identity
      // can fall back to DIS serial when the advertising name is incomplete.
      await _armNotifications(device);
      if (!_isEpochCurrent(epoch)) return;

      _identity ??= _identityResolver.resolveFromName(name);
      _keyBytes = _identity!.keyBytes;
      await _rememberPreferred(
        id: device.remoteId.str,
        name: _identity!.deviceName,
      );
      if (!_isEpochCurrent(epoch)) return;

      // CSV is first-class but must never abort BLE arming.
      var sessionPath = '';
      try {
        await _liveSync.stop(timeout: const Duration(seconds: 5));
        final csvStart = await _csv.startSession(
          saveDirectory: _settings.saveDirectory,
          identity: _identity!,
          eegResolutionBits: _eegResolutionBits,
        );
        sessionPath = csvStart.sessionPath;
        _mutateHealth(
          (h) => h.copyWith(
            csvSessionPath: csvStart.sessionPath,
            csvMessage: csvStart.message,
            csvUsingFallback: csvStart.usedFallback,
          ),
        );
        unawaited(
          _liveSync.start(
            sessionPath: sessionPath,
            settings: _settings,
            flushCsv: _csv.flush,
          ),
        );
      } catch (e) {
        _mutateHealth(
          (h) => h.copyWith(
            csvMessage: 'CSV unavailable: $e (acquisition continues)',
            csvUsingFallback: true,
          ),
        );
      }

      await _lsl.start(
        enabled: _settings.lslEnabled,
        sourceId: device.remoteId.str,
      );
      await _network.configure(
        settings: _settings,
        deviceId: _identity!.btKeyHex,
      );
      if (!_isEpochCurrent(epoch)) return;

      _acceptPackets = true;
      _reconnectAttempt = 0;
      _startRateMonitor();

      // Arm link-lost only after Streaming is established so prepare races
      // cannot start reconnect while discovery is still running.
      _linkSubs.add(
        device.connectionState.listen((s) {
          if (s == BluetoothConnectionState.disconnected) {
            unawaited(_onLinkLost());
          }
        }),
      );

      if (!_isEpochCurrent(epoch)) return;
      final streamingName = name.isEmpty ? _identity!.deviceName : name;
      _emit(
        AcquisitionStreaming(
          deviceName: streamingName,
          sessionDir: sessionPath.isEmpty
              ? (_health.csvSessionPath ?? '(no csv)')
              : sessionPath,
          health: _health,
        ),
      );
      // Idempotent: covers reconnect path that skips Connecting.
      await StreamingForegroundService.ensureStarted(streamingName);
    } catch (e) {
      if (!_isEpochCurrent(epoch)) return;
      await _orderedTeardown(disconnectBle: true);
      if (resumeReconnectOnFailure && !_userStopRequested) {
        await _beginReconnectAttempt(
          name: name.isEmpty ? (_preferredName ?? 'device') : name,
        );
        return;
      }
      _emitToScanningWithError('Prepare failed: $e');
    }
  }

  Future<void> _armNotifications(BluetoothDevice device) async {
    final services = await device.discoverServices();
    BluetoothCharacteristic? eegChar;
    BluetoothCharacteristic? motionChar;
    BluetoothCharacteristic? serviceBControl;
    BluetoothCharacteristic? headsetConfigChar;
    BluetoothCharacteristic? disSerialChar;
    BluetoothCharacteristic? batteryChar;

    for (final service in services) {
      for (final c in service.characteristics) {
        final id = c.uuid.toString();
        if (EmotivBleUuids.isEeg(id)) {
          // Prefer service A's EEG characteristic when both are present.
          if (eegChar == null || id.toUpperCase() == EmotivBleUuids.eeg) {
            eegChar = c;
          }
        } else if (EmotivBleUuids.isMotion(id)) {
          motionChar = c;
        } else if (EmotivBleUuids.isServiceBControl(id)) {
          serviceBControl = c;
        } else if (EmotivBleUuids.isHeadsetConfig(id)) {
          headsetConfigChar = c;
        } else if (EmotivBleUuids.isBatteryLevel(id)) {
          batteryChar = c;
        } else if (_isDisSerial(id)) {
          disSerialChar = c;
        }
      }
    }

    if (eegChar == null) {
      throw StateError('EEG characteristic not found');
    }

    _identity = _identityResolver.tryResolveFromName(device.platformName);
    if (_identity == null && disSerialChar != null) {
      try {
        final raw = await disSerialChar.read();
        final serial = String.fromCharCodes(raw).trim();
        if (serial.isNotEmpty) {
          _identity = _identityResolver.resolveFromSerialHex(
            device.platformName.isEmpty ? serial : device.platformName,
            serial.replaceAll(RegExp(r'[^A-Fa-f0-9]'), ''),
          );
        }
      } catch (_) {}
    }
    if (_identity == null) {
      throw StateError(
        'Could not resolve headset serial from name or DIS',
      );
    }

    _eegResolutionBits = CryptoCodec.defaultEegResolutionBits;
    if (headsetConfigChar != null) {
      try {
        final bytes = await headsetConfigChar.read();
        final config = HeadsetConfig.parse(bytes);
        if (config?.eegResolutionBits != null) {
          _eegResolutionBits = config!.eegResolutionBits!;
        }
      } catch (_) {}
    }

    // The official Android app writes 02 1E to the service-B control
    // characteristic during discovery, when the headset exposes it.
    if (serviceBControl != null) {
      try {
        await serviceBControl.write(
          EmotivBleUuids.serviceBControlInit,
          withoutResponse: false,
        );
      } catch (_) {}
    }

    final eegUuid = eegChar.uuid.toString();
    await eegChar.setNotifyValue(true);
    _linkSubs.add(
      eegChar.lastValueStream.listen((data) {
        if (!_acceptPackets || data.isEmpty) return;
        _enqueueRaw(PacketKind.eeg, data, characteristicUuid: eegUuid);
      }),
    );

    if (motionChar != null) {
      final motionUuid = motionChar.uuid.toString();
      await motionChar.setNotifyValue(true);
      _linkSubs.add(
        motionChar.lastValueStream.listen((data) {
          if (!_acceptPackets || data.isEmpty) return;
          _enqueueRaw(
            PacketKind.motion,
            data,
            characteristicUuid: motionUuid,
          );
        }),
      );
    }

    // Battery Level (`0x2A19`): optional BAS notify; missing is non-fatal.
    if (batteryChar != null) {
      try {
        final initial = await batteryChar.read();
        _applyBatteryPayload(initial);
      } catch (_) {}
      try {
        await batteryChar.setNotifyValue(true);
        _linkSubs.add(
          batteryChar.lastValueStream.listen((data) {
            _applyBatteryPayload(data);
          }),
        );
      } catch (_) {}
    }

    // Enabling notifications is all that starts the stream; the official app
    // writes nothing to the EEG or motion characteristics.
  }

  void _applyBatteryPayload(List<int> data) {
    final percent = EmotivBleUuids.parseBatteryPercent(data);
    if (percent == null) return;
    _mutateHealth((h) => h.copyWith(batteryPercent: percent));
    _refreshStreamingHealth();
  }

  void _enqueueRaw(
    PacketKind kind,
    List<int> data, {
    required String characteristicUuid,
  }) {
    // Always capture non-empty notify payloads for offline re-decode, even
    // when length/kind gates would reject live decode.
    final bytes = Uint8List.fromList(data);
    final now = DateTime.now();
    // Headset clock is unavailable over BLE; wall + us is the receive timeline.
    final monoUs = now.microsecondsSinceEpoch;
    final packet = RawPacket(
      kind: kind,
      bytes: bytes,
      receiveMonoUs: monoUs,
      wallClock: now,
      characteristicUuid: characteristicUuid,
    );

    _hub.publishRaw(packet);

    final key = _keyBytes;
    final longEnough = kind == PacketKind.eeg
        ? bytes.length >= EmotivBleUuids.eegMinBytes
        : bytes.length >= EmotivBleUuids.motionMinBytes;
    if (key != null && longEnough) {
      _decode.submit(
        packet,
        keyBytes: key,
        eegResolutionBits: _eegResolutionBits,
      );
    }

    if (kind == PacketKind.eeg) {
      if (_lastEegMonoUs != null) {
        final gapUs = monoUs - _lastEegMonoUs!;
        // Expected ~7812 us at 128 Hz; flag large gaps (>50ms).
        if (gapUs > 50000) {
          _mutateHealth((h) => h.copyWith(gapCount: h.gapCount + 1));
        }
      }
      _lastEegMonoUs = monoUs;
    }
  }

  void _onDecodeResult(DecodeResult result) {
    switch (result) {
      case DecodeEegOk():
        _eegWindow++;
        _mutateHealth((h) => h.copyWith(eegPackets: h.eegPackets + 1));
      case DecodeMotionOk():
        _motionWindow++;
        _mutateHealth((h) => h.copyWith(motionPackets: h.motionPackets + 1));
      case DecodeFailed(:final error):
        _mutateHealth((h) => h.copyWith(decodeMessage: error.message));
    }
    _hub.publishDecode(result);
    _refreshStreamingHealth();
  }

  void _startRateMonitor() {
    _rateTimer?.cancel();
    _eegWindow = 0;
    _motionWindow = 0;
    _rateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _mutateHealth(
        (h) => h.copyWith(
          eegHz: _eegWindow.toDouble(),
          motionHz: _motionWindow.toDouble(),
        ),
      );
      _eegWindow = 0;
      _motionWindow = 0;
      _refreshStreamingHealth();
    });
  }

  void _refreshStreamingHealth() {
    final s = _state;
    if (s is AcquisitionStreaming) {
      _emit(s.copyWith(health: _health));
    } else if (s is AcquisitionReconnecting) {
      _emit(
        AcquisitionReconnecting(
          deviceName: s.deviceName,
          attempt: s.attempt,
          nextRetryIn: s.nextRetryIn,
          health: _health,
        ),
      );
    }
  }

  Future<void> _onLinkLost() async {
    if (_userStopRequested) return;
    // Only Streaming / Reconnecting may start recovery — never during
    // Connecting / Preparing (avoids overlapping teardown + reconnect).
    if (!BleFsmPolicy.canHandleLinkLost(_state)) return;

    final epoch = _bumpEpoch();
    final name = _preferredName ?? _device?.platformName ?? 'device';
    _acceptPackets = false;
    await _orderedTeardown(disconnectBle: false);
    if (!_isEpochCurrent(epoch)) return;

    await _beginReconnectAttempt(name: name, epoch: epoch);
  }

  /// Shared reconnect backoff entry used by link-lost and prepare failures.
  Future<void> _beginReconnectAttempt({
    required String name,
    int? epoch,
  }) async {
    if (_userStopRequested) return;
    final currentEpoch = epoch ?? _bumpEpoch();
    if (!_isEpochCurrent(currentEpoch)) return;

    _reconnectAttempt++;
    if (_reconnectAttempt > 8) {
      _emit(
        AcquisitionFailed(
          message:
              'Gave up reconnecting to $name after $_reconnectAttempt attempts',
          health: _health.copyWith(reconnectAttempt: _reconnectAttempt),
        ),
      );
      await StreamingForegroundService.ensureStopped();
      return;
    }

    final delay = _backoff(_reconnectAttempt);
    _mutateHealth((h) => h.copyWith(reconnectAttempt: _reconnectAttempt));
    _emit(
      AcquisitionReconnecting(
        deviceName: name,
        attempt: _reconnectAttempt,
        nextRetryIn: delay,
        health: _health,
      ),
    );

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      if (_userStopRequested || !_isEpochCurrent(currentEpoch)) return;
      await _attemptReconnect(epoch: currentEpoch);
    });
  }

  Future<void> _attemptReconnect({required int epoch}) async {
    if (!_isEpochCurrent(epoch) || _userStopRequested) return;

    final id = _preferredId;
    BluetoothDevice? device;
    if (id != null && _discovered.containsKey(id)) {
      device = _discovered[id];
    } else {
      device = _device;
    }

    // Prefer a listened rediscovery so stale cached peripherals are refreshed.
    if (id != null) {
      final found = await _scanForPreferred(
        id: id,
        name: _preferredName,
        timeout: const Duration(seconds: 8),
      );
      if (!_isEpochCurrent(epoch) || _userStopRequested) return;
      if (found != null) {
        device = found;
      }
    }

    if (device == null) {
      await _beginReconnectAttempt(
        name: _preferredName ?? 'device',
        epoch: epoch,
      );
      return;
    }

    try {
      try {
        await device.disconnect();
      } catch (_) {}
      if (!_isEpochCurrent(epoch) || _userStopRequested) return;

      await device.connect(
        timeout: const Duration(seconds: 15),
        license: License.nonprofit,
      );
      if (!_isEpochCurrent(epoch) || _userStopRequested) {
        try {
          await device.disconnect();
        } catch (_) {}
        return;
      }
      _device = device;
      await _prepareAndStream(
        device,
        epoch: epoch,
        resumeReconnectOnFailure: true,
      );
    } catch (_) {
      if (!_isEpochCurrent(epoch)) return;
      await _beginReconnectAttempt(
        name: _preferredName ?? device.platformName,
        epoch: epoch,
      );
    }
  }

  /// Listened scan for a preferred peripheral; returns the device when found.
  Future<BluetoothDevice?> _scanForPreferred({
    required String id,
    String? name,
    required Duration timeout,
  }) async {
    await _stopScanRadio();
    final completer = Completer<BluetoothDevice?>();
    Timer? timeoutTimer;

    void completeOnce(BluetoothDevice? device) {
      if (completer.isCompleted) return;
      timeoutTimer?.cancel();
      completer.complete(device);
    }

    try {
      _scanSubs.add(
        FlutterBluePlus.scanResults.listen((results) {
          for (final r in results) {
            _considerScanResult(
              r.device,
              r.rssi,
              advName: r.advertisementData.advName,
              serviceUuids: r.advertisementData.serviceUuids,
            );
            final matchId = r.device.remoteId.str == id;
            final matchName =
                name != null && name.isNotEmpty && r.device.platformName == name;
            if (matchId || matchName) {
              completeOnce(r.device);
              return;
            }
          }
        }),
      );

      await FlutterBluePlus.startScan(
        withServices: [
          Guid(EmotivBleUuids.control),
          Guid(EmotivBleUuids.serviceB),
        ],
        timeout: timeout,
        androidUsesFineLocation: true,
      );

      timeoutTimer = Timer(timeout, () => completeOnce(null));
      final found = await completer.future;
      await _stopScanRadio();
      return found;
    } catch (_) {
      await _stopScanRadio();
      return null;
    }
  }

  Duration _backoff(int attempt) {
    final baseMs = min(30000, 1000 * (1 << min(attempt, 5)));
    final jitter = Random().nextInt(400);
    return Duration(milliseconds: baseMs + jitter);
  }

  Future<void> _cancelReconnect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  Future<bool> _ensureAdapterReady() async {
    try {
      if (await FlutterBluePlus.isSupported == false) {
        _emit(
          AcquisitionFailed(
            message: 'Bluetooth LE is not supported on this device',
            health: _health,
          ),
        );
        unawaited(StreamingForegroundService.ensureStopped());
        return false;
      }
    } catch (_) {}

    BluetoothAdapterState adapterState;
    try {
      adapterState = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      adapterState = FlutterBluePlus.adapterStateNow;
    }

    if (adapterState == BluetoothAdapterState.off ||
        adapterState == BluetoothAdapterState.unavailable ||
        adapterState == BluetoothAdapterState.unauthorized) {
      _emit(
        AcquisitionFailed(
          message: 'Bluetooth is $adapterState. Turn it on and allow '
              'nearby-device permission, then scan again.',
          health: _health,
        ),
      );
      unawaited(StreamingForegroundService.ensureStopped());
      return false;
    }
    return true;
  }

  Future<void> _seedAlreadyConnected() async {
    try {
      final connected = FlutterBluePlus.connectedDevices;
      for (final d in connected) {
        _considerScanResult(d, _rssi[d.remoteId.str] ?? 0);
      }
    } catch (_) {}

    try {
      final withServices = await FlutterBluePlus.systemDevices([
        Guid(EmotivBleUuids.control),
        Guid(EmotivBleUuids.serviceB),
      ]);
      for (final d in withServices) {
        // Windows systemDevices ignores withServices; require name/preferred.
        _considerScanResult(d, _rssi[d.remoteId.str] ?? 0);
      }
    } catch (_) {}
  }

  void _considerScanResult(
    BluetoothDevice device,
    int rssi, {
    String? advName,
    List<Guid> serviceUuids = const [],
  }) {
    final id = device.remoteId.str;
    final platformName = device.platformName.trim();
    final resolvedAdv = (advName ?? '').trim();
    final name = platformName.isNotEmpty ? platformName : resolvedAdv;
    final isPreferred = id == _preferredId ||
        (_preferredName != null &&
            name.isNotEmpty &&
            name == _preferredName);

    final candidate = _identityResolver.isEmotivScanCandidate(
      name,
      serviceUuids: serviceUuids.map((g) => g.str),
      isPreferred: isPreferred,
    );
    if (!candidate) {
      _discovered.remove(id);
      _rssi.remove(id);
      return;
    }

    _discovered[id] = device;
    if (rssi != 0 || !_rssi.containsKey(id)) {
      _rssi[id] = rssi;
    }
  }

  List<DiscoveredDevice> _buildDeviceList() {
    final devices = _discovered.entries.map((e) {
      final name = e.value.platformName;
      final parsed = _identityResolver.tryParseAdvertisement(name);
      return DiscoveredDevice(
        id: e.key,
        name: name.isEmpty ? '(unnamed Emotiv)' : name,
        rssi: _rssi[e.key],
        serialHex: parsed?.serialHex,
        isPreferred: e.key == _preferredId ||
            (_preferredName != null && name == _preferredName),
      );
    }).toList()
      ..sort((a, b) {
        if (a.isPreferred != b.isPreferred) {
          return a.isPreferred ? -1 : 1;
        }
        final ar = a.rssi ?? -999;
        final br = b.rssi ?? -999;
        return br.compareTo(ar);
      });
    return devices;
  }

  void _publishScanDevices({bool clearError = false}) {
    if (_state is! AcquisitionScanning) return;
    final current = _state as AcquisitionScanning;
    _emit(
      current.copyWith(
        devices: _buildDeviceList(),
        preferredId: _preferredId,
        clearErrorMessage: clearError,
        health: _health,
      ),
    );
  }

  void _emitToScanningWithError(String message) {
    _emit(
      AcquisitionScanning(
        devices: _buildDeviceList(),
        active: false,
        preferredId: _preferredId,
        errorMessage: message,
        health: _health,
      ),
    );
    // Soft connect/prepare failure: drop FGS (fire-and-forget).
    unawaited(StreamingForegroundService.ensureStopped());
  }

  Future<void> _tryAutoConnectPreferred() async {
    if (!BleFsmPolicy.claimAutoConnect(
      enabled: _autoConnectPreferred,
      alreadyClaimed: _autoConnectClaimed,
    )) {
      return;
    }
    if (!BleFsmPolicy.canConnect(_state)) return;
    final id = _preferredId;
    if (id == null) return;

    String? targetId;
    if (_discovered.containsKey(id)) {
      targetId = id;
    } else if (_preferredName != null) {
      for (final e in _discovered.entries) {
        if (e.value.platformName == _preferredName) {
          targetId = e.key;
          break;
        }
      }
    }
    if (targetId == null) return;

    // Synchronous claim before any await so concurrent scanResults cannot
    // start a second connect.
    _autoConnectClaimed = true;
    _autoConnectPreferred = false;
    await connect(targetId);
  }

  Future<void> _stopScanRadio() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await _scanActiveSub?.cancel();
    _scanActiveSub = null;
    // Cancel scan-result listeners only; keep link/notify subs intact.
    await _scanSubs.cancelAll();
  }

  Future<void> _forceDisconnect(BluetoothDevice? device) async {
    final target = device ?? _device;
    if (target == null) return;
    try {
      await target.disconnect();
    } catch (_) {}
  }

  Future<void> _rememberPreferred({
    required String id,
    required String name,
  }) async {
    _preferredId = id;
    _preferredName = name;
    final next = _settings.copyWith(
      preferredDeviceId: id,
      preferredDeviceName: name,
    );
    _settings = next;
    final persist = _persistSettings;
    if (persist != null) {
      try {
        await persist(next);
      } catch (_) {}
    }
  }

  bool _isDisSerial(String uuid) {
    final id = uuid.toUpperCase().replaceAll('-', '');
    return id == '00002A2500001000800000805F9B34FB' || id == '2A25';
  }

  /// Ordered teardown: stop packets → cancel notifies → flush CSV → close LSL → disconnect.
  Future<void> _orderedTeardown({required bool disconnectBle}) async {
    final name = _preferredName ?? _device?.platformName ?? '';
    if (disconnectBle && (_state is AcquisitionStreaming || _device != null)) {
      _emit(AcquisitionStopping(deviceName: name, health: _health));
    }

    _acceptPackets = false;
    _rateTimer?.cancel();
    _rateTimer = null;
    await _scanSubs.cancelAll();
    await _linkSubs.cancelAll();
    await _decodeSub?.cancel();
    _decodeSub = null;

    try {
      await _csv.stop();
    } catch (_) {}
    try {
      await _liveSync.stop(
        timeout: disconnectBle
            ? const Duration(seconds: 45)
            : const Duration(seconds: 15),
      );
    } catch (_) {}
    try {
      await _lsl.stop();
    } catch (_) {}
    try {
      await _network.stop();
    } catch (_) {}

    _hub.clear();
    _lastEegMonoUs = null;

    if (disconnectBle) {
      await _forceDisconnect(_device);
      _device = null;
      _mutateHealth((h) => h.copyWith(clearBatteryPercent: true));
    }
  }

  void _onLiveSyncStatus(String? message) {
    _mutateHealth(
      (h) => message == null
          ? h.copyWith(clearSyncMessage: true)
          : h.copyWith(syncMessage: message),
    );
    final s = _state;
    if (s is AcquisitionStreaming) {
      _emit(
        AcquisitionStreaming(
          deviceName: s.deviceName,
          sessionDir: s.sessionDir,
          health: _health,
        ),
      );
    } else if (s is AcquisitionIdle) {
      _emit(AcquisitionIdle(health: _health));
    } else if (s is AcquisitionStopping) {
      _emit(AcquisitionStopping(deviceName: s.deviceName, health: _health));
    }
  }

  void _mutateHealth(
    AcquisitionHealth Function(AcquisitionHealth) fn,
  ) {
    _health = fn(_health);
  }

  void _emit(AcquisitionState next) {
    _state = next;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }
}
