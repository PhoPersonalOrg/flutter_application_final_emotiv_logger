import 'package:flutter/material.dart';

/// Discrete contact-quality tiers matching pyPhoTimeline `eeg_quality_colors.py`.
///
/// Epoc X Mode-7 exposes a single broadcast `word7 & 0x7f` (`0..127`) for all
/// 14 electrodes, latched only when `counter == sampleRate - 1` (~1 Hz). Bands
/// map onto pyPhoTimeline's 4-tier palette:
/// - `<= 0` → [ContactQualityTier.unknown] (`#808080`)
/// - `1..31` → [ContactQualityTier.poor] (`#d32f2f`)
/// - `32..63` → [ContactQualityTier.fair] (`#f57c00`)
/// - `64..95` → [ContactQualityTier.good] (`#fdd835`)
/// - `>= 96` → [ContactQualityTier.excellent] (`#43a047`)
enum ContactQualityTier {
  unknown(
    index_: 0,
    label: 'None',
    legendLabel: 'Unknown (0)',
    color: Color(0xFF808080),
    overlayAlpha: 1.0,
  ),
  poor(
    index_: 1,
    label: 'Poor',
    legendLabel: 'Poor (1–31)',
    color: Color(0xFFD32F2F),
    overlayAlpha: 0.95,
  ),
  fair(
    index_: 2,
    label: 'Fair',
    legendLabel: 'Fair (32–63)',
    color: Color(0xFFF57C00),
    overlayAlpha: 0.70,
  ),
  good(
    index_: 3,
    label: 'Good',
    legendLabel: 'Good (64–95)',
    color: Color(0xFFFDD835),
    overlayAlpha: 0.30,
  ),
  excellent(
    index_: 4,
    label: 'Excellent',
    legendLabel: 'Excellent (96–127)',
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

  /// Contrasting foreground label color for [color], matching
  /// `EmotivEpocXElectrodeQualityWidget._label_color_for_fill`.
  Color get labelColor {
    final luma =
        0.299 * color.r + 0.587 * color.g + 0.114 * color.b;
    return luma < 0.55
        ? const Color(0xFFFAFAFA)
        : const Color(0xFF202020);
  }

  /// Map Mode-7 raw CQ (`0..127`) to a discrete tier.
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
