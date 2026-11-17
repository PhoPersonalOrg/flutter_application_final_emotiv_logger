import 'dart:io';

import 'package:dropbox_client/dropbox_client.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import 'dropbox_config.dart';
import 'session_transfer.dart';

/// Dropbox App Folder auth + session upload (PKCE, no app secret).
class DropboxSync {
  DropboxSync({FlutterSecureStorage? secureStorage})
      : _secure = secureStorage ??
            const FlutterSecureStorage(aOptions: AndroidOptions());

  final FlutterSecureStorage _secure;

  static const _credentialsKey = 'acq.v1.dropbox.pkceCredentials';
  static const defaultRemoteRoot = 'EmotivSessions';

  static bool _initialized = false;
  String? lastError;

  static Future<void> initIfConfigured() async {
    if (!DropboxConfig.isConfigured || _initialized) return;
    await Dropbox.init(DropboxConfig.clientId, DropboxConfig.appKey);
    _initialized = true;
  }

  void _requireConfigured() {
    if (!DropboxConfig.isConfigured) {
      throw StateError(
        'Dropbox app key missing. Rebuild with '
        '--dart-define=DROPBOX_APP_KEY=<key> and set db-<key> URL schemes '
        '(see README).',
      );
    }
  }

  Future<bool> isLinked() async {
    if (!DropboxConfig.isConfigured) return false;
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

  /// Uploads one local `session_*` directory under the App Folder.
  Future<void> uploadSession(
    String localSessionDir, {
    String remoteRoot = defaultRemoteRoot,
    TransferProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    await ensureAuthorized();
    final dir = Directory(localSessionDir);
    if (!await dir.exists()) {
      throw StateError('Session folder missing: $localSessionDir');
    }

    final folderName = p.basename(localSessionDir);
    final root = _normalizeRemoteRoot(remoteRoot);
    final remoteSession =
        root.isEmpty ? '/$folderName' : '/$root/$folderName';

    final files = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File) files.add(entity);
    }
    files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    if (files.isEmpty) {
      throw StateError('Session folder is empty: $localSessionDir');
    }

    var fileIndex = 0;
    for (final file in files) {
      if (isCancelled != null && isCancelled()) {
        throw const TransferCancelled();
      }
      fileIndex++;
      final name = p.basename(file.path);
      final remoteFile = '$remoteSession/$name';
      final length = await file.length();

      onProgress?.call(
        TransferProgress(
          sessionFolder: folderName,
          fileName: name,
          fileIndex: fileIndex,
          fileCount: files.length,
          bytesSent: 0,
          bytesTotal: length,
        ),
      );

      await Dropbox.upload(file.path, remoteFile, (uploaded, total) {
        onProgress?.call(
          TransferProgress(
            sessionFolder: folderName,
            fileName: name,
            fileIndex: fileIndex,
            fileCount: files.length,
            bytesSent: uploaded,
            bytesTotal: total > 0 ? total : length,
          ),
        );
      });
    }

    onProgress?.call(
      TransferProgress(
        sessionFolder: folderName,
        fileName: '',
        fileIndex: files.length,
        fileCount: files.length,
        bytesSent: 1,
        bytesTotal: 1,
        done: true,
      ),
    );
  }

  /// Uploads several sessions sequentially.
  Future<void> uploadSessions(
    List<String> sessionPaths, {
    String remoteRoot = defaultRemoteRoot,
    TransferProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    for (final path in sessionPaths) {
      if (isCancelled != null && isCancelled()) {
        throw const TransferCancelled();
      }
      await uploadSession(
        path,
        remoteRoot: remoteRoot,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    }
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
    if (!DropboxConfig.isConfigured) {
      lastError = 'Dropbox not configured (missing DROPBOX_APP_KEY)';
      return false;
    }
    try {
      if (!await isLinked()) {
        lastError = 'Dropbox not linked';
        return false;
      }
      await uploadSession(sessionPath, remoteRoot: remoteRoot);
      lastError = null;
      return true;
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
