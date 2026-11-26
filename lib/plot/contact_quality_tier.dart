import 'package:flutter/material.dart';

/// Discrete contact-quality tiers matching pyPhoTimeline `eeg_quality_colors.py`
/// and Cortex discrete Contact Quality grades (`04_EpocX_Packet_Crypto_and_Codec.md` §7.1).
///
/// Cortex discrete per-electrode grades (`{0, 1, 2, 4}`, plus `3` on Insight 2):
/// - `0` (`metric < 0.2`) -> [ContactQualityTier.unknown] (`#808080`, No contact)
/// - `1` (`0.2 <= metric < 0.7`) -> [ContactQualityTier.poor] (`#d32f2f`)
/// - `2` (`0.7 <= metric < 1.7`) -> [ContactQualityTier.fair] (`#f57c00`)
/// - `3` -> [ContactQualityTier.good] (`#fdd835`)
/// - `4` (`metric >= 1.7`) -> [ContactQualityTier.excellent] (`#43a047`)
enum ContactQualityTier {
  unknown(
    index_: 0,
    label: 'None',
    legendLabel: 'None (0)',
    color: Color(0xFF808080),
    overlayAlpha: 1.0,
  ),
  poor(
    index_: 1,
    label: 'Poor',
    legendLabel: 'Poor (1)',
    color: Color(0xFFD32F2F),
    overlayAlpha: 0.95,
  ),
  fair(
    index_: 2,
    label: 'Fair',
    legendLabel: 'Fair (2)',
    color: Color(0xFFF57C00),
    overlayAlpha: 0.70,
  ),
  good(
    index_: 3,
    label: 'Good',
    legendLabel: 'Good (3)',
    color: Color(0xFFFDD835),
    overlayAlpha: 0.30,
  ),
  excellent(
    index_: 4,
    label: 'Excellent',
    legendLabel: 'Excellent (4)',
    color: Color(0xFF43A047),
    overlayAlpha: 0.0,
  );

  const ContactQualityTier({
    required this.index_,
    required this.label,
    required this.legendLabel,
    required this.color,
    required this.overlayAlpha,
  });

  /// Tier index `0..4` matching `quality_tier_index` in pyPhoTimeline.
  final int index_;
  final String label;
  final String legendLabel;
  final Color color;

  /// Black scrim alpha matching `EEG_QUALITY_OVERLAY_ALPHA` in pyPhoTimeline.
  final double overlayAlpha;

  /// Legend items shown on CQ tracks (excludes unknown, matching pyPhoTimeline).
  static const List<ContactQualityTier> legendTiers = [
    poor,
    fair,
    good,
    excellent,
  ];

  /// Contrasting foreground label color for [color].
  Color get labelColor {
    final luma = 0.299 * color.r + 0.587 * color.g + 0.114 * color.b;
    return luma < 0.55 ? const Color(0xFFFAFAFA) : const Color(0xFF202020);
  }

  /// Map discrete Cortex per-electrode CQ grade (`0, 1, 2, 3, 4`) to a tier.
  static ContactQualityTier fromCortexGrade(int? grade) {
    if (grade == null || grade <= 0) return unknown;
    return switch (grade) {
      1 => poor,
      2 => fair,
      3 => good,
      _ => excellent,
    };
  }

  /// Map overall CQ percentage (`0..100`) to a summary tier.
  static ContactQualityTier fromOverallPercent(int? percent) {
    if (percent == null || percent <= 0) return unknown;
    if (percent < 25) return poor;
    if (percent < 50) return fair;
    if (percent < 75) return good;
    return excellent;
  }

  /// Legacy `0..127` band mapper retained for compatibility.
  static ContactQualityTier fromMode7Raw(int? cq) {
    if (cq == null || cq <= 0) return unknown;
    if (cq <= 31) return poor;
    if (cq <= 63) return fair;
    if (cq <= 95) return good;
    return excellent;
  }

  /// Map tier index `0..4` back to [ContactQualityTier].
  static ContactQualityTier fromTierIndex(int tierIndex) {
    return switch (tierIndex) {
      1 => poor,
      2 => fair,
      3 => good,
      4 => excellent,
      _ => unknown,
    };
  }
}
