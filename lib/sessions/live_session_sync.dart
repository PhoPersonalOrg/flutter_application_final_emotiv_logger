import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import '../app/settings.dart';
import 'dropbox_config.dart';
import 'dropbox_sync.dart';
import 'dropbox_upload_session.dart';
import 'server_bookmark.dart';
import 'smb_paths.dart';

typedef LiveSyncStatusCallback = void Function(String? message);

/// Growing session files that live sync pushes.
const liveSyncGrowingFiles = ['eeg.csv', 'motion.csv', 'cq.csv', 'raw.csv'];
const liveSyncMetaFile = 'session.json';

/// Reads `[offset, length)` from [file] (read-only); empty when nothing new.
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

/// Builds a compact status line from healthy channel labels and channel errors.
String formatLiveSyncStatus({
  String? dropbox,
  List<String> smb = const [],
  List<String> sftp = const [],
  List<String> channelErrors = const [],
  String? error,
}) {
  final parts = <String>[];
  if (dropbox != null && dropbox.isNotEmpty) parts.add(dropbox);
  parts.addAll(smb.where((s) => s.isNotEmpty));
  parts.addAll(sftp.where((s) => s.isNotEmpty));
  parts.addAll(channelErrors.where((s) => s.isNotEmpty));
  if (error != null && error.isNotEmpty) parts.add(error);
  if (parts.isEmpty) return 'Sync: idle';
  return 'Sync: ${parts.join(' · ')}';
}

/// Whether a periodic tick should be skipped (not running or already busy).
bool shouldSkipLiveSyncTick({
  required bool running,
  required bool tickInFlight,
}) =>
    !running || tickInFlight;

/// Pluggable destination channel for live incremental session sync.
///
/// Implementations must treat local session files as strictly read-only and
/// never delete or modify local files on upload success or failure.
abstract class LiveSyncChannel {
  /// Short destination name for error reporting (e.g. `Dropbox`, `SMB NAS`).
  String get shortName;

  /// Healthy status label while actively syncing.
  String get activeLabel;

  /// Status label once finalized after Stop.
  String get committedLabel;

  /// Pushes any new bytes from local session files to the remote destination.
  Future<void> syncTick({required bool finalizing});

  /// Flushes any remaining bytes and commits/closes remote handles.
  Future<void> finalizeAndClose();
}

typedef BookmarkLiveChannelBuilder = LiveSyncChannel Function(
  ServerBookmark bookmark,
  String password,
  String sessionPath,
  String folderName,
);

typedef DropboxLiveChannelBuilder = LiveSyncChannel Function(
  String sessionPath,
  String folderName,
  String remoteRoot,
);

/// Live incremental sync of `session_*` folders to Dropbox, SMB, and/or SFTP.
///
/// Runs asynchronously in the background:
/// - `start()` registers enabled destinations without awaiting network connect,
///   detaching any prior session run so starting a new recording never blocks.
/// - Ticks and finalization run all channels concurrently via [Future.wait];
///   an error on one file or server never stops other files or servers, and
///   failed channels retry with exponential backoff from their saved offsets.
/// - Local CSV files are always kept intact on device.
class LiveSessionSync {
  LiveSessionSync({
    DropboxSync? dropbox,
    required Future<BookmarkStoreState> Function() loadBookmarks,
    required Future<String?> Function(String bookmarkId) readPassword,
    LiveSyncStatusCallback? onStatus,
    this.tickInterval = const Duration(seconds: 5),
    this.baseBackoff = const Duration(seconds: 5),
    this.maxBackoff = const Duration(seconds: 30),
    DateTime Function()? clock,
    DropboxUploadSessionClient? dropboxClient,
    Future<bool> Function()? isDropboxLinked,
    DropboxLiveChannelBuilder? dropboxChannelBuilder,
    BookmarkLiveChannelBuilder? bookmarkChannelBuilder,
  })  : _dropbox = dropbox ?? DropboxSync(),
        _loadBookmarks = loadBookmarks,
        _readPassword = readPassword,
        _onStatus = onStatus,
        _clock = clock ?? DateTime.now,
        _dropboxHttp = dropboxClient ?? DropboxUploadSessionClient(),
        _isDropboxLinked = isDropboxLinked,
        _dropboxChannelBuilder = dropboxChannelBuilder,
        _bookmarkChannelBuilder = bookmarkChannelBuilder;

  final DropboxSync _dropbox;
  final Future<BookmarkStoreState> Function() _loadBookmarks;
  final Future<String?> Function(String bookmarkId) _readPassword;
  final LiveSyncStatusCallback? _onStatus;
  final Duration tickInterval;
  final Duration baseBackoff;
  final Duration maxBackoff;
  final DateTime Function() _clock;
  final DropboxUploadSessionClient _dropboxHttp;
  final Future<bool> Function()? _isDropboxLinked;
  final DropboxLiveChannelBuilder? _dropboxChannelBuilder;
  final BookmarkLiveChannelBuilder? _bookmarkChannelBuilder;

  _LiveSyncSessionRun? _activeRun;
  final Set<Future<void>> _finalizingFutures = {};
  int _startGen = 0;

  bool get isRunning => _activeRun != null && _activeRun!.isRunning;

  /// Number of detached session runs still finalizing in the background.
  int get finalizingCount => _finalizingFutures.length;

  void _status(String? message) => _onStatus?.call(message);

  Future<void> start({
    required String sessionPath,
    required AppSettings settings,
    Future<void> Function()? flushCsv,
  }) async {
    final gen = ++_startGen;

    // Detach any prior session run into background finalization immediately
    // without blocking the new session's startup.
    final previous = _activeRun;
    if (previous != null) {
      _activeRun = null;
      previous.detachFlushCsv();
      _trackFinalizing(_finalizeRun(previous, timeout: const Duration(seconds: 60)));
    }

    if (sessionPath.isEmpty) return;

    final folderName = p.basename(sessionPath);
    final channels = <LiveSyncChannel>[];
    final setupErrors = <String>[];

    final checkDropbox = settings.dropboxLiveSync &&
        (_dropboxChannelBuilder != null || DropboxConfig.isConfigured);
    if (checkDropbox) {
      try {
        final linked =
            await (_isDropboxLinked?.call() ?? _dropbox.isLinked());
        if (linked) {
          final ch = _dropboxChannelBuilder != null
              ? _dropboxChannelBuilder(
                  sessionPath,
                  folderName,
                  settings.dropboxRemoteRoot,
                )
              : _DropboxLiveChannel(
                  client: _dropboxHttp,
                  sessionPath: sessionPath,
                  folderName: folderName,
                  remoteRoot: settings.dropboxRemoteRoot,
                );
          channels.add(ch);
        }
      } catch (e) {
        setupErrors.add('Dropbox (${_compactError(e)})');
      }
    }

    if (_startGen != gen) return;

    try {
      final bookmarks = await _loadBookmarks();
      if (_startGen != gen) return;
      for (final b in bookmarks.bookmarks) {
        if (!b.liveSync || !b.rememberPassword) continue;
        try {
          final password = await _readPassword(b.id);
          if (_startGen != gen) return;
          if (password == null || password.isEmpty) continue;
          final ch = _bookmarkChannelBuilder != null
              ? _bookmarkChannelBuilder(b, password, sessionPath, folderName)
              : _buildDefaultBookmarkChannel(
                  bookmark: b,
                  password: password,
                  sessionPath: sessionPath,
                  folderName: folderName,
                );
          channels.add(ch);
        } catch (e) {
          setupErrors.add('${b.protocol.label} ${b.name} (${_compactError(e)})');
        }
      }
    } catch (e) {
      setupErrors.add('Bookmarks (${_compactError(e)})');
    }

    if (_startGen != gen) return;

    if (channels.isEmpty) {
      if (setupErrors.isNotEmpty) {
        _status(formatLiveSyncStatus(channelErrors: setupErrors));
      } else if (_finalizingFutures.isEmpty) {
        _status(null);
      }
      return;
    }

    late final _LiveSyncSessionRun run;
    run = _LiveSyncSessionRun(
      channels: [
        for (final ch in channels)
          _ResilientChannelRunner(
            channel: ch,
            clock: _clock,
            baseBackoff: baseBackoff,
            maxBackoff: maxBackoff,
          ),
      ],
      tickInterval: tickInterval,
      flushCsv: flushCsv,
      initialErrors: setupErrors,
      onStatus: (msg) {
        if (identical(_activeRun, run)) {
          _status(msg);
        }
      },
    );
    _activeRun = run;
    run.start();
  }

  LiveSyncChannel _buildDefaultBookmarkChannel({
    required ServerBookmark bookmark,
    required String password,
    required String sessionPath,
    required String folderName,
  }) {
    return switch (bookmark.protocol) {
      TransferProtocol.smb => _SmbLiveChannel(
          bookmark: bookmark,
          password: password,
          sessionPath: sessionPath,
          folderName: folderName,
        ),
      TransferProtocol.sftp => _SftpLiveChannel(
          bookmark: bookmark,
          password: password,
          sessionPath: sessionPath,
          folderName: folderName,
        ),
    };
  }

  /// Detaches the active session run synchronously and finalizes remaining
  /// bytes in the background (bounded by [timeout]).
  ///
  /// Callers on the BLE teardown path may invoke this with `unawaited(...)` so
  /// BLE disconnect and new recordings are never blocked; tests and `dispose()`
  /// may `await` it to wait for finalization to settle.
  Future<void> stop({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    _startGen++;
    final run = _activeRun;
    if (run == null) {
      if (_finalizingFutures.isNotEmpty) {
        await Future.wait(List<Future<void>>.from(_finalizingFutures));
      }
      return;
    }
    _activeRun = null;
    run.detachFlushCsv();
    final future = _finalizeRun(run, timeout: timeout);
    _trackFinalizing(future);
    await future;
  }

  void _trackFinalizing(Future<void> future) {
    _finalizingFutures.add(future);
    future.whenComplete(() {
      _finalizingFutures.remove(future);
    });
  }

  Future<void> _finalizeRun(
    _LiveSyncSessionRun run, {
    required Duration timeout,
  }) async {
    final summary = await run.finalize(timeout: timeout);
    // Do not clobber a newer active recording's live sync status.
    if (_activeRun == null && summary != null) {
      _status(summary);
    }
  }

  Future<void> dispose() async {
    _startGen++;
    final run = _activeRun;
    _activeRun = null;
    if (run != null) {
      run.detachFlushCsv();
      _trackFinalizing(
        _finalizeRun(run, timeout: const Duration(seconds: 10)),
      );
    }
    if (_finalizingFutures.isNotEmpty) {
      try {
        await Future.wait(
          List<Future<void>>.from(_finalizingFutures),
        ).timeout(const Duration(seconds: 10));
      } catch (_) {}
    }
    _dropboxHttp.close();
  }
}

class _LiveSyncSessionRun {
  _LiveSyncSessionRun({
    required this.channels,
    required this.tickInterval,
    required Future<void> Function()? flushCsv,
    required List<String> initialErrors,
    required this.onStatus,
  })  : _flushCsv = flushCsv,
        _stickySetupErrors = List.unmodifiable(initialErrors);

  final List<_ResilientChannelRunner> channels;
  final Duration tickInterval;
  final List<String> _stickySetupErrors;
  final LiveSyncStatusCallback onStatus;

  Future<void> Function()? _flushCsv;
  Timer? _timer;
  Future<void>? _tickInFlight;
  bool _running = false;

  bool get isRunning => _running;

  void detachFlushCsv() {
    _flushCsv = null;
  }

  void start() {
    _running = true;
    onStatus(_buildLiveStatus());
    _timer = Timer.periodic(tickInterval, (_) {
      unawaited(requestTick());
    });
    unawaited(requestTick());
  }

  Future<void> requestTick() async {
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

  Future<void> _tick() async {
    try {
      await _flushCsv?.call();
    } catch (_) {}

    await Future.wait(
      channels.map((runner) => runner.runTick(finalizing: false)),
    );

    if (_running) {
      onStatus(_buildLiveStatus());
    }
  }

  Future<String?> finalize({required Duration timeout}) async {
    _timer?.cancel();
    _timer = null;
    _running = false;

    final inFlight = _tickInFlight;
    if (inFlight != null) {
      try {
        await inFlight.timeout(timeout);
      } catch (_) {}
    }

    if (channels.isEmpty) return null;

    try {
      await Future.wait(
        channels.map((runner) => runner.runFinalize()),
      ).timeout(timeout);
    } catch (e) {
      return formatLiveSyncStatus(
        channelErrors: [
          ..._stickySetupErrors,
          'finalize timeout (${_compactError(e)})',
        ],
      );
    }

    final healthy = <String>[];
    final errors = <String>[..._stickySetupErrors];
    for (final r in channels) {
      if (r.lastError != null) {
        errors.add('${r.channel.shortName} (err: ${r.lastError})');
      } else {
        healthy.add(r.channel.committedLabel);
      }
    }
    return formatLiveSyncStatus(
      smb: healthy,
      channelErrors: errors,
    );
  }

  String _buildLiveStatus() {
    final healthy = <String>[];
    final errors = <String>[..._stickySetupErrors];
    for (final r in channels) {
      if (r.lastError != null) {
        errors.add('${r.channel.shortName} (err: ${r.lastError})');
      } else {
        healthy.add(r.channel.activeLabel);
      }
    }
    return formatLiveSyncStatus(
      smb: healthy,
      channelErrors: errors,
    );
  }
}

class _ResilientChannelRunner {
  _ResilientChannelRunner({
    required this.channel,
    required this.clock,
    required this.baseBackoff,
    required this.maxBackoff,
  });

  final LiveSyncChannel channel;
  final DateTime Function() clock;
  final Duration baseBackoff;
  final Duration maxBackoff;

  int _consecutiveFailures = 0;
  DateTime? _nextRetryAt;
  String? _lastError;

  String? get lastError => _lastError;

  Duration _backoffDuration(int failures) {
    if (failures <= 0) return Duration.zero;
    final shift = (failures - 1).clamp(0, 6);
    final scaledMs = baseBackoff.inMilliseconds * (1 << shift);
    final cappedMs = scaledMs > maxBackoff.inMilliseconds
        ? maxBackoff.inMilliseconds
        : scaledMs;
    return Duration(milliseconds: cappedMs);
  }

  Future<void> runTick({required bool finalizing}) async {
    if (!finalizing && _nextRetryAt != null && clock().isBefore(_nextRetryAt!)) {
      return;
    }
    try {
      await channel.syncTick(finalizing: finalizing);
      _consecutiveFailures = 0;
      _nextRetryAt = null;
      _lastError = null;
    } catch (e) {
      _consecutiveFailures++;
      _lastError = _compactError(e);
      _nextRetryAt = clock().add(_backoffDuration(_consecutiveFailures));
    }
  }

  Future<void> runFinalize() async {
    try {
      await channel.finalizeAndClose();
      _consecutiveFailures = 0;
      _nextRetryAt = null;
      _lastError = null;
    } catch (e) {
      _lastError = _compactError(e);
    }
  }
}

String _compactError(Object e) {
  final raw = '$e'.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (raw.length <= 96) return raw;
  return '${raw.substring(0, 93)}...';
}

class _DropboxLiveChannel implements LiveSyncChannel {
  _DropboxLiveChannel({
    required this.client,
    required this.sessionPath,
    required this.folderName,
    required String remoteRoot,
  }) : remoteSession = _remoteSessionPath(remoteRoot, folderName) {
    for (final name in liveSyncGrowingFiles) {
      _uploads[name] = DropboxGrowingUpload(client, '$remoteSession/$name');
      _localOffsets[name] = 0;
    }
  }

  final DropboxUploadSessionClient client;
  final String sessionPath;
  final String folderName;
  final String remoteSession;

  final Map<String, DropboxGrowingUpload> _uploads = {};
  final Map<String, int> _localOffsets = {};
  bool _metaUploaded = false;

  @override
  String get shortName => 'Dropbox';

  @override
  String get activeLabel => 'Dropbox live (commits on Stop)';

  @override
  String get committedLabel => 'Dropbox committed';

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

  static bool _isInvalidSessionError(Object e) {
    final s = '$e'.toLowerCase();
    return s.contains('not_found') ||
        s.contains('closed') ||
        s.contains('incorrect_offset') ||
        s.contains('409');
  }

  @override
  Future<void> syncTick({required bool finalizing}) async {
    final fileErrors = <String>[];

    if (!_metaUploaded) {
      try {
        final meta = File(p.join(sessionPath, liveSyncMetaFile));
        if (await meta.exists()) {
          final bytes = await meta.readAsBytes();
          await client.uploadBytes(
            remotePath: '$remoteSession/$liveSyncMetaFile',
            data: Uint8List.fromList(bytes),
          );
          _metaUploaded = true;
        }
      } catch (e) {
        fileErrors.add('$liveSyncMetaFile: ${_compactError(e)}');
      }
    }

    for (final name in liveSyncGrowingFiles) {
      try {
        final file = File(p.join(sessionPath, name));
        if (!await file.exists()) continue;
        final offset = _localOffsets[name] ?? 0;
        final slice = await readFileSlice(file, offset);
        if (slice.isEmpty) continue;
        final upload =
            _uploads[name] ??= DropboxGrowingUpload(client, '$remoteSession/$name');
        await upload.appendBytes(slice);
        _localOffsets[name] = offset + slice.length;
      } catch (e) {
        if (_isInvalidSessionError(e)) {
          _uploads[name] = DropboxGrowingUpload(client, '$remoteSession/$name');
          _localOffsets[name] = 0;
        }
        fileErrors.add('$name: ${_compactError(e)}');
      }
    }

    if (fileErrors.isNotEmpty) {
      throw StateError(fileErrors.join('; '));
    }
  }

  @override
  Future<void> finalizeAndClose() async {
    final fileErrors = <String>[];

    if (!_metaUploaded) {
      try {
        final meta = File(p.join(sessionPath, liveSyncMetaFile));
        if (await meta.exists()) {
          final bytes = await meta.readAsBytes();
          await client.uploadBytes(
            remotePath: '$remoteSession/$liveSyncMetaFile',
            data: Uint8List.fromList(bytes),
          );
          _metaUploaded = true;
        }
      } catch (e) {
        fileErrors.add('$liveSyncMetaFile: ${_compactError(e)}');
      }
    }

    for (final name in liveSyncGrowingFiles) {
      final file = File(p.join(sessionPath, name));
      final exists = await file.exists();
      final upload =
          _uploads[name] ??= DropboxGrowingUpload(client, '$remoteSession/$name');
      if (!exists && upload.sessionId == null) continue;

      try {
        if (exists) {
          final offset = _localOffsets[name] ?? 0;
          final slice = await readFileSlice(file, offset);
          if (slice.isNotEmpty) {
            await upload.appendBytes(slice);
            _localOffsets[name] = offset + slice.length;
          }
        }
        await upload.commit();
      } catch (e) {
        if (exists && _isInvalidSessionError(e)) {
          // Recover from stale/mismatched upload_session by re-streaming full local file.
          try {
            final fresh = DropboxGrowingUpload(client, '$remoteSession/$name');
            final allBytes = Uint8List.fromList(await file.readAsBytes());
            if (allBytes.isNotEmpty) {
              await fresh.appendBytes(allBytes);
            }
            await fresh.commit();
            _uploads[name] = fresh;
            _localOffsets[name] = allBytes.length;
            continue;
          } catch (retryErr) {
            fileErrors.add('$name: ${_compactError(retryErr)}');
            continue;
          }
        }
        fileErrors.add('$name: ${_compactError(e)}');
      }
    }

    if (fileErrors.isNotEmpty) {
      throw StateError(fileErrors.join('; '));
    }
  }
}

class _SmbLiveChannel implements LiveSyncChannel {
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
  final Set<String> _createdRemotely = {};
  bool _metaUploaded = false;

  @override
  String get shortName => 'SMB ${bookmark.name}';

  @override
  String get activeLabel => 'SMB ${bookmark.name}';

  @override
  String get committedLabel => 'SMB ${bookmark.name} ok';

  Future<void> _ensureConnected() async {
    if (_pool != null) return;
    final share = normalizeSmbShare(bookmark.smbShare);
    if (share.isEmpty) {
      throw ArgumentError('SMB share name is required');
    }
    final pool = await Smb2Pool.connect(
      host: bookmark.host,
      share: share,
      user: bookmark.username.isEmpty ? null : bookmark.username,
      password: password,
      domain: bookmark.domain.isEmpty ? null : bookmark.domain,
      workers: 2,
      timeout: const Duration(seconds: 10),
    );
    try {
      final remoteRoot = normalizeSmbRemotePath(bookmark.remotePath);
      final remoteSession =
          remoteRoot.isEmpty ? folderName : '$remoteRoot/$folderName';
      await pool.mkdir(remoteSession, recursive: true);
      _pool = pool;
      _remoteSession = remoteSession;
    } catch (_) {
      try {
        await pool.disconnect();
      } catch (_) {}
      rethrow;
    }
  }

  Future<Smb2PoolHandle> _ensureHandle(String name) async {
    final existing = _handles[name];
    if (existing != null) return existing;
    final shouldTruncate =
        (_offsets[name] ?? 0) == 0 && !_createdRemotely.contains(name);
    final handle = await _pool!.openFileWrite(
      '$_remoteSession/$name',
      truncate: shouldTruncate,
    );
    _createdRemotely.add(name);
    _handles[name] = handle;
    return handle;
  }

  Future<void> _resetConnection({bool flushHandles = false}) async {
    final pool = _pool;
    _pool = null;
    if (pool != null) {
      for (final handle in _handles.values) {
        if (flushHandles) {
          try {
            await pool.fsyncHandle(handle);
          } catch (_) {}
        }
        try {
          await pool.closeHandle(handle);
        } catch (_) {}
      }
      _handles.clear();
      try {
        await pool.disconnect();
      } catch (_) {}
    } else {
      _handles.clear();
    }
  }

  @override
  Future<void> syncTick({required bool finalizing}) async {
    try {
      await _ensureConnected();
    } catch (_) {
      await _resetConnection();
      rethrow;
    }

    final fileErrors = <String>[];

    if (!_metaUploaded) {
      try {
        final meta = File(p.join(sessionPath, liveSyncMetaFile));
        if (await meta.exists()) {
          await _pool!.uploadFile(
            meta.path,
            '$_remoteSession/$liveSyncMetaFile',
          );
          _metaUploaded = true;
        }
      } catch (e) {
        fileErrors.add('$liveSyncMetaFile: ${_compactError(e)}');
      }
    }

    for (final name in liveSyncGrowingFiles) {
      try {
        final file = File(p.join(sessionPath, name));
        if (!await file.exists()) continue;
        final handle = await _ensureHandle(name);
        final offset = _offsets[name] ?? 0;
        final slice = await readFileSlice(file, offset);
        if (slice.isEmpty) continue;
        await _pool!.writeToHandle(handle, slice, offset: offset);
        _offsets[name] = offset + slice.length;
      } catch (e) {
        final dead = _handles.remove(name);
        if (dead != null && _pool != null) {
          try {
            await _pool!.closeHandle(dead);
          } catch (_) {}
        }
        fileErrors.add('$name: ${_compactError(e)}');
      }
    }

    if (fileErrors.isNotEmpty) {
      await _resetConnection();
      throw StateError(fileErrors.join('; '));
    }
  }

  @override
  Future<void> finalizeAndClose() async {
    Object? syncError;
    try {
      await syncTick(finalizing: true);
    } catch (e) {
      syncError = e;
    } finally {
      await _resetConnection(flushHandles: syncError == null);
    }
    if (syncError != null) {
      throw syncError;
    }
  }
}

class _SftpLiveChannel implements LiveSyncChannel {
  _SftpLiveChannel({
    required this.bookmark,
    required this.password,
    required this.sessionPath,
    required this.folderName,
  });

  final ServerBookmark bookmark;
  final String password;
  final String sessionPath;
  final String folderName;

  SSHClient? _ssh;
  SftpClient? _sftp;
  String? _remoteSession;
  final Map<String, SftpFile> _handles = {};
  final Map<String, int> _offsets = {};
  final Set<String> _createdRemotely = {};
  bool _metaUploaded = false;

  @override
  String get shortName => 'SFTP ${bookmark.name}';

  @override
  String get activeLabel => 'SFTP ${bookmark.name}';

  @override
  String get committedLabel => 'SFTP ${bookmark.name} ok';

  static String _normalizeRemote(String path) {
    var s = path.trim().replaceAll('\\', '/');
    if (s.isEmpty) return '';
    if (!s.startsWith('/')) s = '/$s';
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
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
        // Already exists or intermediate directory not writable — continue.
      }
    }
  }

  Future<void> _ensureConnected() async {
    if (_ssh != null && _sftp != null) return;
    final socket = await SSHSocket.connect(
      bookmark.host,
      bookmark.port,
      timeout: const Duration(seconds: 10),
    );
    final ssh = SSHClient(
      socket,
      username: bookmark.username,
      onPasswordRequest: () => password,
    );
    try {
      final sftp = await ssh.sftp();
      final remoteRoot = _normalizeRemote(bookmark.remotePath);
      final remoteSession = remoteRoot.isEmpty || remoteRoot == '/'
          ? '/$folderName'
          : '$remoteRoot/$folderName';
      await _sftpEnsureDir(sftp, remoteSession);
      _ssh = ssh;
      _sftp = sftp;
      _remoteSession = remoteSession;
    } catch (_) {
      ssh.close();
      rethrow;
    }
  }

  Future<SftpFile> _ensureHandle(String name) async {
    final existing = _handles[name];
    if (existing != null) return existing;
    final shouldTruncate =
        (_offsets[name] ?? 0) == 0 && !_createdRemotely.contains(name);
    final mode = shouldTruncate
        ? (SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate)
        : (SftpFileOpenMode.create | SftpFileOpenMode.write);
    final handle = await _sftp!.open('$_remoteSession/$name', mode: mode);
    _createdRemotely.add(name);
    _handles[name] = handle;
    return handle;
  }

  Future<void> _resetConnection() async {
    for (final handle in _handles.values) {
      try {
        await handle.close();
      } catch (_) {}
    }
    _handles.clear();
    try {
      _sftp?.close();
    } catch (_) {}
    _sftp = null;
    try {
      _ssh?.close();
    } catch (_) {}
    _ssh = null;
  }

  @override
  Future<void> syncTick({required bool finalizing}) async {
    try {
      await _ensureConnected();
    } catch (_) {
      await _resetConnection();
      rethrow;
    }

    final fileErrors = <String>[];

    if (!_metaUploaded) {
      try {
        final meta = File(p.join(sessionPath, liveSyncMetaFile));
        if (await meta.exists()) {
          final bytes = Uint8List.fromList(await meta.readAsBytes());
          final remote = await _sftp!.open(
            '$_remoteSession/$liveSyncMetaFile',
            mode: SftpFileOpenMode.create |
                SftpFileOpenMode.write |
                SftpFileOpenMode.truncate,
          );
          try {
            if (bytes.isNotEmpty) {
              await remote.writeBytes(bytes);
            }
          } finally {
            await remote.close();
          }
          _metaUploaded = true;
        }
      } catch (e) {
        fileErrors.add('$liveSyncMetaFile: ${_compactError(e)}');
      }
    }

    for (final name in liveSyncGrowingFiles) {
      try {
        final file = File(p.join(sessionPath, name));
        if (!await file.exists()) continue;
        final handle = await _ensureHandle(name);
        final offset = _offsets[name] ?? 0;
        final slice = await readFileSlice(file, offset);
        if (slice.isEmpty) continue;
        await handle.writeBytes(slice, offset: offset);
        _offsets[name] = offset + slice.length;
      } catch (e) {
        final dead = _handles.remove(name);
        if (dead != null) {
          try {
            await dead.close();
          } catch (_) {}
        }
        fileErrors.add('$name: ${_compactError(e)}');
      }
    }

    if (fileErrors.isNotEmpty) {
      await _resetConnection();
      throw StateError(fileErrors.join('; '));
    }
  }

  @override
  Future<void> finalizeAndClose() async {
    Object? syncError;
    try {
      await syncTick(finalizing: true);
    } catch (e) {
      syncError = e;
    } finally {
      await _resetConnection();
    }
    if (syncError != null) {
      throw syncError;
    }
  }
}
