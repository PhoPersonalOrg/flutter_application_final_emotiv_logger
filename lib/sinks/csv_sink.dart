import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../decode/device_identity.dart';
import '../domain/samples.dart';
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

/// Session-directory CSV/raw writer with ordered flush on teardown.
class CsvSink {
  CsvSink({required this.hub});

  final SampleHub hub;

  Directory? _sessionDir;
  IOSink? _eeg;
  IOSink? _motion;
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
  }) async {
    await stop();
    _closed = false;

    final preferred = (saveDirectory != null && saveDirectory.isNotEmpty)
        ? saveDirectory
        : null;

    Object? customError;
    if (preferred != null) {
      try {
        final path = await _openUnder(Directory(preferred), identity);
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
      final path = await _openUnder(docs, identity);
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

  Future<String> _openUnder(Directory base, DeviceIdentity identity) async {
    if (!await base.exists()) {
      await base.create(recursive: true);
    }
    await _probeWritable(base);

    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final sessionDir = Directory('${base.path}/session_$stamp');
    await sessionDir.create(recursive: true);

    final meta = {
      'deviceName': identity.deviceName,
      'btKeyHex': identity.btKeyHex,
      'keyFingerprint': identity.keyFingerprint,
      'startedAt': DateTime.now().toIso8601String(),
      'eegRateHz': EegSample.nominalRateHz,
      'motionRateHz': MotionSample.nominalRateHz,
      'eegChannels': EegSample.channelNames,
      'motionChannels': MotionSample.channelNames,
    };
    await File('${sessionDir.path}/session.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(meta),
    );

    _sessionDir = sessionDir;
    _eeg = File('${sessionDir.path}/eeg.csv').openWrite();
    _eeg!.writeln('wall_ms,mono_us,${EegSample.channelNames.join(',')}');

    _motion = File('${sessionDir.path}/motion.csv').openWrite();
    _motion!.writeln(
      'wall_ms,mono_us,${MotionSample.channelNames.join(',')}',
    );

    _raw = File('${sessionDir.path}/raw.csv').openWrite();
    _raw!.writeln('wall_ms,mono_us,kind,bytes');

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
      _eeg?.writeln(
        '${s.wallClock.millisecondsSinceEpoch},${s.receiveMonoUs},${s.values.join(',')}',
      );
    }
    for (final s in hub.takeCsvMotion()) {
      _motion?.writeln(
        '${s.wallClock.millisecondsSinceEpoch},${s.receiveMonoUs},${s.values.join(',')}',
      );
    }
    for (final p in hub.takeCsvRaw()) {
      _raw?.writeln(
        '${p.wallClock.millisecondsSinceEpoch},${p.receiveMonoUs},${p.kind.name},${p.bytes.join(' ')}',
      );
    }
  }

  Future<void> flush() async {
    _drain();
    await _eeg?.flush();
    await _motion?.flush();
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
      await _raw?.close();
    } catch (_) {}
    _eeg = null;
    _motion = null;
    _raw = null;
  }
}
