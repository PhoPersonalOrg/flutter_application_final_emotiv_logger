import 'dart:async';

/// Owns every BLE-related [StreamSubscription] for a session.
/// Cancelled as a bag on every exit from connecting/preparing/streaming/reconnecting.
class SessionSubscriptions {
  final List<StreamSubscription> _subs = [];

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
