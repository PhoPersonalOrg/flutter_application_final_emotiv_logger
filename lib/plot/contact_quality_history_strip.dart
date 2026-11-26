import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../domain/samples.dart';
import 'contact_quality_tier.dart';
import 'live_eeg_ring_buffer.dart';

/// Scrolling 14-electrode categorical contact-quality history heatmap.
///
/// Renders 14 independent electrode rows (`AF3..AF4`) separated by thin 1 px
/// gaps over fixed-duration committed time bins (`cqHistoryChannelTiers`),
/// falling back to 1D summary column tiers (`cqHistoryTiers`) when per-channel
/// bins are omitted.
class ContactQualityHistoryStrip extends StatelessWidget {
  const ContactQualityHistoryStrip({
    super.key,
    required this.cqHistoryTiers,
    this.cqHistoryChannelTiers,
    this.maxBins = LiveEegRingBuffer.defaultCqHistoryBins,
    this.channelCount = EegSample.channelCount,
    this.height = 44,
  });

  final Uint8List cqHistoryTiers;
  final Uint8List? cqHistoryChannelTiers;
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
                channelTiers: cqHistoryChannelTiers,
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
    required this.channelTiers,
    required this.maxBins,
    required this.channelCount,
  });

  final Uint8List tiers;
  final Uint8List? channelTiers;
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

    final visibleCount = n > cols ? cols : n;
    final srcStart = n - visibleCount;
    final startCol = cols - visibleCount;

    final cellPaint = Paint()..style = PaintingStyle.fill;
    final perCh = channelTiers;
    final hasPerChannel =
        perCh != null && channelCount > 0 && perCh.length == n * channelCount;

    if (hasPerChannel) {
      final rowH = usableHeight / channelCount;
      for (var ch = 0; ch < channelCount; ch++) {
        final y0 = _verticalPad + ch * rowH;
        final y1 = y0 + rowH;
        var runStart = 0;
        while (runStart < visibleCount) {
          final tierVal = perCh[(srcStart + runStart) * channelCount + ch];
          var runEnd = runStart + 1;
          while (runEnd < visibleCount &&
              perCh[(srcStart + runEnd) * channelCount + ch] == tierVal) {
            runEnd++;
          }
          final x0 = plotLeft + (startCol + runStart) * colWidth;
          final x1 = plotLeft + (startCol + runEnd) * colWidth;
          cellPaint.color = ContactQualityTier.fromTierIndex(tierVal).color;
          canvas.drawRect(Rect.fromLTRB(x0, y0, x1, y1), cellPaint);
          runStart = runEnd;
        }
      }
    } else {
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
    }

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
        oldDelegate.tiers.length != tiers.length ||
        oldDelegate.channelTiers?.length != channelTiers?.length) {
      return true;
    }
    final aCh = oldDelegate.channelTiers;
    final bCh = channelTiers;
    if (aCh != null && bCh != null) {
      for (var i = 0; i < aCh.length; i++) {
        if (aCh[i] != bCh[i]) return true;
      }
    }
    for (var i = 0; i < tiers.length; i++) {
      if (oldDelegate.tiers[i] != tiers[i]) return true;
    }
    return false;
  }
}
