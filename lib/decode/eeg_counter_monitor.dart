/// Plausibility check on decrypted EEG packages.
///
/// A correctly decrypted Epoc X package starts with a counter that advances by
/// one per package and wraps at the sample rate (128 or 256). Decrypting with
/// the wrong key or cipher yields random bytes, so the counter stops being
/// sequential. That is what happens for the two cases `CryptoCodec` does not
/// implement: firmware newer than 0x73e (AES-256, per-device XOR byte) and a
/// headset configured in legacy EPOC mode.
///
/// The monitor only reports; it never drops samples, because heavy BLE packet
/// loss also lowers the sequential ratio.
class EegCounterMonitor {
  EegCounterMonitor({this.window = 128, this.minSequentialRatio = 0.5});

  /// Number of counter transitions judged together.
  final int window;

  /// Below this share of sequential transitions a window is reported.
  final double minSequentialRatio;

  int? _last;
  int _seen = 0;
  int _sequential = 0;

  void reset() {
    _last = null;
    _seen = 0;
    _sequential = 0;
  }

  /// Feeds one package counter. Returns a warning when the window that just
  /// completed was implausible, otherwise null.
  String? add(int counter) {
    final last = _last;
    _last = counter;
    if (last == null) return null;

    _seen++;
    if (_isSuccessor(last, counter)) _sequential++;
    if (_seen < window) return null;

    final sequential = _sequential;
    final seen = _seen;
    _seen = 0;
    _sequential = 0;
    if (sequential / seen >= minSequentialRatio) return null;

    return 'EEG decrypt looks wrong: only $sequential of $seen package '
        'counters were sequential. The headset may run firmware newer than '
        '0x73e (AES-256 keying, not supported) or be set to legacy EPOC mode '
        '(not supported). EEG values from this session are not trustworthy; '
        'raw.csv still holds the undecrypted packets.';
  }

  static bool _isSuccessor(int last, int counter) {
    if (counter == last + 1) return true;
    return counter == 0 && (last == 127 || last == 255);
  }
}
