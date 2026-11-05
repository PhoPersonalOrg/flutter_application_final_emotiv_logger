import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../decode/device_identity.dart';
import '../domain/samples.dart';
import 'sample_hub.dart';

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

  Future<String> startSession({
    required String? saveDirectory,
    required DeviceIdentity identity,
  }) async {
    await stop();
    _closed = false;

    final base = await _resolveBase(saveDirectory);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    _sessionDir = Directory('${base.path}/session_$stamp');
    await _sessionDir!.create(recursive: true);

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
    await File('${_sessionDir!.path}/session.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(meta),
    );

    _eeg = File('${_sessionDir!.path}/eeg.csv').openWrite();
    _eeg!.writeln('wall_ms,mono_us,${EegSample.channelNames.join(',')}');

    _motion = File('${_sessionDir!.path}/motion.csv').openWrite();
    _motion!.writeln(
      'wall_ms,mono_us,${MotionSample.channelNames.join(',')}',
    );

    _raw = File('${_sessionDir!.path}/raw.csv').openWrite();
    _raw!.writeln('wall_ms,mono_us,kind,bytes');

    _flushTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(flush());
    });
    _sub = hub.csvAvailable.listen((_) => _drain());
    return _sessionDir!.path;
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
    await flush();
    await _eeg?.close();
    await _motion?.close();
    await _raw?.close();
    _eeg = null;
    _motion = null;
    _raw = null;
  }

  Future<Directory> _resolveBase(String? saveDirectory) async {
    if (saveDirectory != null && saveDirectory.isNotEmpty) {
      final d = Directory(saveDirectory);
      if (!await d.exists()) {
        await d.create(recursive: true);
      }
      return d;
    }
    return getApplicationDocumentsDirectory();
  }
}
