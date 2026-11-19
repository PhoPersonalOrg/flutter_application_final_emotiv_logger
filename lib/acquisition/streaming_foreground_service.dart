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
/// Idempotent [ensureStarted] / [ensureStopped]. No-ops on non-Android.
class StreamingForegroundService {
  StreamingForegroundService._();

  static const int _serviceId = 256;
  static bool _initialized = false;

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
  static Future<void> ensureStarted(String deviceName) async {
    if (!Platform.isAndroid) return;
    try {
      init();
      final label =
          deviceName.trim().isEmpty ? 'headset' : deviceName.trim();
      final title = 'Emotiv logging';
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
    } catch (_) {
      // FGS is best-effort keepalive; never abort acquisition.
    }
  }

  /// Stops the FGS if it is running.
  static Future<void> ensureStopped() async {
    if (!Platform.isAndroid) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {
      // Best-effort cleanup.
    }
  }
}
