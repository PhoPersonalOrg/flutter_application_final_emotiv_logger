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
import '../sinks/csv_sink.dart';
import '../sinks/lsl_sink.dart';
import '../sinks/network_sink.dart';
import '../sinks/sample_hub.dart';
import 'session_subscriptions.dart';

/// Owns the BLE acquisition FSM, decode pipeline, and sinks.
class AcquisitionSession {
  AcquisitionSession({
    AppSettings? initialSettings,
    Future<void> Function(AppSettings settings)? persistSettings,
  })  : _settings = initialSettings ?? const AppSettings(),
        _persistSettings = persistSettings {
    _preferredId = _settings.preferredDeviceId;
    _preferredName = _settings.preferredDeviceName;
    _hub = SampleHub(onHealth: _mutateHealth);
    _csv = CsvSink(hub: _hub);
    _lsl = LslSink(hub: _hub, onHealth: _mutateHealth);
    _network = NetworkSink(hub: _hub, onHealth: _mutateHealth);
    _stateController.add(const AcquisitionIdle());
  }

  final Future<void> Function(AppSettings settings)? _persistSettings;

  final _stateController =
      StreamController<AcquisitionState>.broadcast(sync: true);
  final _identityResolver = DeviceIdentityResolver();
  final _decode = DecodePipeline();

  late final SampleHub _hub;
  late final CsvSink _csv;
  late final LslSink _lsl;
  late final NetworkSink _network;

  final _subs = SessionSubscriptions();
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
  int _reconnectAttempt = 0;
  int _eegWindow = 0;
  int _motionWindow = 0;
  int? _lastEegMonoUs;

  Stream<AcquisitionState> get stateStream => _stateController.stream;
  AcquisitionState get state => _state;
  AcquisitionHealth get health => _health;
  SampleHub get hub => _hub;
  String? get preferredDeviceId => _preferredId;
  String? get preferredDeviceName => _preferredName;

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
    if (_state is! AcquisitionIdle &&
        _state is! AcquisitionFailed &&
        _state is! AcquisitionScanning) {
      return;
    }
    await _cancelReconnect();
    await _stopScanRadio();
    _discovered.clear();
    _rssi.clear();
    _autoConnectPreferred = autoConnectPreferred;
    _emit(
      AcquisitionScanning(
        devices: const [],
        active: true,
        preferredId: _preferredId,
        health: _health,
      ),
    );

    try {
      final adapter = await _ensureAdapterReady();
      if (!adapter) return;

      await _seedAlreadyConnected();

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

      _subs.add(
        FlutterBluePlus.scanResults.listen((results) {
          for (final r in results) {
            _considerScanResult(r.device, r.rssi);
          }
          _publishScanDevices();
          if (_autoConnectPreferred) {
            unawaited(_tryAutoConnectPreferred());
          }
        }),
      );
      _publishScanDevices();
    } catch (e) {
      await _stopScanRadio();
      _emit(AcquisitionFailed(message: 'Scan failed: $e', health: _health));
    }
  }

  /// Scan and connect to the last used headset when it appears.
  Future<void> reconnectPreferred() async {
    final id = _preferredId;
    if (id == null) {
      await startScan();
      return;
    }
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
    if (_state is AcquisitionScanning) {
      final current = _state as AcquisitionScanning;
      _emit(current.copyWith(active: false));
    }
  }

  Future<void> connect(String deviceId) async {
    final device = _discovered[deviceId];
    if (device == null) {
      _emit(
        AcquisitionFailed(
          message: 'Unknown device id: $deviceId',
          health: _health,
        ),
      );
      return;
    }
    _preferredId = deviceId;
    _preferredName = device.platformName;
    _autoConnectPreferred = false;
    _userStopRequested = false;
    _reconnectAttempt = 0;
    await _stopScanRadio();
    await _connectDevice(device);
  }

  Future<void> disconnect() async {
    _userStopRequested = true;
    await _cancelReconnect();
    await _orderedTeardown(disconnectBle: true);
    _emit(AcquisitionIdle(health: _health));
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
    await _cancelReconnect();
    await _stopScanRadio();
    await _orderedTeardown(disconnectBle: true);
    await _decode.dispose();
    await _hub.dispose();
    await _stateController.close();
  }

  Future<void> _connectDevice(BluetoothDevice device) async {
    _emit(
      AcquisitionConnecting(
        deviceName: device.platformName,
        health: _health,
      ),
    );
    try {
      await device.connect(
        timeout: const Duration(seconds: 15),
        license: License.nonprofit,
      );
      _device = device;
      await _prepareAndStream(device);
    } catch (e) {
      await _subs.cancelAll();
      _emit(
        AcquisitionFailed(message: 'Connect failed: $e', health: _health),
      );
    }
  }

  Future<void> _prepareAndStream(BluetoothDevice device) async {
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
      _decode.resetSession();
      _mutateHealth((h) => h.copyWith(clearDecodeMessage: true));
      await _decodeSub?.cancel();
      _decodeSub = _decode.results.listen(_onDecodeResult);

      _subs.add(
        device.connectionState.listen((s) {
          if (s == BluetoothConnectionState.disconnected) {
            unawaited(_onLinkLost());
          }
        }),
      );

      // Discover + config/serial extract must happen before CSV/LSL so identity
      // can fall back to DIS serial when the advertising name is incomplete.
      await _armNotifications(device);

      _identity ??= _identityResolver.resolveFromName(name);
      _keyBytes = _identity!.keyBytes;
      await _rememberPreferred(
        id: device.remoteId.str,
        name: _identity!.deviceName,
      );

      // CSV is first-class but must never abort BLE arming.
      var sessionPath = '';
      try {
        final csvStart = await _csv.startSession(
          saveDirectory: _settings.saveDirectory,
          identity: _identity!,
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
      );
      await _network.configure(
        settings: _settings,
        deviceId: _identity!.btKeyHex,
      );

      _acceptPackets = true;
      _reconnectAttempt = 0;
      _startRateMonitor();

      _emit(
        AcquisitionStreaming(
          deviceName: name.isEmpty ? _identity!.deviceName : name,
          sessionDir: sessionPath.isEmpty
              ? (_health.csvSessionPath ?? '(no csv)')
              : sessionPath,
          health: _health,
        ),
      );
    } catch (e) {
      await _orderedTeardown(disconnectBle: true);
      _emit(
        AcquisitionFailed(message: 'Prepare failed: $e', health: _health),
      );
    }
  }

  Future<void> _armNotifications(BluetoothDevice device) async {
    final services = await device.discoverServices();
    BluetoothCharacteristic? eegChar;
    BluetoothCharacteristic? motionChar;
    BluetoothCharacteristic? serviceBControl;
    BluetoothCharacteristic? headsetConfigChar;
    BluetoothCharacteristic? disSerialChar;

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

    await eegChar.setNotifyValue(true);
    _subs.add(
      eegChar.lastValueStream.listen((data) {
        if (!_acceptPackets || data.isEmpty) return;
        _enqueueRaw(PacketKind.eeg, data);
      }),
    );

    if (motionChar != null) {
      await motionChar.setNotifyValue(true);
      _subs.add(
        motionChar.lastValueStream.listen((data) {
          if (!_acceptPackets || data.isEmpty) return;
          _enqueueRaw(PacketKind.motion, data);
        }),
      );
    }

    // Enabling notifications is all that starts the stream; the official app
    // writes nothing to the EEG or motion characteristics.
  }

  void _enqueueRaw(PacketKind kind, List<int> data) {
    final bytes = Uint8List.fromList(data);
    if (kind == PacketKind.eeg && bytes.length < EmotivBleUuids.eegMinBytes) {
      return;
    }
    if (kind == PacketKind.motion &&
        bytes.length < EmotivBleUuids.motionMinBytes) {
      return;
    }

    final now = DateTime.now();
    // Headset clock is unavailable over BLE; wall + us is the receive timeline.
    final monoUs = now.microsecondsSinceEpoch;
    final packet = RawPacket(
      kind: kind,
      bytes: bytes,
      receiveMonoUs: monoUs,
      wallClock: now,
    );

    _hub.publishRaw(packet);
    final key = _keyBytes;
    if (key != null) {
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
    if (_state is AcquisitionStopping ||
        _state is AcquisitionIdle ||
        _state is AcquisitionFailed) {
      return;
    }

    final name = _preferredName ?? _device?.platformName ?? 'device';
    _acceptPackets = false;
    await _orderedTeardown(disconnectBle: false);

    _reconnectAttempt++;
    if (_reconnectAttempt > 8) {
      _emit(
        AcquisitionFailed(
          message: 'Gave up reconnecting to $name after $_reconnectAttempt attempts',
          health: _health.copyWith(reconnectAttempt: _reconnectAttempt),
        ),
      );
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
      if (_userStopRequested) return;
      BluetoothDevice? device = _device;
      final id = _preferredId;
      if (id != null && _discovered.containsKey(id)) {
        device = _discovered[id];
      }
      if (device == null && id != null) {
        try {
          await FlutterBluePlus.startScan(
            withServices: [
              Guid(EmotivBleUuids.control),
              Guid(EmotivBleUuids.serviceB),
            ],
            timeout: const Duration(seconds: 8),
            androidUsesFineLocation: true,
          );
          await Future<void>.delayed(const Duration(seconds: 2));
          for (final r in FlutterBluePlus.lastScanResults) {
            _considerScanResult(r.device, r.rssi);
            if (r.device.remoteId.str == id ||
                r.device.platformName == _preferredName) {
              device = r.device;
              break;
            }
          }
          await FlutterBluePlus.stopScan();
        } catch (_) {}
      }
      if (device == null) {
        unawaited(_onLinkLost());
        return;
      }
      try {
        await device.connect(
          timeout: const Duration(seconds: 15),
          license: License.nonprofit,
        );
        _device = device;
        await _prepareAndStream(device);
      } catch (_) {
        unawaited(_onLinkLost());
      }
    });
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
  }

  void _considerScanResult(BluetoothDevice device, int rssi) {
    final name = device.platformName;
    final id = device.remoteId.str;
    final parsed = name.isEmpty
        ? null
        : _identityResolver.tryParseAdvertisement(name);
    final isPreferred = id == _preferredId ||
        (_preferredName != null && name == _preferredName);

    // Keep service-filtered hits even when the local name is empty (common on
    // some Android stacks until GAP name is read); prefer parseable Emotiv names.
    if (name.isNotEmpty && parsed == null && !isPreferred) {
      return;
    }

    _discovered[id] = device;
    if (rssi != 0 || !_rssi.containsKey(id)) {
      _rssi[id] = rssi;
    }
  }

  void _publishScanDevices() {
    if (_state is! AcquisitionScanning) return;
    final current = _state as AcquisitionScanning;
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
    _emit(
      current.copyWith(
        devices: devices,
        preferredId: _preferredId,
        health: _health,
      ),
    );
  }

  Future<void> _tryAutoConnectPreferred() async {
    if (!_autoConnectPreferred) return;
    final id = _preferredId;
    if (id == null) return;
    if (!_discovered.containsKey(id)) {
      if (_preferredName == null) return;
      String? match;
      for (final e in _discovered.entries) {
        if (e.value.platformName == _preferredName) {
          match = e.key;
          break;
        }
      }
      if (match == null) return;
      _autoConnectPreferred = false;
      await connect(match);
      return;
    }
    _autoConnectPreferred = false;
    await connect(id);
  }

  Future<void> _stopScanRadio() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await _scanActiveSub?.cancel();
    _scanActiveSub = null;
    // Cancel scan-result listeners only; keep connection/notify subs intact.
    await _subs.cancelAll();
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
    await _subs.cancelAll();
    await _decodeSub?.cancel();
    _decodeSub = null;

    try {
      await _csv.stop();
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
      try {
        await _device?.disconnect();
      } catch (_) {}
      _device = null;
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
