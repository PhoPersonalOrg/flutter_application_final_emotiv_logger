/// EEG settings an Epoc X reports in its configuration characteristic
/// (`EmotivBleUuids.headsetConfig`).
///
/// Mirrors the Epoc X branch of the EmotivPRO V4 Android function
/// `AbstractInputDevice::setHeadsetConfigFromByteArray`, which the official
/// app feeds with the value of that characteristic once discovery finishes.
class HeadsetConfig {
  const HeadsetConfig({
    required this.mode,
    this.eegRateHz,
    this.eegResolutionBits,
  });

  /// Legacy EPOC mode: different key schedule and 14-bit bit-packed samples.
  static const int modeLegacyEpoc = 3;

  /// Epoc X mode: the layout `CryptoCodec` decodes.
  static const int modeEpocX = 7;

  final int mode;

  /// Null when the value was too short to carry it.
  final int? eegRateHz;

  /// Bits per EEG sample (14 or 16 on known headsets). Null when the value
  /// was too short to carry it.
  final int? eegResolutionBits;

  bool get isLegacyEpocMode => mode == modeLegacyEpoc;

  /// Returns null for an empty value, which Android ignores.
  static HeadsetConfig? parse(List<int> bytes) {
    if (bytes.isEmpty) return null;
    if (bytes[0] == 0) {
      return const HeadsetConfig(
        mode: modeLegacyEpoc,
        eegRateHz: 128,
        eegResolutionBits: 14,
      );
    }
    return HeadsetConfig(
      mode: modeEpocX,
      eegRateHz: bytes.length >= 3 ? bytes[1] | (bytes[2] << 8) : null,
      eegResolutionBits: bytes.length >= 4 ? bytes[3] : null,
    );
  }
}
