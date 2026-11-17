import 'dart:async';
import 'dart:io';

import 'package:lsl_flutter/lsl_flutter.dart';

import '../domain/acquisition_health.dart';
import '../domain/samples.dart';
import 'sample_hub.dart';

/// In-process LSL outlet. Creation failure → [LslSubsystemStatus.degraded], session continues.
class LslSink {
  LslSink({
    required this.hub,
    required this.onHealth,
  });

  final SampleHub hub;
  final void Function(AcquisitionHealth Function(AcquisitionHealth)) onHealth;

  OutletWorker? _worker;
  StreamInfo? _eegInfo;
  StreamInfo? _motionInfo;
  StreamSubscription? _sub;
  bool _active = false;
  int _eegOk = 0;
  int _eegFail = 0;
  int _motionOk = 0;
  int _motionFail = 0;

  Future<LslSubsystemStatus> start({
    required bool enabled,
    required String sourceId,
  }) async {
    await stop();
    if (!enabled) {
      onHealth(
        (h) => h.copyWith(
          lslStatus: LslSubsystemStatus.disabled,
          lslMessage: 'LSL disabled in settings',
        ),
      );
      return LslSubsystemStatus.disabled;
    }

    try {
      final platform = Platform.operatingSystem;
      _eegInfo = StreamInfoFactory.createDoubleStreamInfo(
        'Epoc X',
        'EEG',
        Float32ChannelFormat(),
        channelCount: EegSample.channelCount,
        nominalSRate: EegSample.nominalRateHz,
        sourceId: sourceId,
      );
      _worker = await OutletWorker.spawn().timeout(
        const Duration(seconds: 10),
      );
      final eegAdded = await _worker!.addStream(_eegInfo!).timeout(
        const Duration(seconds: 5),
      );
      if (!eegAdded) {
        throw StateError('Failed to add EEG LSL stream');
      }

      try {
        _motionInfo = StreamInfoFactory.createDoubleStreamInfo(
          'Epoc X Motion',
          'Accelerometer',
          Float32ChannelFormat(),
          channelCount: MotionSample.channelCount,
          nominalSRate: MotionSample.nominalRateHz,
          sourceId: sourceId,
        );
        await _worker!.addStream(_motionInfo!);
      } catch (_) {
        _motionInfo = null;
      }

      _active = true;
      _sub = hub.lslAvailable.listen((_) => unawaited(_drain()));
      onHealth(
        (h) => h.copyWith(
          lslStatus: LslSubsystemStatus.active,
          lslMessage: 'LSL active on $platform',
        ),
      );
      return LslSubsystemStatus.active;
    } catch (e) {
      await _cleanupWorker();
      onHealth(
        (h) => h.copyWith(
          lslStatus: LslSubsystemStatus.degraded,
          lslMessage: 'LSL unavailable: $e',
        ),
      );
      return LslSubsystemStatus.degraded;
    }
  }

  Future<void> _drain() async {
    if (!_active || _worker == null) return;
    for (final s in hub.takeLslEeg()) {
      try {
        await _worker!.pushSample('Epoc X', s.values);
        _eegOk++;
      } catch (_) {
        _eegFail++;
      }
    }
    if (_motionInfo != null) {
      for (final s in hub.takeLslMotion()) {
        try {
          await _worker!.pushSample('Epoc X Motion', s.values);
          _motionOk++;
        } catch (_) {
          _motionFail++;
        }
      }
    }
  }

  Future<void> stop() async {
    _active = false;
    await _sub?.cancel();
    _sub = null;
    await _cleanupWorker();
    onHealth(
      (h) => h.copyWith(
        lslStatus: LslSubsystemStatus.idle,
        lslMessage: 'LSL stopped (eeg ok=$_eegOk fail=$_eegFail '
            'motion ok=$_motionOk fail=$_motionFail)',
      ),
    );
    _eegOk = _eegFail = _motionOk = _motionFail = 0;
  }

  Future<void> _cleanupWorker() async {
    try {
      if (_worker != null) {
        if (_eegInfo != null) {
          await _worker!.removeStream('Epoc X');
        }
        if (_motionInfo != null) {
          await _worker!.removeStream('Epoc X Motion');
        }
      }
    } catch (_) {}
    _worker = null;
    _eegInfo = null;
    _motionInfo = null;
  }
}
