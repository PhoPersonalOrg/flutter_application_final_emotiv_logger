import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Top-level entry used by [FlutterForegroundTask.startService].
///
/// BLE GATT and CSV stay on the main isolate in [AcquisitionSession]; this
/// handler is intentionally a no-op process pin.
@pragma('vm:entry-point')
void streamingForegroundStartCallback() {
  FlutterForegroundTask.setTaskHandler(_NoopStreamingTaskHandler());
}

class _NoopStreamingTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Android-only wrapper around `flutter_foreground_task` for streaming.
///
/// Start/stop are serialized and reconciled against [AcquisitionSession]'s
/// `_opEpoch` so a pending start cannot outlive Stop, and a stale stop cannot
/// tear down a newer session's keepalive.
class StreamingForegroundService {
  StreamingForegroundService._();

  static const int _serviceId = 256;
  static bool _initialized = false;

  /// Latest desired intent (updated synchronously; applied by [_reconcile]).
  static int _desiredEpoch = 0;
  static bool _desiredRunning = false;
  static String _desiredDeviceName = '';

  /// Serializes native start/stop so awaits cannot interleave.
  static Future<void> _queue = Future<void>.value();

  /// Configures notification channel / task options once.
  static void init() {
    if (!Platform.isAndroid || _initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'emotiv_streaming',
        channelName: 'Emotiv streaming',
        channelDescription:
            'Shown while the headset is connected and logging.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
    _initialized = true;
  }

  /// Starts (or refreshes) the connected-device FGS for [deviceName].
  ///
  /// [epoch] must be the acquisition op-epoch that owns this connect/stream.
  /// Stale calls with an older epoch are ignored once a newer intent exists.
  static Future<void> ensureStarted(
    String deviceName, {
    required int epoch,
  }) {
    if (!Platform.isAndroid) return Future<void>.value();
    if (epoch < _desiredEpoch) return Future<void>.value();
    _desiredEpoch = epoch;
    _desiredRunning = true;
    _desiredDeviceName = deviceName;
    return _scheduleReconcile();
  }

  /// Stops the FGS for [epoch] (and any older session).
  ///
  /// A stop with a newer epoch wins over an in-flight start for an older one.
  /// A stop that is older than a newer start intent is ignored.
  static Future<void> ensureStopped({required int epoch}) {
    if (!Platform.isAndroid) return Future<void>.value();
    if (epoch < _desiredEpoch) return Future<void>.value();
    _desiredEpoch = epoch;
    _desiredRunning = false;
    return _scheduleReconcile();
  }

  static Future<void> _scheduleReconcile() {
    final done = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        await _reconcile();
      } catch (_) {
        // Best-effort keepalive; never surface to callers.
      } finally {
        if (!done.isCompleted) done.complete();
      }
    });
    return done.future;
  }

  /// Applies [_desiredRunning] / [_desiredEpoch], re-running if intent changes
  /// while an await is in flight.
  static Future<void> _reconcile() async {
    init();
    while (true) {
      final wantRunning = _desiredRunning;
      final epoch = _desiredEpoch;
      final deviceName = _desiredDeviceName;

      try {
        if (wantRunning) {
          await _applyStart(deviceName);
        } else {
          await _applyStop();
        }
      } catch (_) {
        // Swallow native failures; loop may retry if intent changed.
      }

      // Intent unchanged while we awaited → done. Otherwise apply the new one.
      if (wantRunning == _desiredRunning && epoch == _desiredEpoch) {
        return;
      }
    }
  }

  static Future<void> _applyStart(String deviceName) async {
    final label = deviceName.trim().isEmpty ? 'headset' : deviceName.trim();
    const title = 'Emotiv logging';
    final text = 'Streaming $label — tap to open';
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
      return;
    }
    await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: const [ForegroundServiceTypes.connectedDevice],
      notificationTitle: title,
      notificationText: text,
      callback: streamingForegroundStartCallback,
    );
  }

  static Future<void> _applyStop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}
