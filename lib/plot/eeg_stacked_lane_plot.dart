import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../domain/samples.dart';
import 'live_eeg_ring_buffer.dart';

/// 14-channel stacked raw EEG strip modeled after pyPhoTimeline's
/// `EEGPlotDetailRenderer` (`ChannelNormalizationMode.INDIVIDUAL`).
///
/// Uses a pure `CustomPainter` over pre-downsampled `Float64List` series — no
/// third-party chart widgets — so 20 Hz repaints stay sub-millisecond.
class EegStackedLanePlot extends StatelessWidget {
  const EegStackedLanePlot({
    super.key,
    required this.snapshot,
    this.streaming = true,
    this.channelNames = EegSample.channelNames,
    this.height = 196,
  });

  final LiveEegPlotSnapshot snapshot;
  final bool streaming;
  final List<String> channelNames;
  final double height;

  /// High-contrast 14-channel spectral palette inspired by pyPhoTimeline's
  /// `nipy_spectral` channel colors, tuned for dark EEG plot backgrounds.
  static const List<Color> channelPalette = [
    Color(0xFF9C6ADE), // AF3
    Color(0xFF64B5F6), // F7
    Color(0xFF4FC3F7), // F3
    Color(0xFF26C6DA), // FC5
    Color(0xFF26A69A), // T7
    Color(0xFF66BB6A), // P7
    Color(0xFF9CCC65), // O1
    Color(0xFFD4E157), // O2
    Color(0xFFFFEE58), // P8
    Color(0xFFFFCA28), // T8
    Color(0xFFFFA726), // FC6
    Color(0xFFFF7043), // F4
    Color(0xFFEF5350), // F8
    Color(0xFFEC407A), // AF4
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ColoredBox(
          color: const Color(0xFF14181F),
          child: RepaintBoundary(
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: _EegStackedLanePainter(
                    snapshot: snapshot,
                    channelNames: channelNames,
                  ),
                ),
                if (!snapshot.hasSamples)
                  Center(
                    child: Text(
                      streaming
                          ? 'Waiting for EEG packets…'
                          : 'Idle — connect headset to stream raw EEG',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.white70,
                          ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EegStackedLanePainter extends CustomPainter {
  _EegStackedLanePainter({
    required this.snapshot,
    required this.channelNames,
  });

  final LiveEegPlotSnapshot snapshot;
  final List<String> channelNames;

  static const double _labelGutterWidth = 34.0;
  static const double _rightPad = 6.0;
  static const double _verticalPad = 4.0;
  static const double _laneInnerMarginFrac = 0.12;

  @override
  void paint(Canvas canvas, Size size) {
    final laneCount = channelNames.length;
    if (laneCount == 0 || size.width <= _labelGutterWidth + _rightPad) return;

    final usableHeight = (size.height - 2 * _verticalPad).clamp(1.0, size.height);
    final laneHeight = usableHeight / laneCount;
    final plotLeft = _labelGutterWidth;
    final plotRight = size.width - _rightPad;
    final plotWidth = plotRight - plotLeft;

    // Subtle gutter separator + horizontal lane guides.
    final gridPaint = Paint()
      ..color = const Color(0x1FFFFFFF)
      ..strokeWidth = 0.5;
    canvas.drawLine(
      Offset(plotLeft, 0),
      Offset(plotLeft, size.height),
      gridPaint,
    );

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: 1,
    );

    final fontSize = (laneHeight * 0.68).clamp(7.5, 10.0);

    for (var ch = 0; ch < laneCount; ch++) {
      final laneTop = _verticalPad + ch * laneHeight;
      final laneCenterY = laneTop + laneHeight * 0.5;

      if (ch > 0) {
        canvas.drawLine(
          Offset(plotLeft, laneTop),
          Offset(plotRight, laneTop),
          gridPaint,
        );
      }

      final color = EegStackedLanePlot
          .channelPalette[ch % EegStackedLanePlot.channelPalette.length];

      textPainter.text = TextSpan(
        text: channelNames[ch],
        style: TextStyle(
          color: color.withValues(alpha: 0.92),
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          height: 1.0,
        ),
      );
      textPainter.layout(maxWidth: _labelGutterWidth - 4);
      textPainter.paint(
        canvas,
        Offset(
          _labelGutterWidth - textPainter.width - 4,
          laneCenterY - textPainter.height * 0.5,
        ),
      );

      if (!snapshot.hasSamples || ch >= snapshot.downsampledChannels.length) {
        continue;
      }

      final series = snapshot.downsampledChannels[ch];
      _drawNormalizedSeries(
        canvas: canvas,
        series: series,
        left: plotLeft,
        width: plotWidth,
        laneTop: laneTop,
        laneHeight: laneHeight,
        color: color,
      );
    }
  }

  void _drawNormalizedSeries({
    required Canvas canvas,
    required Float64List series,
    required double left,
    required double width,
    required double laneTop,
    required double laneHeight,
    required Color color,
  }) {
    final n = series.length;
    if (n == 0) return;

    var vMin = double.infinity;
    var vMax = double.negativeInfinity;
    for (var i = 0; i < n; i++) {
      final v = series[i];
      if (!v.isFinite) continue;
      if (v < vMin) vMin = v;
      if (v > vMax) vMax = v;
    }

    if (!vMin.isFinite || !vMax.isFinite) return;

    final span = vMax - vMin;
    final innerTop = laneTop + laneHeight * _laneInnerMarginFrac;
    final innerHeight = laneHeight * (1.0 - 2.0 * _laneInnerMarginFrac);

    final wavePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.05
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    if (n == 1) {
      final y = innerTop + innerHeight * 0.5;
      canvas.drawLine(Offset(left, y), Offset(left + width, y), wavePaint);
      return;
    }

    final dx = width / (n - 1);
    final path = Path();
    var started = false;

    for (var i = 0; i < n; i++) {
      final v = series[i];
      if (!v.isFinite) {
        started = false;
        continue;
      }
      // INDIVIDUAL min-max normalization into [0, 1] (inverted for screen Y).
      final norm = span <= 1e-9 ? 0.5 : ((v - vMin) / span).clamp(0.0, 1.0);
      final x = left + i * dx;
      final y = innerTop + innerHeight * (1.0 - norm);
      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
    }

    if (started) {
      canvas.drawPath(path, wavePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _EegStackedLanePainter oldDelegate) {
    return oldDelegate.snapshot.revision != snapshot.revision ||
        oldDelegate.channelNames != channelNames;
  }
}
