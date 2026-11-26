import 'dart:typed_data';

import '../domain/samples.dart';
import 'contact_quality_tier.dart';

/// Lightweight immutable snapshot emitted at <=20 Hz for plot CustomPainters.
class LiveEegPlotSnapshot {
  const LiveEegPlotSnapshot({
    required this.revision,
    required this.channelCount,
    required this.sampleCount,
    required this.downsampledChannels,
    required this.latestOverallCq,
    required this.latestChannelGrades,
    required this.cqHistoryTiers,
    required this.cqHistoryChannelTiers,
    this.lastWallClock,
  });

  static final LiveEegPlotSnapshot empty = LiveEegPlotSnapshot(
    revision: 0,
    channelCount: EegSample.channelCount,
    sampleCount: 0,
    downsampledChannels: const [],
    latestOverallCq: 0,
    latestChannelGrades: Uint8List(EegSample.channelCount),
    cqHistoryTiers: Uint8List(0),
    cqHistoryChannelTiers: Uint8List(0),
    lastWallClock: null,
  );

  /// Monotonically increasing revision so `shouldRepaint` is O(1).
  final int revision;
  final int channelCount;

  /// Total valid EEG samples currently in the ring window (`0..windowSamples`).
  final int sampleCount;

  /// Per-channel downsampled microvolt series (chronological, oldest -> newest),
  /// each normalized/drawn independently by `EegStackedLanePlot`.
  final List<Float64List> downsampledChannels;

  /// Latest overall Contact Quality percentage (`0..100`).
  final int latestOverallCq;

  /// Latest per-channel discrete Cortex CQ grades (`0, 1, 2, 4`) in `AF3..AF4` order.
  final Uint8List latestChannelGrades;

  /// Immutable committed summary CQ tier indices (`0..4`), oldest -> newest.
  final Uint8List cqHistoryTiers;

  /// Immutable committed per-electrode CQ tier indices (`0..4`), oldest -> newest,
  /// stored as `bin * channelCount + ch` (`bins == cqHistoryTiers.length`).
  final Uint8List cqHistoryChannelTiers;

  final DateTime? lastWallClock;

  ContactQualityTier get latestTier =>
      ContactQualityTier.fromOverallPercent(latestOverallCq);

  bool get hasSamples => sampleCount > 0 && downsampledChannels.isNotEmpty;
}

/// Preallocated circular EEG buffer + fixed-cadence immutable per-electrode CQ history.
class LiveEegRingBuffer {
  LiveEegRingBuffer({
    this.channelCount = EegSample.channelCount,
    this.windowSamples = defaultWindowSamples,
    this.targetDrawPoints = defaultTargetDrawPoints,
    this.cqBinDurationUs = defaultCqBinDurationUs,
    this.cqHistoryBins = defaultCqHistoryBins,
  })  : assert(channelCount > 0),
        assert(windowSamples >= 4),
        assert(targetDrawPoints >= 3),
        assert(cqBinDurationUs > 0),
        assert(cqHistoryBins > 0),
        _data = Float64List(channelCount * windowSamples),
        _latestChannelGrades = Uint8List(channelCount),
        _cqRing = Uint8List(cqHistoryBins),
        _cqChannelRing = Uint8List(cqHistoryBins * channelCount),
        _pendingChannelTiers = Uint8List(channelCount),
        _scratch = Float64List(windowSamples);

  /// ~3 s @ 128 Hz.
  static const int defaultWindowSamples = 384;

  /// ~10 pts/s over a 3 s window, matching pyPhoTimeline live EEG cap.
  static const int defaultTargetDrawPoints = 48;

  /// 250 ms per committed CQ cell (~4 cells/s).
  static const int defaultCqBinDurationUs = 250000;

  /// 60 bins * 250 ms = 15 s of scrolling CQ history.
  static const int defaultCqHistoryBins = 60;

  final int channelCount;
  final int windowSamples;
  final int targetDrawPoints;
  final int cqBinDurationUs;
  final int cqHistoryBins;

  /// Channel-major storage: channel `c`, slot `s` lives at `c * windowSamples + s`.
  final Float64List _data;
  final Float64List _scratch;

  int _writeIndex = 0;
  int _length = 0;
  int _latestOverallCq = 0;
  final Uint8List _latestChannelGrades;
  DateTime? _lastWallClock;
  int _revision = 0;

  // Fixed-grid CQ history state (prevents retroactive cell flicker).
  final Uint8List _cqRing;
  final Uint8List _cqChannelRing;
  final Uint8List _pendingChannelTiers;
  int _cqWrite = 0;
  int _cqLength = 0;
  int? _currentBinIndex;
  int _pendingBinTier = 0;

  int get length => _length;
  int get writeIndex => _writeIndex;
  int get latestOverallCq => _latestOverallCq;
  Uint8List get latestChannelGrades => Uint8List.fromList(_latestChannelGrades);
  DateTime? get lastWallClock => _lastWallClock;
  int get cqHistoryLength => _cqLength;

  void clear() {
    _data.fillRange(0, _data.length, 0.0);
    _latestChannelGrades.fillRange(0, _latestChannelGrades.length, 0);
    _cqRing.fillRange(0, _cqRing.length, 0);
    _cqChannelRing.fillRange(0, _cqChannelRing.length, 0);
    _pendingChannelTiers.fillRange(0, _pendingChannelTiers.length, 0);
    _writeIndex = 0;
    _length = 0;
    _latestOverallCq = 0;
    _lastWallClock = null;
    _cqWrite = 0;
    _cqLength = 0;
    _currentBinIndex = null;
    _pendingBinTier = 0;
    _revision++;
  }

  void pushAll(Iterable<EegSample> samples) {
    for (final s in samples) {
      push(s);
    }
  }

  void push(EegSample sample) {
    final values = sample.values;
    final n = values.length < channelCount ? values.length : channelCount;
    final slot = _writeIndex;
    for (var c = 0; c < n; c++) {
      _data[c * windowSamples + slot] = values[c];
    }
    for (var c = n; c < channelCount; c++) {
      _data[c * windowSamples + slot] = 0.0;
    }

    _writeIndex = (slot + 1) % windowSamples;
    if (_length < windowSamples) {
      _length++;
    }

    final grades = sample.contactQualityGrades;
    var gradeSum = 0;
    for (var c = 0; c < channelCount; c++) {
      final g = c < grades.length ? grades[c].clamp(0, 4) : 0;
      _latestChannelGrades[c] = g;
      gradeSum += g;
    }
    final computedOverall =
        ((gradeSum * 100.0) / (channelCount * 4.0)).round().clamp(0, 100);
    _latestOverallCq =
        sample.overallCq > 0 ? sample.overallCq : computedOverall;
    _lastWallClock = sample.wallClock;
    _ingestCqSample(sample.receiveMonoUs, _latestOverallCq, _latestChannelGrades);
    _revision++;
  }

  void _ingestCqSample(
    int monoUs,
    int overallCq,
    Uint8List channelGrades,
  ) {
    final summaryTier = ContactQualityTier.fromOverallPercent(overallCq).index_;
    final binIdx = monoUs ~/ cqBinDurationUs;

    void updatePendingChannels() {
      for (var c = 0; c < channelCount; c++) {
        _pendingChannelTiers[c] =
            ContactQualityTier.fromCortexGrade(channelGrades[c]).index_;
      }
    }

    final cur = _currentBinIndex;
    if (cur == null) {
      _currentBinIndex = binIdx;
      _pendingBinTier = summaryTier;
      updatePendingChannels();
      return;
    }

    if (binIdx <= cur) {
      _pendingBinTier = summaryTier;
      updatePendingChannels();
      return;
    }

    // Commit the completed bin immutably.
    _commitCqBin(_pendingBinTier, _pendingChannelTiers);

    // Forward-fill any skipped bins (capped to ring size) with the last known tiers.
    final gap = binIdx - cur - 1;
    if (gap > 0) {
      final fillCount = gap > cqHistoryBins ? cqHistoryBins : gap;
      for (var i = 0; i < fillCount; i++) {
        _commitCqBin(_pendingBinTier, _pendingChannelTiers);
      }
    }

    _currentBinIndex = binIdx;
    _pendingBinTier = summaryTier;
    updatePendingChannels();
  }

  void _commitCqBin(int summaryTier, Uint8List channelTiers) {
    final dstSlot = _cqWrite;
    _cqRing[dstSlot] = summaryTier;
    final base = dstSlot * channelCount;
    for (var c = 0; c < channelCount; c++) {
      _cqChannelRing[base + c] = channelTiers[c];
    }
    _cqWrite = (dstSlot + 1) % cqHistoryBins;
    if (_cqLength < cqHistoryBins) {
      _cqLength++;
    }
  }

  /// Copy channel [channel] in chronological order (oldest -> newest).
  Float64List readChannelChronological(int channel) {
    RangeError.checkValidIndex(channel, List<int>.filled(channelCount, 0));
    final out = Float64List(_length);
    _copyChannelInto(channel, out);
    return out;
  }

  void _copyChannelInto(int channel, Float64List dest) {
    final base = channel * windowSamples;
    if (_length < windowSamples) {
      for (var i = 0; i < _length; i++) {
        dest[i] = _data[base + i];
      }
      return;
    }
    final oldest = _writeIndex;
    final firstPart = windowSamples - oldest;
    for (var i = 0; i < firstPart; i++) {
      dest[i] = _data[base + oldest + i];
    }
    for (var i = 0; i < oldest; i++) {
      dest[firstPart + i] = _data[base + i];
    }
  }

  /// Build an immutable snapshot for UI painting, downsampling each channel
  /// with LTTB to at most [maxPoints] (defaults to [targetDrawPoints]).
  LiveEegPlotSnapshot snapshot({int? maxPoints}) {
    final (summaryHist, channelHist) = _buildCqHistorySnapshots();
    if (_length == 0) {
      return LiveEegPlotSnapshot(
        revision: _revision,
        channelCount: channelCount,
        sampleCount: 0,
        downsampledChannels: const [],
        latestOverallCq: _latestOverallCq,
        latestChannelGrades: Uint8List.fromList(_latestChannelGrades),
        cqHistoryTiers: summaryHist,
        cqHistoryChannelTiers: channelHist,
        lastWallClock: _lastWallClock,
      );
    }

    final cap = maxPoints ?? targetDrawPoints;
    final channels = List<Float64List>.generate(channelCount, (c) {
      _copyChannelInto(c, _scratch);
      return lttbDownsampleUniform(_scratch, _length, cap);
    }, growable: false);

    return LiveEegPlotSnapshot(
      revision: _revision,
      channelCount: channelCount,
      sampleCount: _length,
      downsampledChannels: channels,
      latestOverallCq: _latestOverallCq,
      latestChannelGrades: Uint8List.fromList(_latestChannelGrades),
      cqHistoryTiers: summaryHist,
      cqHistoryChannelTiers: channelHist,
      lastWallClock: _lastWallClock,
    );
  }

  (Uint8List, Uint8List) _buildCqHistorySnapshots() {
    final includePending = _currentBinIndex != null ? 1 : 0;
    final committedCount = _cqLength;
    final total = committedCount + includePending;
    if (total == 0) return (Uint8List(0), Uint8List(0));

    final cappedCommitted =
        committedCount >= cqHistoryBins && includePending == 1
            ? cqHistoryBins - 1
            : committedCount;
    final outLen = cappedCommitted + includePending;
    final outSummary = Uint8List(outLen);
    final outChannels = Uint8List(outLen * channelCount);

    final startLogical = committedCount - cappedCommitted;
    final ringOldest = _cqLength < cqHistoryBins ? 0 : _cqWrite;
    for (var i = 0; i < cappedCommitted; i++) {
      final idx = (ringOldest + startLogical + i) % cqHistoryBins;
      outSummary[i] = _cqRing[idx];
      final srcBase = idx * channelCount;
      final dstBase = i * channelCount;
      for (var c = 0; c < channelCount; c++) {
        outChannels[dstBase + c] = _cqChannelRing[srcBase + c];
      }
    }
    if (includePending == 1) {
      final lastIdx = outLen - 1;
      outSummary[lastIdx] = _pendingBinTier;
      final dstBase = lastIdx * channelCount;
      for (var c = 0; c < channelCount; c++) {
        outChannels[dstBase + c] = _pendingChannelTiers[c];
      }
    }
    return (outSummary, outChannels);
  }

  /// Largest-Triangle-Three-Buckets (LTTB) downsampler for uniform-x series.
  static Float64List lttbDownsampleUniform(
    Float64List series,
    int length,
    int maxPoints,
  ) {
    if (length <= 0) return Float64List(0);
    final effectiveMax = maxPoints < 3 ? (length < 3 ? length : 3) : maxPoints;
    if (length <= effectiveMax) {
      final copy = Float64List(length);
      for (var i = 0; i < length; i++) {
        copy[i] = series[i];
      }
      return copy;
    }

    final out = Float64List(effectiveMax);
    out[0] = series[0];
    out[effectiveMax - 1] = series[length - 1];

    final bucketSize = (length - 2) / (effectiveMax - 2);
    var prevIdx = 0;

    for (var i = 1; i < effectiveMax - 1; i++) {
      final rangeStart = ((i - 1) * bucketSize).floor() + 1;
      var rangeEnd = (i * bucketSize).floor() + 1;
      if (rangeEnd > length - 1) rangeEnd = length - 1;

      final nextStart = (i * bucketSize).floor() + 1;
      var nextEnd = ((i + 1) * bucketSize).floor() + 1;
      if (nextEnd > length - 1) nextEnd = length - 1;

      double nextAvgX;
      double nextAvgY;
      if (nextStart < nextEnd) {
        final count = nextEnd - nextStart;
        nextAvgX = (nextStart + nextEnd - 1) * 0.5;
        var sumY = 0.0;
        for (var k = nextStart; k < nextEnd; k++) {
          sumY += series[k];
        }
        nextAvgY = sumY / count;
      } else {
        nextAvgX = (length - 1).toDouble();
        nextAvgY = series[length - 1];
      }

      final prevX = prevIdx.toDouble();
      final prevY = series[prevIdx];
      final dxNext = nextAvgX - prevX;
      final dyNext = nextAvgY - prevY;

      var maxArea = -1.0;
      var bestIdx = rangeStart;
      for (var idx = rangeStart; idx < rangeEnd; idx++) {
        final y = series[idx];
        if (!y.isFinite) continue;
        final area = ((idx - prevX) * dyNext - dxNext * (y - prevY)).abs();
        if (area > maxArea) {
          maxArea = area;
          bestIdx = idx;
        }
      }

      out[i] = series[bestIdx];
      prevIdx = bestIdx;
    }

    return out;
  }
}
