import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../app/settings.dart';
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

/// Owns the EPOC X BLE GATT acquisition FSM, V2/V4 decode isolate, and sinks.
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
    _network = NetworkSink(hub: _hub, onHealth: _mutateAndPublishHealth);
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
  final Map<String, String> _advNames = {};
  BluetoothDevice? _device;
  String? _preferredName;
  String? _preferredId;
  DeviceIdentity? _identity;
  HeadsetConfig _headsetConfig = HeadsetConfig.bleDefaults();
  int? _negotiatedMtu;
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

  /// Service UUID filter passed to `FlutterBluePlus.startScan`:
  /// - On iOS/macOS, CoreBluetooth requires `[epocXService]` for `bluetooth-central`
  ///   background scanning and merges active `SCAN_RSP` (`81072f40`) automatically.
  /// - On Android/Windows/Linux, scan unfiltered with active scanning (`lowLatency`)
  ///   and filter via `isEmotivScanCandidate` so OEM hardware filters never drop
  ///   `ADV_IND` (`"EPOCX (<8HEX>)"`) before `SCAN_RSP` arrives.
  static List<Guid> _platformScanServiceFilter() {
    if (Platform.isIOS || Platform.isMacOS) {
      return [Guid(EmotivBleUuids.epocXService)];
    }
    return const [];
  }

  String _resolvedDeviceName(BluetoothDevice device) {
    final pName = device.platformName.trim();
    if (pName.isNotEmpty) return pName;
    final aName = device.advName.trim();
    if (aName.isNotEmpty) return aName;
    return (_advNames[device.remoteId.str] ?? '').trim();
  }

  Future<void> updateSettings(AppSettings settings) async {
    final prev = _settings;
    _settings = settings;
    _preferredId = settings.preferredDeviceId ?? _preferredId;
    _preferredName = settings.preferredDeviceName ?? _preferredName;
    if (prev.headbandPosition != settings.headbandPosition) {
      _decode.updateHeadbandPosition(settings.headbandPosition);
    }
    if (_state is AcquisitionStreaming || _state is AcquisitionPreparing) {
      unawaited(
        _network.configure(
          settings: settings,
          deviceId: _identity?.btKeyHex,
          eegRateHz: _headsetConfig.eegRateHz.toDouble(),
          motionRateHz: _headsetConfig.memsRateHz.toDouble(),
        ),
      );
      if (_state is AcquisitionStreaming &&
          _device != null &&
          (prev.lslEnabled != settings.lslEnabled ||
              prev.hostname.trim() != settings.hostname.trim())) {
        unawaited(
          _lsl
              .start(
                enabled: settings.lslEnabled,
                sourceId: _device!.remoteId.str,
                hostname: settings.hostname,
                eegRateHz: _headsetConfig.eegRateHz.toDouble(),
                motionRateHz: _headsetConfig.memsRateHz.toDouble(),
              )
              .then((_) => _refreshStreamingHealth()),
        );
      }
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

      // Active scanning (`SCAN_REQ` -> `SCAN_RSP`) is required because physical
      // EPOC X puts `"EPOCX (<8HEX>)"` in `ADV_IND` and `81072f40` in `SCAN_RSP`.
      await FlutterBluePlus.startScan(
        withServices: _platformScanServiceFilter(),
        timeout: const Duration(seconds: 30),
        continuousUpdates: true,
        continuousDivisor: 3,
        androidScanMode: AndroidScanMode.lowLatency,
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
    final name = _resolvedDeviceName(device);
    _preferredId = deviceId;
    if (name.isNotEmpty) {
      _preferredName = name;
    }
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
    final epoch = _bumpEpoch();
    await _cancelReconnect();
    await _orderedTeardown(disconnectBle: true);
    _mutateHealth((h) => h.copyWith(clearHardwareTelemetry: true));
    _emit(AcquisitionIdle(health: _health));
    // Stop FGS after CSV flush/teardown so the process is not demoted mid-flush.
    await StreamingForegroundService.ensureStopped(epoch: epoch);
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
    final epoch = _bumpEpoch();
    await _cancelReconnect();
    await _stopScanRadio();
    await _orderedTeardown(disconnectBle: true);
    await StreamingForegroundService.ensureStopped(epoch: epoch);
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
    final displayName = _resolvedDeviceName(device);
    _emit(
      AcquisitionConnecting(
        deviceName: displayName,
        health: _health,
      ),
    );
    // Pin the process for connect+prepare+stream (kept through Reconnecting).
    await StreamingForegroundService.ensureStarted(
      displayName,
      epoch: epoch,
    );
    try {
      // Drop any half-open OS link before a fresh connect attempt.
      try {
        await device.disconnect();
      } catch (_) {}
      if (!_isEpochCurrent(epoch)) return;

      await device.connect(
        timeout: const Duration(seconds: 15),
        license: License.nonprofit,
        mtu: EmotivBleUuids.preferredRequestMtu,
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

  /// Negotiate `ATT_MTU >= 87` (required for `84B` `81072f41` super-frames) and
  /// `7.5–10 ms` low-latency connection interval (`ConnectionPriority.high`).
  Future<void> _negotiateLinkParameters(BluetoothDevice device) async {
    _negotiatedMtu = null;
    if (Platform.isAndroid) {
      try {
        await device.requestConnectionPriority(
          connectionPriorityRequest: ConnectionPriority.high,
        );
      } catch (_) {}

      var mtu = device.mtuNow;
      if (mtu < EmotivBleUuids.minAttMtu) {
        try {
          mtu = await device.requestMtu(EmotivBleUuids.preferredRequestMtu);
        } catch (_) {
          mtu = device.mtuNow;
        }
      }
      _negotiatedMtu = mtu;
      if (mtu < EmotivBleUuids.minAttMtu) {
        _mutateHealth(
          (h) => h.copyWith(
            decodeMessage:
                'Warning: negotiated ATT_MTU=$mtu (< ${EmotivBleUuids.minAttMtu}); '
                '84-byte combined EEG+Motion notifications may be truncated.',
          ),
        );
      }
    } else {
      final cachedMtu = device.mtuNow;
      if (cachedMtu > 23) {
        _negotiatedMtu = cachedMtu;
      }
    }
  }

  Future<void> _prepareAndStream(
    BluetoothDevice device, {
    required int epoch,
    required bool resumeReconnectOnFailure,
  }) async {
    if (!_isEpochCurrent(epoch)) return;
    final initialName = _resolvedDeviceName(device);
    _emit(
      AcquisitionPreparing(
        deviceName: initialName,
        sessionDir: _health.csvSessionPath ?? '',
        health: _health,
      ),
    );

    try {
      await _decode.start();
      if (!_isEpochCurrent(epoch)) return;
      _mutateHealth((h) => h.copyWith(clearDecodeMessage: true));
      await _decodeSub?.cancel();
      _decodeSub = _decode.results.listen(_onDecodeResult);

      await _negotiateLinkParameters(device);
      if (!_isEpochCurrent(epoch)) return;

      // Discover services + read DIS 0x2A26 (FW), 0x2A25 (5B binary serial),
      // and 81072f44 (6B mode config) BEFORE opening CSV/LSL outlets.
      await _armNotifications(device);
      if (!_isEpochCurrent(epoch)) return;

      _mutateHealth(
        (h) => h.copyWith(
          headsetFirmwareHex: _headsetConfig.headsetFirmwareHex,
          cryptoVersion: _identity!.sessionKey.isV4 ? 4 : 2,
          negotiatedMtu: _negotiatedMtu,
          configuredEegRateHz: _headsetConfig.eegRateHz,
          configuredMotionRateHz: _headsetConfig.memsRateHz,
        ),
      );

      await _rememberPreferred(
        id: device.remoteId.str,
        name: _identity!.deviceName,
      );
      if (!_isEpochCurrent(epoch)) return;

      // CSV is first-class but must never abort BLE arming.
      var sessionPath = '';
      try {
        final csvStart = await _csv.startSession(
          saveDirectory: _settings.saveDirectory,
          identity: _identity!,
          headsetConfig: _headsetConfig,
          eegResolutionBits: _headsetConfig.eegResolutionBits,
          headbandPosition: _settings.headbandPosition,
          negotiatedMtu: _negotiatedMtu,
        );
        sessionPath = csvStart.sessionPath;
        _mutateHealth(
          (h) => h.copyWith(
            csvSessionPath: csvStart.sessionPath,
            csvMessage: csvStart.message,
            csvUsingFallback: csvStart.usedFallback,
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
        hostname: _settings.hostname,
        eegRateHz: _headsetConfig.eegRateHz.toDouble(),
        motionRateHz: _headsetConfig.memsRateHz.toDouble(),
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
      final streamingName =
          initialName.isEmpty ? _identity!.deviceName : initialName;
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
      await StreamingForegroundService.ensureStarted(
        streamingName,
        epoch: epoch,
      );

      // Network streaming and remote session sync are best-effort and must
      // never gate BLE/CSV startup.
      unawaited(
        _network.configure(
          settings: _settings,
          deviceId: _identity!.btKeyHex,
          eegRateHz: _headsetConfig.eegRateHz.toDouble(),
          motionRateHz: _headsetConfig.memsRateHz.toDouble(),
        ),
      );
      if (sessionPath.isNotEmpty) {
        unawaited(
          _liveSync.start(
            sessionPath: sessionPath,
            settings: _settings,
            flushCsv: _csv.flush,
          ),
        );
      }
    } catch (e) {
      if (!_isEpochCurrent(epoch)) return;
      await _orderedTeardown(disconnectBle: true);
      if (resumeReconnectOnFailure && !_userStopRequested) {
        await _beginReconnectAttempt(
          name: initialName.isEmpty ? (_preferredName ?? 'device') : initialName,
        );
        return;
      }
      _emitToScanningWithError('Prepare failed: $e');
    }
  }

  Future<void> _armNotifications(BluetoothDevice device) async {
    final services = await device.discoverServices();
    BluetoothCharacteristic? dataStreamChar;
    BluetoothCharacteristic? legacyMotionChar;
    BluetoothCharacteristic? headsetConfigChar;
    BluetoothCharacteristic? disModelChar;
    BluetoothCharacteristic? disSerialChar;
    BluetoothCharacteristic? disFirmwareChar;
    BluetoothCharacteristic? batteryChar;

    for (final service in services) {
      for (final c in service.characteristics) {
        final id = c.uuid.toString();
        if (EmotivBleUuids.isDataStream(id)) {
          dataStreamChar = c;
        } else if (EmotivBleUuids.isLegacyMotion(id)) {
          legacyMotionChar = c;
        } else if (EmotivBleUuids.isIgnoredAux(id)) {
          // 81072f43: recognized and ignored per CortexService 0x14088c630.
          continue;
        } else if (EmotivBleUuids.isHeadsetConfig(id)) {
          headsetConfigChar = c;
        } else if (EmotivBleUuids.isDisModelNumber(id)) {
          disModelChar = c;
        } else if (EmotivBleUuids.isDisSerialNumber(id)) {
          disSerialChar = c;
        } else if (EmotivBleUuids.isDisFirmwareRevision(id)) {
          disFirmwareChar = c;
        } else if (EmotivBleUuids.isBatteryLevel(id)) {
          batteryChar = c;
        }
      }
    }

    if (dataStreamChar == null) {
      throw StateError('EPOC X stream characteristic 81072f41 not found');
    }

    // 1. Read DIS 0x2A24 (optional model/build string) & 0x2A26 (2B BE headset_fw).
    String? modelStr;
    if (disModelChar != null) {
      try {
        modelStr = HeadsetConfig.parseDisModel0x2A24(await disModelChar.read());
      } catch (_) {}
    }

    var headsetFw = HeadsetConfig.defaultFirmwareVersion;
    if (disFirmwareChar != null) {
      try {
        final rawFw = await disFirmwareChar.read();
        final parsedFw = HeadsetConfig.parseDisFirmware0x2A26(
          rawFw,
          modelNumber0x2A24: modelStr,
        );
        if (parsedFw != null && parsedFw > 0) {
          headsetFw = parsedFw;
        }
      } catch (_) {}
    } else if (modelStr != null && modelStr.contains('0200')) {
      headsetFw = HeadsetConfig.legacyBleSplitMaxFirmware;
    }

    // 2. Read DIS 0x2A25 (5 raw binary serial bytes on physical EPOC X, e.g. e5 02 02 e9 2b).
    List<int>? disSerialBytes;
    if (disSerialChar != null) {
      try {
        disSerialBytes = await disSerialChar.read();
      } catch (_) {}
    }

    // 3. Read 81072f44 (6-byte read-only mode configuration).
    HeadsetConfig? parsedCfg;
    if (headsetConfigChar != null) {
      try {
        final cfgBytes = await headsetConfigChar.read();
        parsedCfg = HeadsetConfig.parse(
          cfgBytes,
          headsetFirmware: headsetFw,
        );
      } catch (_) {}
    }
    _headsetConfig = parsedCfg ??
        HeadsetConfig.bleDefaults(headsetFirmware: headsetFw);

    // 4. Resolve V2 (fw <= 0x073E) or V4 (fw >= 0x073F) key schedule.
    _identity = _identityResolver.resolveBleIdentity(
      deviceName: _resolvedDeviceName(device),
      dis0x2A25Bytes: disSerialBytes,
      firmwareVersion: _headsetConfig.headsetFirmware,
      keyMode: _headsetConfig.mode,
    );

    _headsetConfig = HeadsetConfig(
      headsetType: _headsetConfig.headsetType,
      mode: _headsetConfig.mode,
      dongleFirmware: 0,
      headsetFirmware: _headsetConfig.headsetFirmware,
      serialHex: _identity!.btKeyHex,
      disSerialHex: _identity!.disSerialHex,
      eegRateHz: _headsetConfig.eegRateHz,
      eegResolutionBits: _headsetConfig.eegResolutionBits,
      memsRateHz: _headsetConfig.memsRateHz,
      memsResolutionBits: _headsetConfig.memsResolutionBits,
      rawConfigBytes: _headsetConfig.rawConfigBytes,
    );

    _decode.configureSession(
      sessionKey: _identity!.sessionKey,
      eegRateHz: _headsetConfig.eegRateHz,
      eegResolutionBits: _headsetConfig.eegResolutionBits,
      headbandPosition: _settings.headbandPosition,
    );

    // 5. Subscribe CCCD 0x2902 (01 00) on 81072f41 (and 81072f42 if present / fw <= 0x0710).
    // Zero challenge/unlock writes are sent on EPOC X.
    final streamUuid = dataStreamChar.uuid.toString();
    await dataStreamChar.setNotifyValue(true);
    _linkSubs.add(
      dataStreamChar.lastValueStream.listen((data) {
        if (!_acceptPackets || data.isEmpty) return;
        _enqueueRaw(PacketKind.eeg, data, characteristicUuid: streamUuid);
      }),
    );

    if (legacyMotionChar != null) {
      final motionUuid = legacyMotionChar.uuid.toString();
      try {
        await legacyMotionChar.setNotifyValue(true);
        _linkSubs.add(
          legacyMotionChar.lastValueStream.listen((data) {
            if (!_acceptPackets || data.isEmpty) return;
            _enqueueRaw(
              PacketKind.motion,
              data,
              characteristicUuid: motionUuid,
            );
          }),
        );
      } catch (_) {}
    }

    // 6. Optional BAS 0x2A19 read/notify (complements primary in-band counter==Fs-1 battery latch).
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
    // Always capture non-empty notify payloads to raw.csv before length/split gates.
    final bytes = Uint8List.fromList(data);
    final now = DateTime.now();
    final monoUs = now.microsecondsSinceEpoch;
    final packet = RawPacket(
      kind: kind,
      bytes: bytes,
      receiveMonoUs: monoUs,
      wallClock: now,
      characteristicUuid: characteristicUuid,
    );

    _hub.publishRaw(packet);

    final sessionKey = _identity?.sessionKey;
    final longEnough = kind == PacketKind.eeg
        ? bytes.length >= EmotivBleUuids.eegMinBytes
        : bytes.length >= EmotivBleUuids.motionMinBytes;
    if (sessionKey != null && longEnough) {
      _decode.submit(
        packet,
        sessionKey: sessionKey,
        eegRateHz: _headsetConfig.eegRateHz,
        eegResolutionBits: _headsetConfig.eegResolutionBits,
        headbandPosition: _settings.headbandPosition,
      );
    }

    if (kind == PacketKind.eeg) {
      if (_lastEegMonoUs != null) {
        final gapUs = monoUs - _lastEegMonoUs!;
        // 81072f41 notifications arrive in pairs (~15.6 ms at 128 Hz, ~7.8 ms at 256 Hz).
        if (gapUs > 50000) {
          _mutateHealth((h) => h.copyWith(gapCount: h.gapCount + 1));
        }
      }
      _lastEegMonoUs = monoUs;
    }
  }

  void _onDecodeResult(DecodeResult result) {
    switch (result) {
      case DecodeEegOk(:final sample):
        _eegWindow++;
        _mutateHealth(
          (h) => h.copyWith(
            eegPackets: h.eegPackets + 1,
            batteryPercent: sample.batteryPercent ?? h.batteryPercent,
          ),
        );
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
    if (!BleFsmPolicy.canHandleLinkLost(_state)) return;

    final epoch = _bumpEpoch();
    final name = _preferredName ??
        (_device != null ? _resolvedDeviceName(_device!) : 'device');
    _acceptPackets = false;
    await _orderedTeardown(disconnectBle: false);
    if (!_isEpochCurrent(epoch)) return;

    await _beginReconnectAttempt(
      name: name.isEmpty ? 'device' : name,
      epoch: epoch,
    );
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
      await StreamingForegroundService.ensureStopped(epoch: currentEpoch);
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
        mtu: EmotivBleUuids.preferredRequestMtu,
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
        name: _preferredName ?? _resolvedDeviceName(device),
        epoch: epoch,
      );
    }
  }

  /// Listened active scan for a preferred peripheral; returns the device when found.
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
            final resolvedName = _resolvedDeviceName(r.device);
            final matchName =
                name != null && name.isNotEmpty && resolvedName == name;
            if (matchId || matchName) {
              completeOnce(r.device);
              return;
            }
          }
        }),
      );

      await FlutterBluePlus.startScan(
        withServices: _platformScanServiceFilter(),
        timeout: timeout,
        continuousUpdates: true,
        continuousDivisor: 3,
        androidScanMode: AndroidScanMode.lowLatency,
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
        unawaited(StreamingForegroundService.ensureStopped(epoch: _opEpoch));
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
      unawaited(StreamingForegroundService.ensureStopped(epoch: _opEpoch));
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
        Guid(EmotivBleUuids.epocXService),
      ]);
      for (final d in withServices) {
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
    final resolvedAdv = (advName ?? '').trim();
    if (resolvedAdv.isNotEmpty) {
      _advNames[id] = resolvedAdv;
    }
    final name = _resolvedDeviceName(device);
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
      final name = _resolvedDeviceName(e.value);
      final parsed = _identityResolver.tryParseAdvertisement(name);
      return DiscoveredDevice(
        id: e.key,
        name: name.isEmpty ? '(unnamed EPOC X)' : name,
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
    unawaited(StreamingForegroundService.ensureStopped(epoch: _opEpoch));
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
        if (_resolvedDeviceName(e.value) == _preferredName) {
          targetId = e.key;
          break;
        }
      }
    }
    if (targetId == null) return;

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

  /// Ordered teardown: stop packets → cancel notifies → flush CSV → close LSL → disconnect.
  Future<void> _orderedTeardown({required bool disconnectBle}) async {
    final name = _preferredName ??
        (_device != null ? _resolvedDeviceName(_device!) : '');
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
    unawaited(_liveSync.stop(timeout: const Duration(seconds: 60)));
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
      _negotiatedMtu = null;
      _mutateHealth((h) => h.copyWith(clearHardwareTelemetry: true));
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
    } else if (s is AcquisitionScanning) {
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

  void _mutateHealth(
    AcquisitionHealth Function(AcquisitionHealth) fn,
  ) {
    _health = fn(_health);
  }

  void _mutateAndPublishHealth(
    AcquisitionHealth Function(AcquisitionHealth) fn,
  ) {
    _mutateHealth(fn);
    _refreshStreamingHealth();
  }

  void _emit(AcquisitionState next) {
    _state = next;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }
}
