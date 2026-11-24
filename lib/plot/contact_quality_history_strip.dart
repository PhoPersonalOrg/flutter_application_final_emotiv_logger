import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../domain/samples.dart';
import 'contact_quality_tier.dart';
import 'live_eeg_ring_buffer.dart';

/// Scrolling categorical contact-quality history heatmap modeled after
/// pyPhoTimeline's `EEGQualityHeatmapDetailRenderer` + `quality_heatmap.py`.
///
/// Renders 14 electrode bands separated by thin 1 px gaps over fixed-duration
/// committed time bins (`LiveEegRingBuffer.cqHistoryTiers`), so committed past
/// columns translate smoothly and never flicker retroactively.
class ContactQualityHistoryStrip extends StatelessWidget {
  const ContactQualityHistoryStrip({
    super.key,
    required this.cqHistoryTiers,
    this.maxBins = LiveEegRingBuffer.defaultCqHistoryBins,
    this.channelCount = EegSample.channelCount,
    this.height = 44,
  });

  final Uint8List cqHistoryTiers;
  final int maxBins;
  final int channelCount;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: ColoredBox(
          color: const Color(0xFF14181F),
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _ContactQualityHistoryPainter(
                tiers: cqHistoryTiers,
                maxBins: maxBins,
                channelCount: channelCount,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ContactQualityHistoryPainter extends CustomPainter {
  _ContactQualityHistoryPainter({
    required this.tiers,
    required this.maxBins,
    required this.channelCount,
  });

  final Uint8List tiers;
  final int maxBins;
  final int channelCount;

  static const double _labelGutterWidth = 34.0;
  static const double _rightPad = 6.0;
  static const double _verticalPad = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= _labelGutterWidth + _rightPad || size.height <= 4) {
      return;
    }

    // Left label ("EEGQ") aligned with EegStackedLanePlot's 34 px channel gutter.
    final tp = TextPainter(
      text: const TextSpan(
        text: 'CQ',
        style: TextStyle(
          color: Colors.white70,
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: _labelGutterWidth - 4);
    tp.paint(
      canvas,
      Offset(
        _labelGutterWidth - tp.width - 4,
        (size.height - tp.height) * 0.5,
      ),
    );

    final plotLeft = _labelGutterWidth;
    final plotRight = size.width - _rightPad;
    final plotWidth = plotRight - plotLeft;
    final usableHeight = size.height - 2 * _verticalPad;

    canvas.drawLine(
      Offset(plotLeft, 0),
      Offset(plotLeft, size.height),
      Paint()
        ..color = const Color(0x1FFFFFFF)
        ..strokeWidth = 0.5,
    );

    final cols = maxBins > 0 ? maxBins : 60;
    final colWidth = plotWidth / cols;
    final n = tiers.length;
    if (n == 0) return;

    // Right-align live edge so newest committed bin sits at the right playhead,
    // scrolling leftward as history fills.
    final visibleCount = n > cols ? cols : n;
    final srcStart = n - visibleCount;
    final startCol = cols - visibleCount;

    final cellPaint = Paint()..style = PaintingStyle.fill;

    // Merge contiguous columns of the same tier into a single rect per run for
    // minimal draw calls, then punch thin horizontal electrode row separators
    // matching pyPhoTimeline `insert_electrode_row_separators` (8:1 block:gap).
    var runStart = 0;
    while (runStart < visibleCount) {
      final tierVal = tiers[srcStart + runStart];
      var runEnd = runStart + 1;
      while (runEnd < visibleCount && tiers[srcStart + runEnd] == tierVal) {
        runEnd++;
      }

      final x0 = plotLeft + (startCol + runStart) * colWidth;
      final x1 = plotLeft + (startCol + runEnd) * colWidth;
      cellPaint.color = ContactQualityTier.fromTierIndex(tierVal).color;
      canvas.drawRect(
        Rect.fromLTRB(x0, _verticalPad, x1, _verticalPad + usableHeight),
        cellPaint,
      );
      runStart = runEnd;
    }

    // Thin dark horizontal separators so the strip reads as 14 electrode rows.
    if (channelCount > 1 && usableHeight >= channelCount * 2.0) {
      final sepPaint = Paint()
        ..color = const Color(0xB314181F)
        ..strokeWidth = 0.75;
      final rowH = usableHeight / channelCount;
      final filledLeft = plotLeft + startCol * colWidth;
      for (var r = 1; r < channelCount; r++) {
        final y = _verticalPad + r * rowH;
        canvas.drawLine(Offset(filledLeft, y), Offset(plotRight, y), sepPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ContactQualityHistoryPainter oldDelegate) {
    if (oldDelegate.maxBins != maxBins ||
        oldDelegate.channelCount != channelCount ||
        oldDelegate.tiers.length != tiers.length) {
      return true;
    }
    for (var i = 0; i < tiers.length; i++) {
      if (oldDelegate.tiers[i] != tiers[i]) return true;
    }
    return false;
  }
}
