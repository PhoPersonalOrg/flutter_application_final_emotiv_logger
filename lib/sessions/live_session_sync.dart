import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:path/path.dart' as p;

import '../app/settings.dart';
import 'dropbox_config.dart';
import 'dropbox_sync.dart';
import 'dropbox_upload_session.dart';
import 'server_bookmark.dart';
import 'smb_paths.dart';

typedef LiveSyncStatusCallback = void Function(String? message);

/// Growing session files that live sync pushes.
const liveSyncGrowingFiles = ['eeg.csv', 'motion.csv', 'raw.csv'];
const liveSyncMetaFile = 'session.json';

/// Reads `[offset, length)` from [file]; empty when nothing new.
Future<Uint8List> readFileSlice(File file, int offset) async {
  final length = await file.length();
  if (offset >= length) return Uint8List(0);
  final raf = await file.open();
  try {
    await raf.setPosition(offset);
    return await raf.read(length - offset);
  } finally {
    await raf.close();
  }
}

/// Builds a compact status line from channel labels.
String formatLiveSyncStatus({
  String? dropbox,
  List<String> smb = const [],
  String? error,
}) {
  if (error != null && error.isNotEmpty) {
    return 'Sync: $error';
  }
  final parts = <String>[];
  if (dropbox != null && dropbox.isNotEmpty) parts.add(dropbox);
  parts.addAll(smb);
  if (parts.isEmpty) return 'Sync: idle';
  return 'Sync: ${parts.join(' · ')}';
}

/// Whether a periodic tick should be skipped (not running or already busy).
bool shouldSkipLiveSyncTick({
  required bool running,
  required bool tickInFlight,
}) =>
    !running || tickInFlight;

/// Live incremental sync of a `session_*` folder to Dropbox and/or SMB.
class LiveSessionSync {
  LiveSessionSync({
    DropboxSync? dropbox,
    required Future<BookmarkStoreState> Function() loadBookmarks,
    required Future<String?> Function(String bookmarkId) readPassword,
    LiveSyncStatusCallback? onStatus,
    this.tickInterval = const Duration(seconds: 5),
    DropboxUploadSessionClient? dropboxClient,
  })  : _dropbox = dropbox ?? DropboxSync(),
        _loadBookmarks = loadBookmarks,
        _readPassword = readPassword,
        _onStatus = onStatus,
        _dropboxHttp = dropboxClient ?? DropboxUploadSessionClient();

  final DropboxSync _dropbox;
  final Future<BookmarkStoreState> Function() _loadBookmarks;
  final Future<String?> Function(String bookmarkId) _readPassword;
  final LiveSyncStatusCallback? _onStatus;
  final Duration tickInterval;
  final DropboxUploadSessionClient _dropboxHttp;

  Timer? _timer;
  Future<void>? _tickInFlight;
  bool _running = false;
  String? _sessionPath;
  Future<void> Function()? _flushCsv;

  _DropboxLiveChannel? _dropboxChannel;
  final List<_SmbLiveChannel> _smbChannels = [];

  bool get isRunning => _running;

  void _status(String? message) => _onStatus?.call(message);

  Future<void> start({
    required String sessionPath,
    required AppSettings settings,
    Future<void> Function()? flushCsv,
  }) async {
    await stop(timeout: const Duration(seconds: 5));
    if (sessionPath.isEmpty) return;

    _sessionPath = sessionPath;
    _flushCsv = flushCsv;
    _running = true;

    final folderName = p.basename(sessionPath);
    final enabled = <String>[];

    if (settings.dropboxLiveSync && DropboxConfig.isConfigured) {
      try {
        if (await _dropbox.isLinked()) {
          _dropboxChannel = _DropboxLiveChannel(
            client: _dropboxHttp,
            sessionPath: sessionPath,
            folderName: folderName,
            remoteRoot: settings.dropboxRemoteRoot,
          );
          await _dropboxChannel!.bootstrap();
          enabled.add('Dropbox live (commits on Stop)');
        }
      } catch (e) {
        _status(formatLiveSyncStatus(error: 'Dropbox start failed: $e'));
      }
    }

    try {
      final bookmarks = await _loadBookmarks();
      for (final b in bookmarks.bookmarks) {
        if (b.protocol != TransferProtocol.smb) continue;
        if (!b.liveSync || !b.rememberPassword) continue;
        final password = await _readPassword(b.id);
        if (password == null || password.isEmpty) continue;
        try {
          final channel = _SmbLiveChannel(
            bookmark: b,
            password: password,
            sessionPath: sessionPath,
            folderName: folderName,
          );
          await channel.bootstrap();
          _smbChannels.add(channel);
          enabled.add('SMB ${b.name}');
        } catch (e) {
          _status(formatLiveSyncStatus(error: 'SMB ${b.name}: $e'));
        }
      }
    } catch (e) {
      _status(formatLiveSyncStatus(error: 'Bookmarks: $e'));
    }

    if (_dropboxChannel == null && _smbChannels.isEmpty) {
      _running = false;
      _sessionPath = null;
      _status(null);
      return;
    }

    _status(
      formatLiveSyncStatus(
        dropbox: _dropboxChannel == null
            ? null
            : 'Dropbox live (commits on Stop)',
        smb: [
          for (final c in _smbChannels) 'SMB ${c.bookmark.name}',
        ],
      ),
    );

    _timer = Timer.periodic(tickInterval, (_) {
      unawaited(_requestTick());
    });
    unawaited(_requestTick());
  }

  Future<void> _requestTick() async {
    if (shouldSkipLiveSyncTick(
      running: _running,
      tickInFlight: _tickInFlight != null,
    )) {
      return;
    }
    final done = _tick();
    _tickInFlight = done;
    try {
      await done;
    } finally {
      if (identical(_tickInFlight, done)) {
        _tickInFlight = null;
      }
    }
  }

  Future<void> _tick({bool finalizing = false}) async {
    final sessionPath = _sessionPath;
    if (sessionPath == null) return;

    try {
      await _flushCsv?.call();
    } catch (_) {}

    final dropboxLabel = _dropboxChannel == null
        ? null
        : (finalizing
            ? 'Dropbox committing…'
            : 'Dropbox live (commits on Stop)');
    final smbLabels = <String>[];

    if (_dropboxChannel != null) {
      try {
        await _dropboxChannel!.syncTick(finalizing: finalizing);
      } catch (e) {
        _status(formatLiveSyncStatus(error: 'Dropbox: $e'));
        return;
      }
    }

    for (final channel in _smbChannels) {
      try {
        await channel.syncTick();
        smbLabels.add('SMB ${channel.bookmark.name}');
      } catch (e) {
        _status(
          formatLiveSyncStatus(error: 'SMB ${channel.bookmark.name}: $e'),
        );
        return;
      }
    }

    if (!finalizing) {
      _status(
        formatLiveSyncStatus(dropbox: dropboxLabel, smb: smbLabels),
      );
    }
  }

  /// Final flush + commit; best-effort, bounded by [timeout].
  Future<void> stop({
    Duration timeout = const Duration(seconds: 45),
  }) async {
    _timer?.cancel();
    _timer = null;
    if (!_running && _dropboxChannel == null && _smbChannels.isEmpty) {
      return;
    }
    _running = false;

    // Wait for any in-flight tick so we do not race append/commit.
    final inFlight = _tickInFlight;
    if (inFlight != null) {
      try {
        await inFlight.timeout(timeout);
      } catch (_) {}
    }

    final hadDropbox = _dropboxChannel != null;
    final smbNames = [for (final c in _smbChannels) c.bookmark.name];

    try {
      await Future(() async {
        await _tick(finalizing: true);
        if (_dropboxChannel != null) {
          await _dropboxChannel!.commit();
        }
        for (final channel in List<_SmbLiveChannel>.from(_smbChannels)) {
          await channel.close();
        }
      }).timeout(timeout);
      if (hadDropbox || smbNames.isNotEmpty) {
        _status(
          formatLiveSyncStatus(
            dropbox: hadDropbox ? 'Dropbox committed' : null,
            smb: [for (final name in smbNames) 'SMB $name ok'],
          ),
        );
      }
    } catch (e) {
      _status(formatLiveSyncStatus(error: 'finalize failed: $e'));
    } finally {
      _dropboxChannel = null;
      _smbChannels.clear();
      _sessionPath = null;
      _flushCsv = null;
      _tickInFlight = null;
    }
  }

  Future<void> dispose() async {
    await stop(timeout: const Duration(seconds: 10));
    _dropboxHttp.close();
  }
}

class _DropboxLiveChannel {
  _DropboxLiveChannel({
    required this.client,
    required this.sessionPath,
    required this.folderName,
    required String remoteRoot,
  }) : remoteSession = _remoteSessionPath(remoteRoot, folderName);

  final DropboxUploadSessionClient client;
  final String sessionPath;
  final String folderName;
  final String remoteSession;

  final Map<String, DropboxGrowingUpload> _uploads = {};
  final Map<String, int> _localOffsets = {};
  bool _metaUploaded = false;

  static String _remoteSessionPath(String remoteRoot, String folderName) {
    var root = remoteRoot.trim().replaceAll('\\', '/');
    while (root.startsWith('/')) {
      root = root.substring(1);
    }
    while (root.endsWith('/')) {
      root = root.substring(0, root.length - 1);
    }
    if (root.isEmpty) root = DropboxSync.defaultRemoteRoot;
    return '/$root/$folderName';
  }

  Future<void> bootstrap() async {
    final meta = File(p.join(sessionPath, liveSyncMetaFile));
    if (await meta.exists()) {
      final bytes = await meta.readAsBytes();
      await client.uploadBytes(
        remotePath: '$remoteSession/$liveSyncMetaFile',
        data: Uint8List.fromList(bytes),
      );
      _metaUploaded = true;
    }
    for (final name in liveSyncGrowingFiles) {
      final remote = '$remoteSession/$name';
      _uploads[name] = DropboxGrowingUpload(client, remote);
      _localOffsets[name] = 0;
    }
  }

  Future<void> syncTick({required bool finalizing}) async {
    if (!_metaUploaded) {
      final meta = File(p.join(sessionPath, liveSyncMetaFile));
      if (await meta.exists()) {
        final bytes = await meta.readAsBytes();
        await client.uploadBytes(
          remotePath: '$remoteSession/$liveSyncMetaFile',
          data: Uint8List.fromList(bytes),
        );
        _metaUploaded = true;
      }
    }

    for (final name in liveSyncGrowingFiles) {
      final file = File(p.join(sessionPath, name));
      if (!await file.exists()) continue;
      final offset = _localOffsets[name] ?? 0;
      final slice = await readFileSlice(file, offset);
      if (slice.isEmpty) continue;
      final upload = _uploads[name]!;
      await upload.appendBytes(slice);
      _localOffsets[name] = offset + slice.length;
    }
  }

  Future<void> commit() async {
    for (final name in liveSyncGrowingFiles) {
      final upload = _uploads[name];
      if (upload == null) continue;
      // Ensure any bytes written after last tick are included.
      final file = File(p.join(sessionPath, name));
      if (await file.exists()) {
        final offset = _localOffsets[name] ?? 0;
        final slice = await readFileSlice(file, offset);
        if (slice.isNotEmpty) {
          await upload.appendBytes(slice);
          _localOffsets[name] = offset + slice.length;
        }
      }
      await upload.commit();
    }
  }
}

class _SmbLiveChannel {
  _SmbLiveChannel({
    required this.bookmark,
    required this.password,
    required this.sessionPath,
    required this.folderName,
  });

  final ServerBookmark bookmark;
  final String password;
  final String sessionPath;
  final String folderName;

  Smb2Pool? _pool;
  String? _remoteSession;
  final Map<String, Smb2PoolHandle> _handles = {};
  final Map<String, int> _offsets = {};

  Future<void> bootstrap() async {
    final share = normalizeSmbShare(bookmark.smbShare);
    if (share.isEmpty) {
      throw ArgumentError('SMB share name is required');
    }
    _pool = await Smb2Pool.connect(
      host: bookmark.host,
      share: share,
      user: bookmark.username.isEmpty ? null : bookmark.username,
      password: password,
      domain: bookmark.domain.isEmpty ? null : bookmark.domain,
    );
    final remoteRoot = normalizeSmbRemotePath(bookmark.remotePath);
    _remoteSession = remoteRoot.isEmpty
        ? folderName
        : '$remoteRoot/$folderName';
    await _pool!.mkdir(_remoteSession!, recursive: true);

    final meta = File(p.join(sessionPath, liveSyncMetaFile));
    if (await meta.exists()) {
      await _pool!.uploadFile(
        meta.path,
        '$_remoteSession/$liveSyncMetaFile',
      );
    }

    for (final name in liveSyncGrowingFiles) {
      final remoteFile = '$_remoteSession/$name';
      final handle = await _pool!.openFileWrite(remoteFile, truncate: true);
      _handles[name] = handle;
      _offsets[name] = 0;
    }
  }

  Future<void> syncTick() async {
    final pool = _pool;
    if (pool == null) return;
    for (final name in liveSyncGrowingFiles) {
      final handle = _handles[name];
      if (handle == null) continue;
      final file = File(p.join(sessionPath, name));
      if (!await file.exists()) continue;
      final offset = _offsets[name] ?? 0;
      final slice = await readFileSlice(file, offset);
      if (slice.isEmpty) continue;
      await pool.writeToHandle(handle, slice, offset: offset);
      _offsets[name] = offset + slice.length;
    }
  }

  Future<void> close() async {
    final pool = _pool;
    if (pool == null) return;
    try {
      await syncTick();
      for (final handle in _handles.values) {
        try {
          await pool.fsyncHandle(handle);
        } catch (_) {}
        try {
          await pool.closeHandle(handle);
        } catch (_) {}
      }
    } finally {
      _handles.clear();
      try {
        await pool.disconnect();
      } catch (_) {}
      _pool = null;
    }
  }
}
