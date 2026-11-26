/// Plausibility check on rolling decrypted EPOC X packet counters.
///
/// Correctly decrypted EPOC X EEG packets carry a `uint8` counter that advances
/// by `1` per sample modulo `eegRateHz` (`128` at `128 Hz`, `256` at `256 Hz`),
/// while MEMS packets wrap modulo `128` (`DataInterpolation` `0x140ddfe30`).
///
/// Decrypting with a mismatched serial or firmware key yields pseudo-random
/// byte `0` values whose sequential transition ratio collapses near `1/256`.
/// The monitor emits an advisory warning without dropping samples.
class EegCounterMonitor {
  EegCounterMonitor({
    this.window = 128,
    this.minSequentialRatio = 0.5,
    this.modulus,
  });

  /// Number of counter transitions evaluated per window.
  final int window;

  /// Minimum fraction of sequential transitions before warning.
  final double minSequentialRatio;

  /// Counter wrap modulus (`128` at `128 Hz`, `256` at `256 Hz`).
  /// When null, accepts both `127 -> 0` and `255 -> 0`.
  int? modulus;

  int? _last;
  int _seen = 0;
  int _sequential = 0;

  void reset({int? newModulus}) {
    if (newModulus != null) {
      modulus = newModulus;
    }
    _last = null;
    _seen = 0;
    _sequential = 0;
  }

  /// Feeds one decrypted packet counter. Returns a warning when a completed
  /// window is implausible, otherwise null.
  String? add(int counter) {
    final last = _last;
    _last = counter;
    if (last == null) return null;

    _seen++;
    if (_isSuccessor(last, counter, modulus)) {
      _sequential++;
    }
    if (_seen < window) return null;

    final sequential = _sequential;
    final seen = _seen;
    _seen = 0;
    _sequential = 0;
    if (sequential / seen >= minSequentialRatio) return null;

    return 'EEG decrypt counter check: only $sequential of $seen transitions '
        'were sequential (modulus=${modulus ?? "128/256"}). Verify DIS 0x2A25 '
        'serial / 0x2A26 firmware key derivation or check for severe BLE drops; '
        'raw.csv preserves all undecrypted wire packets.';
  }

  static bool _isSuccessor(int last, int counter, int? modulus) {
    if (modulus != null && modulus > 0) {
      return counter == ((last + 1) % modulus);
    }
    if (counter == last + 1) return true;
    return counter == 0 && (last == 127 || last == 255);
  }
}

/// Rolling modulo-128 counter continuity tracker for 20-byte MEMS packets.
class MemsCounterMonitor {
  static const int mmsModulus = 128;

  int? _last;
  int _missedCount = 0;

  int get missedCount => _missedCount;

  void reset() {
    _last = null;
    _missedCount = 0;
  }

  /// Returns the number of skipped MEMS frames (`0` when contiguous).
  int add(int counterMems) {
    final cur = counterMems & 0x7F;
    final prev = _last;
    _last = cur;
    if (prev == null) return 0;
    final step = (cur - prev) & 0x7F;
    if (step <= 1) return 0;
    final missed = step - 1;
    _missedCount += missed;
    return missed;
  }
}
