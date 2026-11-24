import 'dart:io';

import 'package:dropbox_client/dropbox_client.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'dropbox_config.dart';
import 'session_transfer.dart';

typedef DropboxRawUploadFn = Future<void> Function(
  String localFilePath,
  String remotePath,
  void Function(int bytesSent, int bytesTotal) onProgress,
);

/// Dropbox App Folder auth + session upload (PKCE, no app secret).
///
/// Local session files are strictly read-only and always kept on device.
class DropboxSync {
  DropboxSync({
    FlutterSecureStorage? secureStorage,
    DropboxRawUploadFn? rawUpload,
    Future<void> Function()? ensureReadyOverride,
  })  : _secure = secureStorage ??
            const FlutterSecureStorage(aOptions: AndroidOptions()),
        _rawUpload = rawUpload,
        _ensureReadyOverride = ensureReadyOverride;

  final FlutterSecureStorage _secure;
  final DropboxRawUploadFn? _rawUpload;
  final Future<void> Function()? _ensureReadyOverride;

  static const _credentialsKey = 'acq.v1.dropbox.pkceCredentials';
  static const defaultRemoteRoot = 'EmotivSessions';

  static bool _initialized = false;
  String? lastError;

  /// `dropbox_client` ships Android/iOS only — skip on desktop.
  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  static Future<void> initIfConfigured() async {
    if (!DropboxConfig.isConfigured || _initialized || !isSupported) return;
    await Dropbox.init(DropboxConfig.clientId, DropboxConfig.appKey);
    _initialized = true;
  }

  void _requireConfigured() {
    if (!isSupported) {
      throw StateError(
        'Dropbox sync is only available on Android and iOS '
        '(dropbox_client has no Windows/desktop plugin).',
      );
    }
    if (!DropboxConfig.isConfigured) {
      throw StateError(
        'Dropbox app key missing. Rebuild with '
        '--dart-define=DROPBOX_APP_KEY=<key> and set db-<key> URL schemes '
        '(see README).',
      );
    }
  }

  Future<bool> isLinked() async {
    if (!isSupported || !DropboxConfig.isConfigured) return false;
    await initIfConfigured();
    final live = await Dropbox.getCredentials();
    if (live != null && live.isNotEmpty) {
      await _secure.write(key: _credentialsKey, value: live);
      return true;
    }
    final stored = await _secure.read(key: _credentialsKey);
    if (stored == null || stored.isEmpty) return false;
    try {
      await Dropbox.authorizeWithCredentials(stored);
      final again = await Dropbox.getCredentials();
      return again != null && again.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Interactive PKCE authorize; persists credentials on success.
  ///
  /// [Dropbox.authorizePKCE] only launches the Dropbox app / browser and
  /// returns immediately. Credentials appear after the `db-*://` redirect is
  /// handled natively, so we poll until linked or timed out.
  Future<void> connect({
    Duration timeout = const Duration(minutes: 2),
  }) async {
    _requireConfigured();
    await initIfConfigured();
    lastError = null;

    // Already authorized (e.g. prior session / redirect already processed).
    final existing = await Dropbox.getCredentials();
    if (existing != null && existing.isNotEmpty) {
      await _secure.write(key: _credentialsKey, value: existing);
      return;
    }

    await Dropbox.authorizePKCE();

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final credentials = await Dropbox.getCredentials();
      if (credentials != null && credentials.isNotEmpty) {
        await _secure.write(key: _credentialsKey, value: credentials);
        return;
      }
    }
    throw StateError(
      'Dropbox authorization timed out. Confirm the db-<app-key> URL scheme '
      'matches DROPBOX_APP_KEY and try Connect again.',
    );
  }

  Future<void> unlink() async {
    lastError = null;
    try {
      await Dropbox.unlink();
    } catch (_) {}
    await _secure.delete(key: _credentialsKey);
  }

  Future<void> ensureAuthorized() async {
    _requireConfigured();
    await initIfConfigured();
    if (await isLinked()) return;
    await connect();
  }

  /// Ensures existing stored credentials are active without opening interactive
  /// browser PKCE flows during background uploads.
  Future<void> _ensureBackgroundReady() async {
    if (_ensureReadyOverride != null) {
      await _ensureReadyOverride();
      return;
    }
    _requireConfigured();
    await initIfConfigured();
    if (!await isLinked()) {
      throw StateError('Dropbox not linked (connect Dropbox in Settings)');
    }
  }

  /// Uploads one local `session_*` directory under the App Folder, continuing
  /// across remaining files if an error occurs and keeping local files intact.
  Future<BatchTransferReport> uploadSession(
    String localSessionDir, {
    String remoteRoot = defaultRemoteRoot,
    TransferProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) {
    return uploadSessions(
      [localSessionDir],
      remoteRoot: remoteRoot,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  /// Uploads several sessions sequentially in the background, continuing across
  /// remaining files and sessions when errors occur and never deleting local files.
  Future<BatchTransferReport> uploadSessions(
    List<String> sessionPaths, {
    String remoteRoot = defaultRemoteRoot,
    TransferProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    final adapter = _DropboxBatchAdapter(
      ensureReady: _ensureBackgroundReady,
      remoteRoot: _normalizeRemoteRoot(remoteRoot),
      rawUpload: _rawUpload ?? _defaultDropboxUpload,
    );
    final report = await SessionTransfer.runResilientBatch(
      destinationLabel: 'Dropbox',
      sessionPaths: sessionPaths,
      adapter: adapter,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
    lastError = report.hasFailures ? report.failures.first.label : null;
    return report;
  }

  static Future<void> _defaultDropboxUpload(
    String localPath,
    String remotePath,
    void Function(int bytesSent, int bytesTotal) onProgress,
  ) async {
    await Dropbox.upload(localPath, remotePath, onProgress);
  }

  /// Best-effort post-stop upload; never throws to callers.
  Future<bool> tryAutoUpload(
    String? sessionPath, {
    required bool enabled,
    String remoteRoot = defaultRemoteRoot,
  }) async {
    if (!enabled || sessionPath == null || sessionPath.isEmpty) {
      return false;
    }
    if (_ensureReadyOverride == null) {
      if (!isSupported) {
        lastError = 'Dropbox not supported on this platform';
        return false;
      }
      if (!DropboxConfig.isConfigured) {
        lastError = 'Dropbox not configured (missing DROPBOX_APP_KEY)';
        return false;
      }
    }
    try {
      final report = await uploadSession(sessionPath, remoteRoot: remoteRoot);
      return report.isFullSuccess;
    } catch (e) {
      lastError = '$e';
      return false;
    }
  }

  static String _normalizeRemoteRoot(String raw) {
    var s = raw.trim().replaceAll('\\', '/');
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s.isEmpty ? defaultRemoteRoot : s;
  }
}

class _DropboxBatchAdapter implements BatchRemoteAdapter {
  _DropboxBatchAdapter({
    required this.ensureReady,
    required this.remoteRoot,
    required this.rawUpload,
  });

  final Future<void> Function() ensureReady;
  final String remoteRoot;
  final DropboxRawUploadFn rawUpload;

  bool _ready = false;

  String _remoteSessionPath(String folderName) =>
      remoteRoot.isEmpty ? '/$folderName' : '/$remoteRoot/$folderName';

  @override
  Future<void> ensureSessionDir(String folderName) async {
    if (!_ready) {
      await ensureReady();
      _ready = true;
    }
  }

  @override
  Future<void> uploadFile({
    required File localFile,
    required String folderName,
    required String fileName,
    required int length,
    required void Function(int bytesSent, int bytesTotal) onFileProgress,
    bool Function()? isCancelled,
  }) async {
    if (isCancelled != null && isCancelled()) {
      throw const TransferCancelled();
    }
    if (!_ready) {
      await ensureReady();
      _ready = true;
    }
    final remoteFile = '${_remoteSessionPath(folderName)}/$fileName';
    await rawUpload(localFile.path, remoteFile, (uploaded, total) {
      if (isCancelled != null && isCancelled()) {
        throw const TransferCancelled();
      }
      onFileProgress(uploaded, total);
    });
  }

  @override
  Future<void> resetConnection() async {
    _ready = false;
  }

  @override
  Future<void> close() async {}
}
