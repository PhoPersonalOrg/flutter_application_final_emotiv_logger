import 'dart:async';

/// Owns a bag of BLE-related [StreamSubscription]s.
///
/// Acquisition uses two bags: scan-only vs link/notify, so stopping a scan
/// cannot cancel connection-state or characteristic listeners.
class SessionSubscriptions {
  final List<StreamSubscription> _subs = [];

  int get length => _subs.length;

  bool get isEmpty => _subs.isEmpty;

  T add<T extends StreamSubscription>(T sub) {
    _subs.add(sub);
    return sub;
  }

  Future<void> cancelAll() async {
    final copy = List<StreamSubscription>.from(_subs);
    _subs.clear();
    for (final s in copy) {
      await s.cancel();
    }
  }
}
