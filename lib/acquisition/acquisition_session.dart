import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../app/settings.dart';
import '../decode/decode_pipeline.dart';
import '../decode/device_identity.dart';
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
  AcquisitionSession({AppSettings? initialSettings})
      : _settings = initialSettings ?? const AppSettings() {
    _hub = SampleHub(onHealth: _mutateHealth);
    _csv = CsvSink(hub: _hub);
    _lsl = LslSink(hub: _hub, onHealth: _mutateHealth);
    _network = NetworkSink(hub: _hub, onHealth: _mutateHealth);
    _stateController.add(const AcquisitionIdle());
  }

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
  Timer? _rateTimer;
  Timer? _reconnectTimer;

  AppSettings _settings;
  AcquisitionState _state = const AcquisitionIdle();
  AcquisitionHealth _health = const AcquisitionHealth();

  final Map<String, BluetoothDevice> _discovered = {};
  BluetoothDevice? _device;
  String? _preferredName;
  String? _preferredId;
  DeviceIdentity? _identity;
  Uint8List? _keyBytes;
  bool _acceptPackets = false;
  bool _userStopRequested = false;
  int _reconnectAttempt = 0;
  int _eegWindow = 0;
  int _motionWindow = 0;
  int? _lastEegMonoUs;

  Stream<AcquisitionState> get stateStream => _stateController.stream;
  AcquisitionState get state => _state;
  AcquisitionHealth get health => _health;
  SampleHub get hub => _hub;

  Future<void> updateSettings(AppSettings settings) async {
    _settings = settings;
    if (_state is AcquisitionStreaming || _state is AcquisitionPreparing) {
      await _network.configure(
        settings: settings,
        deviceId: _identity?.btKeyHex,
      );
    }
  }

  Future<void> startScan() async {
    if (_state is! AcquisitionIdle &&
        _state is! AcquisitionFailed &&
        _state is! AcquisitionScanning) {
      return;
    }
    await _cancelReconnect();
    _discovered.clear();
    _emit(AcquisitionScanning(devices: const [], health: _health));

    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(EmotivBleUuids.control)],
        timeout: const Duration(seconds: 30),
      );
      _subs.add(
        FlutterBluePlus.scanResults.listen((results) {
          for (final r in results) {
            final name = r.device.platformName;
            if (name.isEmpty) continue;
            _discovered[r.device.remoteId.str] = r.device;
          }
          final devices = _discovered.entries
              .map(
                (e) => DiscoveredDevice(
                  id: e.key,
                  name: e.value.platformName,
                ),
              )
              .toList();
          if (_state is AcquisitionScanning) {
            _emit(
              AcquisitionScanning(devices: devices, health: _health),
            );
          }
        }),
      );
    } catch (e) {
      await stopScan();
      _emit(AcquisitionFailed(message: 'Scan failed: $e', health: _health));
    }
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await _subs.cancelAll();
    if (_state is AcquisitionScanning) {
      _emit(AcquisitionIdle(health: _health));
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
    _userStopRequested = false;
    _reconnectAttempt = 0;
    await stopScan();
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
        license: License.free,
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
      _identity = _identityResolver.resolveFromName(name);
      _keyBytes = _identity!.keyBytes;

      await _decode.start();
      await _decodeSub?.cancel();
      _decodeSub = _decode.results.listen(_onDecodeResult);

      final sessionPath = await _csv.startSession(
        saveDirectory: _settings.saveDirectory,
        identity: _identity!,
      );
      _mutateHealth(
        (h) => h.copyWith(csvSessionPath: sessionPath),
      );

      await _lsl.start(
        enabled: _settings.lslEnabled,
        sourceId: device.remoteId.str,
      );
      await _network.configure(
        settings: _settings,
        deviceId: _identity!.btKeyHex,
      );

      _subs.add(
        device.connectionState.listen((s) {
          if (s == BluetoothConnectionState.disconnected) {
            unawaited(_onLinkLost());
          }
        }),
      );

      await _armNotifications(device);
      _acceptPackets = true;
      _reconnectAttempt = 0;
      _startRateMonitor();

      _emit(
        AcquisitionStreaming(
          deviceName: name,
          sessionDir: sessionPath,
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

    for (final service in services) {
      for (final c in service.characteristics) {
        final id = c.uuid.toString().toUpperCase();
        if (id == EmotivBleUuids.eeg) {
          eegChar = c;
        } else if (id == EmotivBleUuids.motion) {
          motionChar = c;
        }
      }
    }

    if (eegChar == null) {
      throw StateError('EEG characteristic not found');
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

    // Start command (0x100 LE) — may be redundant but matches headset protocol.
    final startCmd = Uint8List.fromList([0x00, 0x01, 0x00, 0x00]);
    try {
      await eegChar.write(startCmd, withoutResponse: false);
    } catch (_) {}
    if (motionChar != null) {
      try {
        await motionChar.write(startCmd, withoutResponse: false);
      } catch (_) {}
    }
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
      _decode.submit(packet, keyBytes: key);
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
      case DecodeFailed():
        break;
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
        // Try scan briefly for preferred device.
        try {
          await FlutterBluePlus.startScan(
            withServices: [Guid(EmotivBleUuids.control)],
            timeout: const Duration(seconds: 8),
          );
          await Future<void>.delayed(const Duration(seconds: 2));
          for (final r in FlutterBluePlus.lastScanResults) {
            if (r.device.remoteId.str == id ||
                r.device.platformName == _preferredName) {
              device = r.device;
              _discovered[r.device.remoteId.str] = r.device;
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
          license: License.free,
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
