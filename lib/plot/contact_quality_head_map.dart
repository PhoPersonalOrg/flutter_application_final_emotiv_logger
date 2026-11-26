import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/samples.dart';
import 'contact_quality_tier.dart';

/// Parsed `<circle id="CHANNEL" cx="..." cy="..." r="..."/>` hit region from
/// `assets/emotiv_epoc_x_head_layout.svg`, matching pyPhoTimeline's
/// `emotiv_epoc_x_electrode_layout.py`.
class EpocXElectrodeCircle {
  const EpocXElectrodeCircle({
    required this.channel,
    required this.cx,
    required this.cy,
    required this.r,
  });

  final String channel;
  final double cx;
  final double cy;
  final double r;
}

/// Parsed geometry from `assets/emotiv_epoc_x_head_layout.svg` (viewBox +
/// 14 electrode circles + headset silhouette paths).
class EpocXHeadSvgGeometry {
  const EpocXHeadSvgGeometry({
    required this.viewBox,
    required this.electrodes,
    required this.silhouettePaths,
  });

  final Rect viewBox;
  final Map<String, EpocXElectrodeCircle> electrodes;
  final List<EpocXStyledSvgPath> silhouettePaths;

  /// Fallback geometry identical to `emotiv_epoc_x_head_layout.svg` so widget
  /// builds/tests settle synchronously even before asset load completes.
  static const EpocXHeadSvgGeometry fallback = EpocXHeadSvgGeometry(
    viewBox: Rect.fromLTWH(0, 0, 262, 354),
    electrodes: {
      'AF3': EpocXElectrodeCircle(channel: 'AF3', cx: 99.15, cy: 94.51, r: 13.38),
      'F7': EpocXElectrodeCircle(channel: 'F7', cx: 55.81, cy: 108.91, r: 13.70),
      'F3': EpocXElectrodeCircle(channel: 'F3', cx: 98.11, cy: 153.93, r: 13.64),
      'FC5': EpocXElectrodeCircle(channel: 'FC5', cx: 57.70, cy: 155.72, r: 13.45),
      'T7': EpocXElectrodeCircle(channel: 'T7', cx: 28.90, cy: 182.72, r: 13.46),
      'P7': EpocXElectrodeCircle(channel: 'P7', cx: 66.01, cy: 267.30, r: 13.16),
      'O1': EpocXElectrodeCircle(channel: 'O1', cx: 99.33, cy: 312.35, r: 13.27),
      'O2': EpocXElectrodeCircle(channel: 'O2', cx: 167.83, cy: 312.34, r: 13.08),
      'P8': EpocXElectrodeCircle(channel: 'P8', cx: 201.00, cy: 267.30, r: 13.15),
      'T8': EpocXElectrodeCircle(channel: 'T8', cx: 238.92, cy: 183.02, r: 13.51),
      'FC6': EpocXElectrodeCircle(channel: 'FC6', cx: 209.18, cy: 156.05, r: 13.42),
      'F4': EpocXElectrodeCircle(channel: 'F4', cx: 167.40, cy: 153.93, r: 13.72),
      'F8': EpocXElectrodeCircle(channel: 'F8', cx: 209.71, cy: 108.92, r: 13.67),
      'AF4': EpocXElectrodeCircle(channel: 'AF4', cx: 167.50, cy: 94.52, r: 13.45),
    },
    silhouettePaths: [],
  );

  Rect computeContentBox({double margin = 14.0}) {
    if (electrodes.isEmpty) return viewBox;
    var minX = double.infinity;
    var maxX = double.negativeInfinity;
    var minY = double.infinity;
    var maxY = double.negativeInfinity;
    for (final c in electrodes.values) {
      minX = math.min(minX, c.cx - c.r);
      maxX = math.max(maxX, c.cx + c.r);
      minY = math.min(minY, c.cy - c.r);
      maxY = math.max(maxY, c.cy + c.r);
    }
    minX = math.max(viewBox.left, minX - margin);
    minY = math.max(viewBox.top, minY - margin);
    maxX = math.min(viewBox.right, maxX + margin);
    maxY = math.min(viewBox.bottom, maxY + margin);
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  static Future<EpocXHeadSvgGeometry>? _cachedFuture;

  static Future<EpocXHeadSvgGeometry> loadFromAsset([
    String assetPath = 'assets/emotiv_epoc_x_head_layout.svg',
  ]) {
    return _cachedFuture ??= _load(assetPath);
  }

  static Future<EpocXHeadSvgGeometry> _load(String assetPath) async {
    try {
      final raw = await rootBundle.loadString(assetPath);
      return parseSvgXml(raw);
    } catch (_) {
      return fallback;
    }
  }

  static final RegExp _viewBoxRe = RegExp(r'viewBox="([^"]+)"');
  static final RegExp _circleRe = RegExp(
    r'<circle\s+id="([A-Z0-9]+)"\s+cx="([0-9.]+)"\s+cy="([0-9.]+)"\s+r="([0-9.]+)"',
  );
  static final RegExp _groupPathRe = RegExp(
    r'<g(?:\s+transform="matrix\(1,0,0,1,(-?[0-9.]+),(-?[0-9.]+)\)")?>\s*<path\s+d="([^"]+)"\s+fill="([^"]+)"',
  );

  static EpocXHeadSvgGeometry parseSvgXml(String xml) {
    var viewBox = fallback.viewBox;
    final vbMatch = _viewBoxRe.firstMatch(xml);
    if (vbMatch != null) {
      final parts = vbMatch
          .group(1)!
          .replaceAll(',', ' ')
          .trim()
          .split(RegExp(r'\s+'))
          .map(double.tryParse)
          .whereType<double>()
          .toList();
      if (parts.length == 4) {
        viewBox = Rect.fromLTWH(parts[0], parts[1], parts[2], parts[3]);
      }
    }

    final expected = EegSample.channelNames.toSet();
    final electrodes = <String, EpocXElectrodeCircle>{};
    for (final m in _circleRe.allMatches(xml)) {
      final id = m.group(1)!;
      if (!expected.contains(id)) continue;
      final cx = double.tryParse(m.group(2)!);
      final cy = double.tryParse(m.group(3)!);
      final r = double.tryParse(m.group(4)!);
      if (cx != null && cy != null && r != null) {
        electrodes[id] = EpocXElectrodeCircle(
          channel: id,
          cx: cx,
          cy: cy,
          r: r,
        );
      }
    }
    if (electrodes.length < expected.length) {
      for (final entry in fallback.electrodes.entries) {
        electrodes.putIfAbsent(entry.key, () => entry.value);
      }
    }

    final silhouettePaths = <EpocXStyledSvgPath>[];
    for (final m in _groupPathRe.allMatches(xml)) {
      final tx = double.tryParse(m.group(1) ?? '0') ?? 0.0;
      final ty = double.tryParse(m.group(2) ?? '0') ?? 0.0;
      final d = m.group(3)!;
      final fillAttr = m.group(4)!;
      if (fillAttr == '#00c558' || fillAttr == '#dffef0') {
        continue;
      }
      final color = _resolveSvgFill(fillAttr);
      if (color == null) continue;
      final parsed = _tryParseSvgPath(d, tx: tx, ty: ty);
      if (parsed != null) {
        silhouettePaths.add(EpocXStyledSvgPath(path: parsed, color: color));
      }
    }

    return EpocXHeadSvgGeometry(
      viewBox: viewBox,
      electrodes: electrodes,
      silhouettePaths: silhouettePaths,
    );
  }

  static Color? _resolveSvgFill(String fillAttr) {
    if (fillAttr.startsWith('url(')) {
      return const Color(0xFFC5D5E8);
    }
    if (fillAttr == '#000000') return const Color(0xFF1E242B);
    if (fillAttr == '#99b3d5' || fillAttr == '#9ebac3') {
      return const Color(0xFF8DA9CC);
    }
    if (fillAttr == '#738286') return const Color(0xFF738286);
    if (fillAttr.startsWith('#') && fillAttr.length == 7) {
      final hex = int.tryParse(fillAttr.substring(1), radix: 16);
      if (hex != null) return Color(0xFF000000 | hex);
    }
    return null;
  }

  static final RegExp _pathTokenRe = RegExp(
    r'[MmLlCcQqZz]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?',
  );

  static Path? _tryParseSvgPath(
    String d, {
    double tx = 0.0,
    double ty = 0.0,
  }) {
    final tokens = _pathTokenRe.allMatches(d).map((m) => m.group(0)!).toList();
    if (tokens.isEmpty) return null;

    final path = Path();
    var i = 0;
    String? cmd;
    var curX = 0.0;
    var curY = 0.0;
    var startX = 0.0;
    var startY = 0.0;

    double nextNum() => double.parse(tokens[i++]);
    bool hasNum() =>
        i < tokens.length && !RegExp(r'^[A-Za-z]$').hasMatch(tokens[i]);

    try {
      while (i < tokens.length) {
        final t = tokens[i];
        if (RegExp(r'^[A-Za-z]$').hasMatch(t)) {
          cmd = t;
          i++;
        }
        switch (cmd) {
          case 'M':
            curX = nextNum();
            curY = nextNum();
            startX = curX;
            startY = curY;
            path.moveTo(curX + tx, curY + ty);
            cmd = 'L';
          case 'm':
            curX += nextNum();
            curY += nextNum();
            startX = curX;
            startY = curY;
            path.moveTo(curX + tx, curY + ty);
            cmd = 'l';
          case 'L':
            while (hasNum()) {
              curX = nextNum();
              curY = nextNum();
              path.lineTo(curX + tx, curY + ty);
            }
          case 'l':
            while (hasNum()) {
              curX += nextNum();
              curY += nextNum();
              path.lineTo(curX + tx, curY + ty);
            }
          case 'C':
            while (hasNum()) {
              final x1 = nextNum();
              final y1 = nextNum();
              final x2 = nextNum();
              final y2 = nextNum();
              curX = nextNum();
              curY = nextNum();
              path.cubicTo(
                x1 + tx,
                y1 + ty,
                x2 + tx,
                y2 + ty,
                curX + tx,
                curY + ty,
              );
            }
          case 'c':
            while (hasNum()) {
              final x1 = curX + nextNum();
              final y1 = curY + nextNum();
              final x2 = curX + nextNum();
              final y2 = curY + nextNum();
              curX += nextNum();
              curY += nextNum();
              path.cubicTo(
                x1 + tx,
                y1 + ty,
                x2 + tx,
                y2 + ty,
                curX + tx,
                curY + ty,
              );
            }
          case 'Q':
            while (hasNum()) {
              final x1 = nextNum();
              final y1 = nextNum();
              curX = nextNum();
              curY = nextNum();
              path.quadraticBezierTo(x1 + tx, y1 + ty, curX + tx, curY + ty);
            }
          case 'q':
            while (hasNum()) {
              final x1 = curX + nextNum();
              final y1 = curY + nextNum();
              curX += nextNum();
              curY += nextNum();
              path.quadraticBezierTo(x1 + tx, y1 + ty, curX + tx, curY + ty);
            }
          case 'Z':
          case 'z':
            path.close();
            curX = startX;
            curY = startY;
            cmd = null;
          default:
            return null;
        }
      }
      return path;
    } catch (_) {
      return null;
    }
  }
}

class EpocXStyledSvgPath {
  const EpocXStyledSvgPath({required this.path, required this.color});
  final Path path;
  final Color color;
}

/// Live Emotiv EPOC X 14-electrode per-channel contact-quality head map + legend.
class ContactQualityHeadMap extends StatefulWidget {
  const ContactQualityHeadMap({
    super.key,
    this.channelGrades,
    this.overallCq = 0,
    this.perChannelGrades,
    this.height = 148,
    this.showLegend = true,
  });

  /// 14 discrete Cortex CQ grades (`0, 1, 2, 4`) in `EegSample.channelNames` order.
  final List<int>? channelGrades;

  /// Optional fallback overall CQ percentage (`0..100`) when [channelGrades] is absent.
  final int overallCq;

  /// Optional named map of channel -> Cortex CQ grade (`0..4`).
  final Map<String, int>? perChannelGrades;

  final double height;
  final bool showLegend;

  @override
  State<ContactQualityHeadMap> createState() => _ContactQualityHeadMapState();
}

class _ContactQualityHeadMapState extends State<ContactQualityHeadMap> {
  EpocXHeadSvgGeometry _geometry = EpocXHeadSvgGeometry.fallback;

  @override
  void initState() {
    super.initState();
    EpocXHeadSvgGeometry.loadFromAsset().then((loaded) {
      if (mounted && !identical(loaded, _geometry)) {
        setState(() => _geometry = loaded);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final fallbackTier =
        ContactQualityTier.fromOverallPercent(widget.overallCq);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: widget.height,
          width: double.infinity,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _ContactQualityHeadPainter(
                geometry: _geometry,
                channelGrades: widget.channelGrades,
                perChannelGrades: widget.perChannelGrades,
                fallbackTier: fallbackTier,
              ),
            ),
          ),
        ),
        if (widget.showLegend) ...[
          const SizedBox(height: 6),
          const ContactQualityTierLegend(),
        ],
      ],
    );
  }
}

/// Compact 4-tier legend matching pyPhoTimeline `EEG_QUALITY_TIER_LABELS`.
class ContactQualityTierLegend extends StatelessWidget {
  const ContactQualityTierLegend({super.key});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 4,
      alignment: WrapAlignment.center,
      children: [
        for (final tier in ContactQualityTier.legendTiers)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: tier.color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.black26, width: 0.5),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                tier.label,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
      ],
    );
  }
}

class _ContactQualityHeadPainter extends CustomPainter {
  _ContactQualityHeadPainter({
    required this.geometry,
    required this.fallbackTier,
    this.channelGrades,
    this.perChannelGrades,
  });

  final EpocXHeadSvgGeometry geometry;
  final ContactQualityTier fallbackTier;
  final List<int>? channelGrades;
  final Map<String, int>? perChannelGrades;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final cb = geometry.computeContentBox(margin: 16.0);
    if (cb.width <= 0 || cb.height <= 0) return;

    final scale = math.min(size.width / cb.width, size.height / cb.height);
    final drawW = cb.width * scale;
    final drawH = cb.height * scale;
    final offsetX = (size.width - drawW) * 0.5;
    final offsetY = (size.height - drawH) * 0.5;

    final tx = offsetX - cb.left * scale;
    final ty = offsetY - cb.top * scale;

    canvas.save();
    canvas.translate(tx, ty);
    canvas.scale(scale, scale);

    if (geometry.silhouettePaths.isNotEmpty) {
      final p = Paint()..style = PaintingStyle.fill;
      for (final item in geometry.silhouettePaths) {
        p.color = item.color;
        canvas.drawPath(item.path, p);
      }
    } else {
      final headCenter = const Offset(133.5, 196.0);
      final headRect = Rect.fromCenter(
        center: headCenter,
        width: 212,
        height: 266,
      );
      canvas.drawOval(
        headRect,
        Paint()..color = const Color(0xFFD7E2EE),
      );
      canvas.drawOval(
        headRect,
        Paint()
          ..color = const Color(0xFF607D8B)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
      final nose = Path()
        ..moveTo(121, 64)
        ..lineTo(133.5, 42)
        ..lineTo(146, 64);
      canvas.drawPath(
        nose,
        Paint()
          ..color = const Color(0xFF607D8B)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
    }

    canvas.restore();

    final fillPaint = Paint()..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = const Color(0xFF1E242B)
      ..strokeWidth = math.max(1.0, 1.4 * scale);

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: 1,
    );

    for (var chIdx = 0; chIdx < EegSample.channelNames.length; chIdx++) {
      final channel = EegSample.channelNames[chIdx];
      final circle = geometry.electrodes[channel];
      if (circle == null) continue;

      ContactQualityTier tier;
      if (perChannelGrades != null && perChannelGrades!.containsKey(channel)) {
        tier = ContactQualityTier.fromCortexGrade(perChannelGrades![channel]);
      } else if (channelGrades != null && chIdx < channelGrades!.length) {
        tier = ContactQualityTier.fromCortexGrade(channelGrades![chIdx]);
      } else {
        tier = fallbackTier;
      }

      final cx = tx + circle.cx * scale;
      final cy = ty + circle.cy * scale;
      final r = circle.r * scale;

      fillPaint.color = tier.color;
      final center = Offset(cx, cy);
      canvas.drawCircle(center, r, fillPaint);
      canvas.drawCircle(center, r, strokePaint);

      final fontSize = (r * 0.64).clamp(6.5, 11.0);
      textPainter.text = TextSpan(
        text: channel,
        style: TextStyle(
          color: tier.labelColor,
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          height: 1.0,
        ),
      );
      textPainter.layout(maxWidth: r * 2.1);
      textPainter.paint(
        canvas,
        Offset(cx - textPainter.width * 0.5, cy - textPainter.height * 0.5),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ContactQualityHeadPainter oldDelegate) {
    if (oldDelegate.fallbackTier != fallbackTier ||
        !identical(oldDelegate.geometry, geometry) ||
        oldDelegate.perChannelGrades != perChannelGrades) {
      return true;
    }
    final a = oldDelegate.channelGrades;
    final b = channelGrades;
    if (identical(a, b)) return false;
    if (a == null || b == null || a.length != b.length) return true;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return true;
    }
    return false;
  }
}
