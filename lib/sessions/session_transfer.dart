import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import 'server_bookmark.dart';
import 'smb_paths.dart';

class TransferProgress {
  const TransferProgress({
    required this.sessionFolder,
    required this.fileName,
    required this.fileIndex,
    required this.fileCount,
    required this.bytesSent,
    required this.bytesTotal,
    this.done = false,
    this.skipped = false,
    this.error,
  });

  final String sessionFolder;
  final String fileName;
  final int fileIndex;
  final int fileCount;
  final int bytesSent;
  final int bytesTotal;
  final bool done;
  /// True when the remote file already matched local size and was not uploaded.
  final bool skipped;
  final String? error;

  double get fraction {
    if (bytesTotal <= 0) return 0;
    return (bytesSent / bytesTotal).clamp(0.0, 1.0);
  }
}

typedef TransferProgressCallback = void Function(TransferProgress progress);

/// Skip upload when a remote file exists with the same byte size as local.
bool shouldSkipIdenticalRemoteFile({
  required int localBytes,
  required int? remoteBytes,
}) =>
    remoteBytes != null && remoteBytes == localBytes;

/// Records a single session- or file-level error during a batch transfer.
class TransferItemFailure {
  const TransferItemFailure({
    required this.sessionFolder,
    this.fileName,
    required this.error,
  });

  final String sessionFolder;
  final String? fileName;
  final String error;

  String get label => (fileName == null || fileName!.isEmpty)
      ? '$sessionFolder: $error'
      : '$sessionFolder/$fileName: $error';
}

/// Summary of a resilient multi-session upload where individual file/session
/// errors do not abort remaining uploads and local files are always retained.
class BatchTransferReport {
  const BatchTransferReport({
    required this.destinationLabel,
    required this.totalSessions,
    required this.succeededSessions,
    this.failures = const [],
    this.cancelled = false,
  });

  final String destinationLabel;
  final int totalSessions;
  final List<String> succeededSessions;
  final List<TransferItemFailure> failures;
  final bool cancelled;

  int get succeededCount => succeededSessions.length;
  bool get hasFailures => failures.isNotEmpty;
  bool get isFullSuccess =>
      !cancelled && failures.isEmpty && succeededCount == totalSessions;

  String summaryLine() {
    if (cancelled) {
      return 'Transfer to $destinationLabel cancelled '
          '($succeededCount/$totalSessions completed — local files kept)';
    }
    if (failures.isEmpty) {
      return 'Transferred $succeededCount session'
          '${succeededCount == 1 ? '' : 's'} to $destinationLabel '
          '(local files kept)';
    }
    return 'Transferred $succeededCount/$totalSessions session'
        '${totalSessions == 1 ? '' : 's'} to $destinationLabel '
        '(${failures.length} error${failures.length == 1 ? '' : 's'}: '
        '${failures.first.label} — local files kept)';
  }
}

/// Transport adapter used by [SessionTransfer.runResilientBatch].
///
/// Implementations must treat [localFile] as strictly read-only and never
/// delete or modify local files.
abstract class BatchRemoteAdapter {
  Future<void> ensureSessionDir(String folderName);

  /// Basename → size for files already under the remote session folder.
  /// Empty map means "upload everything" (listing unsupported or failed).
  Future<Map<String, int>> remoteFileSizes(String folderName) async {
    return const <String, int>{};
  }

  Future<void> uploadFile({
    required File localFile,
    required String folderName,
    required String fileName,
    required int length,
    required void Function(int bytesSent, int bytesTotal) onFileProgress,
    bool Function()? isCancelled,
  });

  Future<void> resetConnection();

  Future<void> close();
}

/// Uploads local `session_*` folders over SFTP or SMB without deleting local files.
class SessionTransfer {
  /// Tests that credentials work and the remote path is reachable.
  static Future<void> testConnection({
    required ServerBookmark bookmark,
    required String password,
  }) async {
    switch (bookmark.protocol) {
      case TransferProtocol.sftp:
        final client = await _sftpClient(bookmark, password);
        try {
          final sftp = await client.sftp();
          final path = _normalizeRemote(bookmark.remotePath);
          if (path.isNotEmpty && path != '/') {
            await _sftpEnsureDir(sftp, path);
          }
          await sftp.listdir(path.isEmpty ? '/' : path);
        } finally {
          client.close();
        }
      case TransferProtocol.smb:
        final pool = await _smbPool(bookmark, password);
        try {
          final remote = normalizeSmbRemotePath(bookmark.remotePath);
          if (remote.isNotEmpty) {
            await pool.mkdir(remote, recursive: true);
          }
          await pool.listDirectory(remote);
        } finally {
          await pool.disconnect();
        }
    }
  }

  /// Uploads each [sessionPaths] directory to `{remotePath}/{folderName}/`,
  /// continuing across remaining files and sessions when errors occur.
  ///
  /// Local session files are always kept intact regardless of upload outcome.
  static Future<BatchTransferReport> uploadSessions({
    required ServerBookmark bookmark,
    required String password,
    required List<String> sessionPaths,
    TransferProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    final adapter = switch (bookmark.protocol) {
      TransferProtocol.sftp => _SftpBatchAdapter(
          bookmark: bookmark,
          password: password,
        ),
      TransferProtocol.smb => _SmbBatchAdapter(
          bookmark: bookmark,
          password: password,
        ),
    };
    return runResilientBatch(
      destinationLabel: bookmark.name,
      sessionPaths: sessionPaths,
      adapter: adapter,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  /// Executes a multi-session upload through [adapter], isolating per-file and
  /// per-session failures so healthy items continue uploading and local files
  /// are never modified or deleted.
  static Future<BatchTransferReport> runResilientBatch({
    required String destinationLabel,
    required List<String> sessionPaths,
    required BatchRemoteAdapter adapter,
    TransferProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    final succeeded = <String>[];
    final failures = <TransferItemFailure>[];
    var cancelled = false;

    try {
      for (final sessionPath in sessionPaths) {
        if (_isCancelled(isCancelled)) {
          cancelled = true;
          break;
        }
        final folderName = p.basename(sessionPath);

        List<File> files;
        try {
          final dir = Directory(sessionPath);
          if (!await dir.exists()) {
            throw StateError('Session folder missing: $sessionPath');
          }
          files = await _listFiles(sessionPath);
          if (files.isEmpty) {
            throw StateError('Session folder is empty: $sessionPath');
          }
        } catch (e) {
          final msg = _compactError(e);
          failures.add(
            TransferItemFailure(sessionFolder: folderName, error: msg),
          );
          onProgress?.call(
            TransferProgress(
              sessionFolder: folderName,
              fileName: '',
              fileIndex: 0,
              fileCount: 0,
              bytesSent: 0,
              bytesTotal: 0,
              error: msg,
            ),
          );
          continue;
        }

        try {
          await adapter.ensureSessionDir(folderName);
        } on TransferCancelled {
          cancelled = true;
          break;
        } catch (e) {
          final msg = _compactError(e);
          failures.add(
            TransferItemFailure(sessionFolder: folderName, error: msg),
          );
          onProgress?.call(
            TransferProgress(
              sessionFolder: folderName,
              fileName: '',
              fileIndex: 0,
              fileCount: files.length,
              bytesSent: 0,
              bytesTotal: 0,
              error: msg,
            ),
          );
          await adapter.resetConnection();
          continue;
        }

        Map<String, int> remoteSizes = const {};
        try {
          remoteSizes = await adapter.remoteFileSizes(folderName);
        } catch (_) {
          remoteSizes = const {};
        }

        var sessionFailed = false;
        var fileIndex = 0;
        for (final file in files) {
          if (_isCancelled(isCancelled)) {
            cancelled = true;
            break;
          }
          fileIndex++;
          final name = p.basename(file.path);

          try {
            final length = await file.length();
            if (shouldSkipIdenticalRemoteFile(
              localBytes: length,
              remoteBytes: remoteSizes[name],
            )) {
              onProgress?.call(
                TransferProgress(
                  sessionFolder: folderName,
                  fileName: name,
                  fileIndex: fileIndex,
                  fileCount: files.length,
                  bytesSent: length,
                  bytesTotal: length,
                  skipped: true,
                ),
              );
              continue;
            }

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

            await adapter.uploadFile(
              localFile: file,
              folderName: folderName,
              fileName: name,
              length: length,
              isCancelled: isCancelled,
              onFileProgress: (copied, total) {
                onProgress?.call(
                  TransferProgress(
                    sessionFolder: folderName,
                    fileName: name,
                    fileIndex: fileIndex,
                    fileCount: files.length,
                    bytesSent: copied,
                    bytesTotal: total > 0 ? total : length,
                  ),
                );
              },
            );
          } on TransferCancelled {
            cancelled = true;
            break;
          } catch (e) {
            sessionFailed = true;
            final msg = _compactError(e);
            failures.add(
              TransferItemFailure(
                sessionFolder: folderName,
                fileName: name,
                error: msg,
              ),
            );
            onProgress?.call(
              TransferProgress(
                sessionFolder: folderName,
                fileName: name,
                fileIndex: fileIndex,
                fileCount: files.length,
                bytesSent: 0,
                bytesTotal: 0,
                error: msg,
              ),
            );
            await adapter.resetConnection();
          }
        }

        if (cancelled) break;

        if (!sessionFailed) {
          succeeded.add(folderName);
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
      }
    } finally {
      try {
        await adapter.close();
      } catch (_) {}
    }

    return BatchTransferReport(
      destinationLabel: destinationLabel,
      totalSessions: sessionPaths.length,
      succeededSessions: succeeded,
      failures: failures,
      cancelled: cancelled,
    );
  }

  static Future<SSHClient> _sftpClient(
    ServerBookmark bookmark,
    String password,
  ) async {
    final socket = await SSHSocket.connect(
      bookmark.host,
      bookmark.port,
      timeout: const Duration(seconds: 20),
    );
    return SSHClient(
      socket,
      username: bookmark.username,
      onPasswordRequest: () => password,
    );
  }

  /// Lists disk shares on [host] (hides `$`-suffixed admin shares by default).
  static Future<List<String>> listShares({
    required String host,
    required String password,
    String username = '',
    String domain = '',
    bool includeHidden = false,
  }) async {
    final infos = await Smb2Pool.listSharesOn(
      host: host.trim(),
      user: username.isEmpty ? null : username,
      password: password,
      domain: domain.isEmpty ? null : domain,
    );
    final names = <String>[];
    for (final info in infos) {
      if (!info.isDisk) continue;
      final name = normalizeSmbShare(info.name);
      if (name.isEmpty) continue;
      if (!includeHidden && (info.isHidden || name.endsWith(r'$'))) continue;
      names.add(name);
    }
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  static Future<Smb2Pool> _smbPool(
    ServerBookmark bookmark,
    String password,
  ) {
    final share = normalizeSmbShare(bookmark.smbShare);
    if (share.isEmpty) {
      throw ArgumentError('SMB share name is required');
    }
    return Smb2Pool.connect(
      host: bookmark.host,
      share: share,
      user: bookmark.username.isEmpty ? null : bookmark.username,
      password: password,
      domain: bookmark.domain.isEmpty ? null : bookmark.domain,
      timeout: const Duration(seconds: 15),
    );
  }

  static Future<void> _sftpEnsureDir(SftpClient sftp, String path) async {
    final normalized = _normalizeRemote(path);
    if (normalized.isEmpty || normalized == '/') return;
    final parts = normalized.split('/').where((e) => e.isNotEmpty).toList();
    var current = '';
    for (final part in parts) {
      current = '$current/$part';
      try {
        await sftp.mkdir(current);
      } catch (_) {
        // Exists or intermediate permission — continue.
      }
    }
  }

  static String _normalizeRemote(String path) {
    var s = path.trim().replaceAll('\\', '/');
    if (s.isEmpty) return '';
    if (!s.startsWith('/')) s = '/$s';
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static Future<List<File>> _listFiles(String sessionPath) async {
    final dir = Directory(sessionPath);
    final out = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File) out.add(entity);
    }
    out.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return out;
  }

  /// Maps basename → size for files already under [remoteSession].
  static Future<Map<String, int>> _smbRemoteFileSizes(
    Smb2Pool pool,
    String remoteSession,
  ) async {
    try {
      final entries = await pool.listDirectory(remoteSession);
      final out = <String, int>{};
      for (final entry in entries) {
        if (entry.isFile) {
          out[entry.name] = entry.size;
        }
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  static bool _isCancelled(bool Function()? isCancelled) =>
      isCancelled != null && isCancelled();

  static void _throwIfCancelled(bool Function()? isCancelled) {
    if (_isCancelled(isCancelled)) {
      throw const TransferCancelled();
    }
  }

  static String _compactError(Object e) {
    final raw = '$e'.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (raw.length <= 120) return raw;
    return '${raw.substring(0, 117)}...';
  }
}

class _SftpBatchAdapter implements BatchRemoteAdapter {
  _SftpBatchAdapter({
    required this.bookmark,
    required this.password,
  }) : _remoteRoot = SessionTransfer._normalizeRemote(bookmark.remotePath);

  final ServerBookmark bookmark;
  final String password;
  final String _remoteRoot;

  SSHClient? _client;
  SftpClient? _sftp;

  String _remoteSessionPath(String folderName) =>
      _remoteRoot.isEmpty || _remoteRoot == '/'
          ? '/$folderName'
          : '$_remoteRoot/$folderName';

  Future<SftpClient> _ensureConnected() async {
    if (_client != null && _sftp != null) return _sftp!;
    final client = await SessionTransfer._sftpClient(bookmark, password);
    try {
      final sftp = await client.sftp();
      _client = client;
      _sftp = sftp;
      return sftp;
    } catch (_) {
      client.close();
      rethrow;
    }
  }

  @override
  Future<void> ensureSessionDir(String folderName) async {
    final sftp = await _ensureConnected();
    await SessionTransfer._sftpEnsureDir(sftp, _remoteSessionPath(folderName));
  }

  @override
  Future<Map<String, int>> remoteFileSizes(String folderName) async {
    // SFTP skip-by-size is not implemented yet (matches prior behavior).
    return const <String, int>{};
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
    final reconnected = _sftp == null;
    final sftp = await _ensureConnected();
    final remoteSession = _remoteSessionPath(folderName);
    if (reconnected) {
      await SessionTransfer._sftpEnsureDir(sftp, remoteSession);
    }
    final remoteFile = '$remoteSession/$fileName';
    var sent = 0;

    final remote = await sftp.open(
      remoteFile,
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    try {
      await remote
          .write(
            localFile.openRead().map((chunk) {
              SessionTransfer._throwIfCancelled(isCancelled);
              final data =
                  chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
              sent += data.length;
              onFileProgress(sent, length);
              return data;
            }),
          )
          .done;
    } finally {
      await remote.close();
    }
  }

  @override
  Future<void> resetConnection() async {
    try {
      _sftp?.close();
    } catch (_) {}
    _sftp = null;
    try {
      _client?.close();
    } catch (_) {}
    _client = null;
  }

  @override
  Future<void> close() => resetConnection();
}

class _SmbBatchAdapter implements BatchRemoteAdapter {
  _SmbBatchAdapter({
    required this.bookmark,
    required this.password,
  }) : _remoteRoot = normalizeSmbRemotePath(bookmark.remotePath);

  final ServerBookmark bookmark;
  final String password;
  final String _remoteRoot;

  Smb2Pool? _pool;

  String _remoteSessionPath(String folderName) =>
      _remoteRoot.isEmpty ? folderName : '$_remoteRoot/$folderName';

  Future<Smb2Pool> _ensureConnected() async {
    final existing = _pool;
    if (existing != null) return existing;
    final pool = await SessionTransfer._smbPool(bookmark, password);
    _pool = pool;
    return pool;
  }

  @override
  Future<void> ensureSessionDir(String folderName) async {
    final pool = await _ensureConnected();
    await pool.mkdir(_remoteSessionPath(folderName), recursive: true);
  }

  @override
  Future<Map<String, int>> remoteFileSizes(String folderName) async {
    final pool = await _ensureConnected();
    return SessionTransfer._smbRemoteFileSizes(
      pool,
      _remoteSessionPath(folderName),
    );
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
    SessionTransfer._throwIfCancelled(isCancelled);
    final reconnected = _pool == null;
    final pool = await _ensureConnected();
    final remoteSession = _remoteSessionPath(folderName);
    if (reconnected) {
      await pool.mkdir(remoteSession, recursive: true);
    }
    await pool.uploadFile(
      localFile.path,
      '$remoteSession/$fileName',
      onProgress: (copied, total) {
        SessionTransfer._throwIfCancelled(isCancelled);
        onFileProgress(copied, total);
      },
    );
  }

  @override
  Future<void> resetConnection() async {
    final pool = _pool;
    _pool = null;
    if (pool != null) {
      try {
        await pool.disconnect();
      } catch (_) {}
    }
  }

  @override
  Future<void> close() => resetConnection();
}

class TransferCancelled implements Exception {
  const TransferCancelled();

  @override
  String toString() => 'Transfer cancelled';
}
