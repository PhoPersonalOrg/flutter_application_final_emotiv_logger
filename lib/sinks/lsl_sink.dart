import 'dart:async';
import 'dart:io';

import 'package:liblsl/lsl.dart';

import '../app/settings.dart';
import '../domain/acquisition_health.dart';
import '../domain/samples.dart';
import 'sample_hub.dart';

/// Normalizes the configured LSL outlet hostname, falling back to
/// [AppSettings.defaultHostname] when empty or whitespace.
String resolveLslHostname(String? raw) {
  final trimmed = raw?.trim() ?? '';
  return trimmed.isEmpty ? AppSettings.defaultHostname : trimmed;
}

/// In-process LSL outlets backed by vendored `liblsl`.
/// Creation failure -> [LslSubsystemStatus.degraded], session continues.
class LslSink {
  LslSink({
    required this.hub,
    required this.onHealth,
  });

  final SampleHub hub;
  final void Function(AcquisitionHealth Function(AcquisitionHealth)) onHealth;

  LSLStreamInfoWithMetadata? _eegInfo;
  LSLStreamInfoWithMetadata? _qualityInfo;
  LSLStreamInfoWithMetadata? _motionInfo;
  LSLOutlet? _eegOutlet;
  LSLOutlet? _qualityOutlet;
  LSLOutlet? _motionOutlet;

  StreamSubscription<void>? _sub;
  Future<void>? _activeDrain;
  bool _drainPending = false;
  bool _active = false;

  int _eegOk = 0;
  int _eegFail = 0;
  int _qualityOk = 0;
  int _qualityFail = 0;
  int _motionOk = 0;
  int _motionFail = 0;

  Future<LslSubsystemStatus> start({
    required bool enabled,
    required String sourceId,
    String hostname = AppSettings.defaultHostname,
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

    final effectiveHostname = resolveLslHostname(hostname);

    try {
      final platform = Platform.operatingSystem;

      _eegInfo = await LSL.createStreamInfo(
        streamName: 'Epoc X',
        streamType: LSLContentType.eeg,
        channelCount: EegSample.channelCount,
        sampleRate: EegSample.nominalRateHz,
        channelFormat: LSLChannelFormat.float32,
        sourceId: sourceId,
        hostname: effectiveHostname,
      );
      _addChannelMetadata(
        _eegInfo!,
        labels: EegSample.channelNames,
        unit: 'microvolts',
        channelType: 'EEG',
      );
      _eegOutlet = await LSL
          .createOutlet(
            streamInfo: _eegInfo!,
            chunkSize: 0,
            maxBuffer: 360,
          )
          .timeout(const Duration(seconds: 10));

      try {
        _qualityInfo = await LSL.createStreamInfo(
          streamName: EegSample.qualityStreamName,
          streamType: LSLContentType.custom(EegSample.qualityStreamType),
          channelCount: EegSample.channelCount,
          sampleRate: EegSample.nominalRateHz,
          channelFormat: LSLChannelFormat.float32,
          sourceId: sourceId,
          hostname: effectiveHostname,
        );
        _addChannelMetadata(
          _qualityInfo!,
          labels: EegSample.qualityChannelNames,
          unit: 'cq',
          channelType: 'CQ',
        );
        _qualityOutlet = await LSL
            .createOutlet(
              streamInfo: _qualityInfo!,
              chunkSize: 0,
              maxBuffer: 360,
            )
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        try {
          await _qualityOutlet?.destroy();
        } catch (_) {}
        try {
          _qualityInfo?.destroy();
        } catch (_) {}
        _qualityOutlet = null;
        _qualityInfo = null;
      }

      try {
        _motionInfo = await LSL.createStreamInfo(
          streamName: 'Epoc X Motion',
          streamType: LSLContentType.custom('Accelerometer'),
          channelCount: MotionSample.channelCount,
          sampleRate: MotionSample.nominalRateHz,
          channelFormat: LSLChannelFormat.float32,
          sourceId: sourceId,
          hostname: effectiveHostname,
        );
        _addChannelMetadata(
          _motionInfo!,
          labels: MotionSample.channelNames,
          unit: 'raw',
          channelType: 'Accelerometer',
        );
        _motionOutlet = await LSL
            .createOutlet(
              streamInfo: _motionInfo!,
              chunkSize: 0,
              maxBuffer: 360,
            )
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        try {
          await _motionOutlet?.destroy();
        } catch (_) {}
        try {
          _motionInfo?.destroy();
        } catch (_) {}
        _motionOutlet = null;
        _motionInfo = null;
      }

      _active = true;
      _sub = hub.lslAvailable.listen((_) => _scheduleDrain());
      _scheduleDrain();
      onHealth(
        (h) => h.copyWith(
          lslStatus: LslSubsystemStatus.active,
          lslMessage: 'LSL active ($effectiveHostname) on $platform',
        ),
      );
      return LslSubsystemStatus.active;
    } catch (e) {
      await _cleanupOutlets();
      onHealth(
        (h) => h.copyWith(
          lslStatus: LslSubsystemStatus.degraded,
          lslMessage: 'LSL unavailable: $e',
        ),
      );
      return LslSubsystemStatus.degraded;
    }
  }

  void _addChannelMetadata(
    LSLStreamInfoWithMetadata info, {
    required List<String> labels,
    required String unit,
    required String channelType,
  }) {
    try {
      final root = info.description.value;
      final channels = root.addChildElement('channels');
      for (final label in labels) {
        final ch = channels.addChildElement('channel');
        ch.addChildValue('label', label);
        ch.addChildValue('unit', unit);
        ch.addChildValue('type', channelType);
      }
    } catch (_) {}
  }

  void _scheduleDrain() {
    if (!_active) return;
    if (_activeDrain != null) {
      _drainPending = true;
      return;
    }
    _activeDrain = _runDrainLoop().whenComplete(() {
      _activeDrain = null;
    });
  }

  Future<void> _runDrainLoop() async {
    do {
      _drainPending = false;
      if (!_active || _eegOutlet == null) return;

      for (final s in hub.takeLslEeg()) {
        if (!_active || _eegOutlet == null) return;
        var eegPushed = false;
        try {
          await _eegOutlet!.pushSample(s.values);
          _eegOk++;
          eegPushed = true;
        } catch (_) {
          _eegFail++;
        }
        if (eegPushed && _qualityOutlet != null && _active) {
          try {
            await _qualityOutlet!.pushSample(s.qualityBroadcastValues());
            _qualityOk++;
          } catch (_) {
            _qualityFail++;
          }
        }
      }

      if (_motionOutlet != null && _active) {
        for (final s in hub.takeLslMotion()) {
          if (!_active || _motionOutlet == null) return;
          try {
            await _motionOutlet!.pushSample(s.values);
            _motionOk++;
          } catch (_) {
            _motionFail++;
          }
        }
      }
    } while (_drainPending && _active);
  }

  Future<void> stop() async {
    _active = false;
    _drainPending = false;
    await _sub?.cancel();
    _sub = null;
    final inflight = _activeDrain;
    if (inflight != null) {
      try {
        await inflight;
      } catch (_) {}
    }
    await _cleanupOutlets();
    onHealth(
      (h) => h.copyWith(
        lslStatus: LslSubsystemStatus.idle,
        lslMessage: 'LSL stopped (eeg ok=$_eegOk fail=$_eegFail '
            'quality ok=$_qualityOk fail=$_qualityFail '
            'motion ok=$_motionOk fail=$_motionFail)',
      ),
    );
    _eegOk = _eegFail = _qualityOk = _qualityFail = _motionOk = _motionFail = 0;
  }

  Future<void> _cleanupOutlets() async {
    try {
      await _eegOutlet?.destroy();
    } catch (_) {}
    try {
      await _qualityOutlet?.destroy();
    } catch (_) {}
    try {
      await _motionOutlet?.destroy();
    } catch (_) {}
    try {
      _eegInfo?.destroy();
    } catch (_) {}
    try {
      _qualityInfo?.destroy();
    } catch (_) {}
    try {
      _motionInfo?.destroy();
    } catch (_) {}
    _eegOutlet = null;
    _qualityOutlet = null;
    _motionOutlet = null;
    _eegInfo = null;
    _qualityInfo = null;
    _motionInfo = null;
  }
}
