/// Dropbox App key / client id from `--dart-define`.
///
/// ```bash
/// flutter run --dart-define=DROPBOX_APP_KEY=<key> \
///   --dart-define=DROPBOX_CLIENT_ID=emotiv-logger
/// ```
///
/// Also replace `YOUR_DROPBOX_APP_KEY` in iOS/Android URL schemes with the
/// same key (`db-<key>`). See README.
class DropboxConfig {
  DropboxConfig._();

  static const appKey = String.fromEnvironment(
    'DROPBOX_APP_KEY',
    defaultValue: '',
  );

  static const clientId = String.fromEnvironment(
    'DROPBOX_CLIENT_ID',
    defaultValue: 'emotiv-logger',
  );

  static bool get isConfigured => appKey.trim().isNotEmpty;
}
