import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import 'server_bookmark.dart';

class TransferProgress {
  const TransferProgress({
    required this.sessionFolder,
    required this.fileName,
    required this.fileIndex,
    required this.fileCount,
    required this.bytesSent,
    required this.bytesTotal,
    this.done = false,
    this.error,
  });

  final String sessionFolder;
  final String fileName;
  final int fileIndex;
  final int fileCount;
  final int bytesSent;
  final int bytesTotal;
  final bool done;
  final String? error;

  double get fraction {
    if (bytesTotal <= 0) return 0;
    return (bytesSent / bytesTotal).clamp(0.0, 1.0);
  }
}

typedef TransferProgressCallback = void Function(TransferProgress progress);

/// Uploads local `session_*` folders over SFTP or SMB.
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
          final remote = _smbRemotePath(bookmark.remotePath);
          if (remote.isNotEmpty) {
            await pool.mkdir(remote, recursive: true);
          }
          await pool.listDirectory(remote);
        } finally {
          await pool.disconnect();
        }
    }
  }

  /// Uploads each [sessionPaths] directory to `{remotePath}/{folderName}/`.
  static Future<void> uploadSessions({
    required ServerBookmark bookmark,
    required String password,
    required List<String> sessionPaths,
    TransferProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    switch (bookmark.protocol) {
      case TransferProtocol.sftp:
        await _uploadSftp(
          bookmark: bookmark,
          password: password,
          sessionPaths: sessionPaths,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
      case TransferProtocol.smb:
        await _uploadSmb(
          bookmark: bookmark,
          password: password,
          sessionPaths: sessionPaths,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
    }
  }

  static Future<void> _uploadSftp({
    required ServerBookmark bookmark,
    required String password,
    required List<String> sessionPaths,
    TransferProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    final client = await _sftpClient(bookmark, password);
    try {
      final sftp = await client.sftp();
      final remoteRoot = _normalizeRemote(bookmark.remotePath);

      for (final sessionPath in sessionPaths) {
        _throwIfCancelled(isCancelled);
        final folderName = p.basename(sessionPath);
        final remoteSession = remoteRoot.isEmpty || remoteRoot == '/'
            ? '/$folderName'
            : '$remoteRoot/$folderName';
        await _sftpEnsureDir(sftp, remoteSession);

        final files = await _listFiles(sessionPath);
        var fileIndex = 0;
        for (final file in files) {
          _throwIfCancelled(isCancelled);
          fileIndex++;
          final name = p.basename(file.path);
          final remoteFile = '$remoteSession/$name';
          final length = await file.length();
          var sent = 0;

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

          final remote = await sftp.open(
            remoteFile,
            mode: SftpFileOpenMode.create |
                SftpFileOpenMode.write |
                SftpFileOpenMode.truncate,
          );
          try {
            await remote
                .write(
                  file.openRead().map((chunk) {
                    _throwIfCancelled(isCancelled);
                    final data = chunk is Uint8List
                        ? chunk
                        : Uint8List.fromList(chunk);
                    sent += data.length;
                    onProgress?.call(
                      TransferProgress(
                        sessionFolder: folderName,
                        fileName: name,
                        fileIndex: fileIndex,
                        fileCount: files.length,
                        bytesSent: sent,
                        bytesTotal: length,
                      ),
                    );
                    return data;
                  }),
                )
                .done;
          } finally {
            await remote.close();
          }
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
    } finally {
      client.close();
    }
  }

  static Future<void> _uploadSmb({
    required ServerBookmark bookmark,
    required String password,
    required List<String> sessionPaths,
    TransferProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    final pool = await _smbPool(bookmark, password);
    try {
      final remoteRoot = _smbRemotePath(bookmark.remotePath);

      for (final sessionPath in sessionPaths) {
        _throwIfCancelled(isCancelled);
        final folderName = p.basename(sessionPath);
        final remoteSession = remoteRoot.isEmpty
            ? folderName
            : '$remoteRoot/$folderName';
        await pool.mkdir(remoteSession, recursive: true);

        final files = await _listFiles(sessionPath);
        var fileIndex = 0;
        for (final file in files) {
          _throwIfCancelled(isCancelled);
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

          await pool.uploadFile(
            file.path,
            remoteFile,
            onProgress: (copied, total) {
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
    } finally {
      await pool.disconnect();
    }
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

  static Future<Smb2Pool> _smbPool(
    ServerBookmark bookmark,
    String password,
  ) {
    final share = bookmark.smbShare.trim();
    if (share.isEmpty) {
      throw ArgumentError('SMB share name is required');
    }
    return Smb2Pool.connect(
      host: bookmark.host,
      share: share,
      user: bookmark.username.isEmpty ? null : bookmark.username,
      password: password,
      domain: bookmark.domain.isEmpty ? null : bookmark.domain,
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

  /// SMB paths are share-relative (no leading slash).
  static String _smbRemotePath(String path) {
    var s = path.trim().replaceAll('\\', '/');
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    while (s.endsWith('/')) {
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

  static void _throwIfCancelled(bool Function()? isCancelled) {
    if (isCancelled != null && isCancelled()) {
      throw const TransferCancelled();
    }
  }
}

class TransferCancelled implements Exception {
  const TransferCancelled();

  @override
  String toString() => 'Transfer cancelled';
}
