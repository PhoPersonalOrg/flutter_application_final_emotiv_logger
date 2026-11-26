import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../app/save_directory_policy.dart';
import '../decode/crypto_codec.dart';
import '../decode/device_identity.dart';
import '../decode/headset_config.dart';
import '../domain/samples.dart';
import 'recorder_identity.dart';
import 'sample_hub.dart';

/// Result of opening a session directory for CSV/raw logging.
class CsvSessionStart {
  const CsvSessionStart({
    required this.sessionPath,
    required this.usedFallback,
    this.message,
  });

  final String sessionPath;
  final bool usedFallback;
  final String? message;
}

/// Session-directory CSV/raw writer (`session.json`, `eeg.csv`, `motion.csv`,
/// `cq.csv`, `raw.csv`) with ordered flush on teardown.
class CsvSink {
  CsvSink({required this.hub});

  final SampleHub hub;

  Directory? _sessionDir;
  IOSink? _eeg;
  IOSink? _motion;
  IOSink? _cq;
  IOSink? _raw;
  Timer? _flushTimer;
  StreamSubscription? _sub;
  bool _closed = true;

  String? get sessionPath => _sessionDir?.path;

  /// Opens writers under [saveDirectory], falling back to app documents if
  /// the custom path is unwritable. Throws only if both locations fail.
  Future<CsvSessionStart> startSession({
    required String? saveDirectory,
    required DeviceIdentity identity,
    HeadsetConfig? headsetConfig,
    int eegResolutionBits = CryptoCodec.defaultEegResolutionBits,
    HeadbandPosition headbandPosition = HeadbandPosition.top,
    int? negotiatedMtu,
  }) async {
    await stop();
    _closed = false;

    final cfg = headsetConfig ??
        HeadsetConfig(
          headsetFirmware: identity.sessionKey.firmwareVersion,
          mode: identity.sessionKey.keyMode,
          serialHex: identity.btKeyHex,
          disSerialHex: identity.disSerialHex,
          eegResolutionBits: eegResolutionBits,
        );

    // iOS: ignore custom paths (File Provider / picker paths are not durable).
    final preferred = effectiveSaveDirectory(saveDirectory);

    Object? customError;
    if (preferred != null) {
      try {
        final path = await _openUnder(
          Directory(preferred),
          identity,
          cfg: cfg,
          headbandPosition: headbandPosition,
          negotiatedMtu: negotiatedMtu,
        );
        return CsvSessionStart(
          sessionPath: path,
          usedFallback: false,
          message: 'CSV writing to $path',
        );
      } catch (e) {
        customError = e;
      }
    }

    final docs = await getApplicationDocumentsDirectory();
    try {
      final path = await _openUnder(
        docs,
        identity,
        cfg: cfg,
        headbandPosition: headbandPosition,
        negotiatedMtu: negotiatedMtu,
      );
      final msg = customError == null
          ? 'CSV writing to app documents: $path'
          : 'CSV using app documents (custom path denied: $customError)';
      return CsvSessionStart(
        sessionPath: path,
        usedFallback: preferred != null,
        message: msg,
      );
    } catch (e) {
      _closed = true;
      throw StateError(
        'CSV unwritable (custom: $customError; app documents: $e)',
      );
    }
  }

  Future<String> _openUnder(
    Directory base,
    DeviceIdentity identity, {
    required HeadsetConfig cfg,
    required HeadbandPosition headbandPosition,
    required int? negotiatedMtu,
  }) async {
    if (!await base.exists()) {
      await base.create(recursive: true);
    }
    await _probeWritable(base);

    final startedAt = DateTime.now();
    final stamp = startedAt.toIso8601String().replaceAll(':', '-');
    final sessionDir = Directory('${base.path}/session_$stamp');
    await sessionDir.create(recursive: true);

    final recorder = await resolveRecorderIdentity();
    final meta = <String, Object?>{
      'deviceName': identity.deviceName,
      'device_id': recorder.deviceId,
      'app_version_name': recorder.appVersionName,
      'startedAt': startedAt.toIso8601String(),
      'gps': recorder.gps,
      'gps_status': recorder.gpsStatus ?? 'unavailable',
      'btKeyHex': identity.btKeyHex,
      'disSerialHex': identity.disSerialHex,
      'serialSource': 'ble_hex',
      'serialOrigin': identity.serialOrigin,
      'keyFingerprint': identity.keyFingerprint,
      'headsetFirmware': cfg.headsetFirmware,
      'headsetFirmwareHex': cfg.headsetFirmwareHex,
      'cryptoVersion': identity.sessionKey.isV4 ? 4 : 2,
      'headsetMode': cfg.mode,
      'headsetConfigHex': cfg.rawConfigHex,
      'eegResolutionBits': cfg.eegResolutionBits,
      'eegRateHz': cfg.eegRateHz.toDouble(),
      'motionRateHz': cfg.memsRateHz.toDouble(),
      'motionResolutionBits': cfg.memsResolutionBits,
      'headbandPosition': headbandPosition.storageValue,
      'negotiatedMtu': negotiatedMtu,
      'eegChannels': EegSample.channelNames,
      'motionChannels': MotionSample.channelNames,
      'cqChannels': EegSample.qualityChannelNames,
    };
    await File('${sessionDir.path}/session.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(meta),
    );

    _sessionDir = sessionDir;
    _eeg = File('${sessionDir.path}/eeg.csv').openWrite();
    _eeg!.writeln(
      'wall_ms,mono_us,counter,marker_hw,${EegSample.channelNames.join(',')}',
    );

    _motion = File('${sessionDir.path}/motion.csv').openWrite();
    _motion!.writeln(
      'wall_ms,mono_us,counter_mems,${MotionSample.channelNames.join(',')}',
    );

    _cq = File('${sessionDir.path}/cq.csv').openWrite();
    _cq!.writeln(
      'wall_ms,mono_us,counter,overall_cq,battery_pct,${EegSample.qualityChannelNames.join(',')}',
    );

    _raw = File('${sessionDir.path}/raw.csv').openWrite();
    _raw!.writeln('wall_ms,mono_us,kind,char_uuid,bytes');

    _flushTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(flush());
    });
    _sub = hub.csvAvailable.listen((_) => _drain());
    return sessionDir.path;
  }

  Future<void> _probeWritable(Directory directory) async {
    final probe = File(
      '${directory.path}/.emotiv_write_probe_${DateTime.now().microsecondsSinceEpoch}',
    );
    await probe.writeAsString('ok');
    await probe.delete();
  }

  void _drain() {
    if (_closed) return;
    for (final s in hub.takeCsvEeg()) {
      final wallMs = s.wallClock.millisecondsSinceEpoch;
      _eeg?.writeln(
        '$wallMs,${s.receiveMonoUs},${s.counter},${s.markerHw},${s.values.join(',')}',
      );
      _cq?.writeln(
        '$wallMs,${s.receiveMonoUs},${s.counter},${s.overallCq},${s.batteryPercent ?? ''},${s.contactQualityGrades.join(',')}',
      );
    }
    for (final s in hub.takeCsvMotion()) {
      _motion?.writeln(
        '${s.wallClock.millisecondsSinceEpoch},${s.receiveMonoUs},${s.counterMems},${s.values.join(',')}',
      );
    }
    for (final p in hub.takeCsvRaw()) {
      final uuid = p.characteristicUuid ?? '';
      _raw?.writeln(
        '${p.wallClock.millisecondsSinceEpoch},${p.receiveMonoUs},${p.kind.name},$uuid,${p.bytes.join(' ')}',
      );
    }
  }

  Future<void> flush() async {
    _drain();
    await _eeg?.flush();
    await _motion?.flush();
    await _cq?.flush();
    await _raw?.flush();
  }

  Future<void> stop() async {
    if (_closed && _eeg == null) return;
    _closed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    await _sub?.cancel();
    _sub = null;
    try {
      await flush();
    } catch (_) {}
    try {
      await _eeg?.close();
    } catch (_) {}
    try {
      await _motion?.close();
    } catch (_) {}
    try {
      await _cq?.close();
    } catch (_) {}
    try {
      await _raw?.close();
    } catch (_) {}
    _eeg = null;
    _motion = null;
    _cq = null;
    _raw = null;
  }
}
