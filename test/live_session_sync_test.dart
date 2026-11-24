import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_emotiv_logger/app/settings.dart';
import 'package:flutter_emotiv_logger/sessions/live_session_sync.dart';
import 'package:flutter_emotiv_logger/sessions/server_bookmark.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class _FakeIncrementalChannel implements LiveSyncChannel {
  _FakeIncrementalChannel({
    required this.shortName,
    required this.activeLabel,
    required this.committedLabel,
    required this.sessionPath,
    this.shouldFail = false,
    this.finalizeBlocker,
  });

  @override
  final String shortName;
  @override
  final String activeLabel;
  @override
  final String committedLabel;

  final String sessionPath;
  bool shouldFail;
  Completer<void>? finalizeBlocker;

  final Map<String, BytesBuilder> remoteFiles = {};
  final Map<String, int> offsets = {};
  bool finalized = false;
  int tickCalls = 0;

  @override
  Future<void> syncTick({required bool finalizing}) async {
    tickCalls++;
    if (shouldFail) {
      throw const SocketException('unreachable host');
    }
    for (final name in [liveSyncMetaFile, ...liveSyncGrowingFiles]) {
      final file = File(p.join(sessionPath, name));
      if (!await file.exists()) continue;
      final offset = offsets[name] ?? 0;
      final slice = await readFileSlice(file, offset);
      if (slice.isEmpty) continue;
      remoteFiles.putIfAbsent(name, BytesBuilder.new).add(slice);
      offsets[name] = offset + slice.length;
    }
  }

  @override
  Future<void> finalizeAndClose() async {
    if (finalizeBlocker != null) {
      await finalizeBlocker!.future;
    }
    await syncTick(finalizing: true);
    finalized = true;
  }

  String remoteString(String name) =>
      String.fromCharCodes(remoteFiles[name]?.toBytes() ?? const []);
}

void main() {
  test('readFileSlice returns only new bytes', () async {
    final dir = await Directory.systemTemp.createTemp('live_sync_slice_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/eeg.csv');
    await file.writeAsString('abc');
    expect(await readFileSlice(file, 0), Uint8List.fromList('abc'.codeUnits));
    expect(await readFileSlice(file, 3), isEmpty);
    await file.writeAsString('abcdef', flush: true);
    expect(await readFileSlice(file, 3), Uint8List.fromList('def'.codeUnits));
  });

  test('formatLiveSyncStatus joins channels and errors side-by-side', () {
    expect(formatLiveSyncStatus(), 'Sync: idle');
    expect(
      formatLiveSyncStatus(
        dropbox: 'Dropbox live (commits on Stop)',
        smb: const ['SMB Lab'],
      ),
      'Sync: Dropbox live (commits on Stop) · SMB Lab',
    );
    expect(
      formatLiveSyncStatus(error: 'Dropbox: timeout'),
      'Sync: Dropbox: timeout',
    );
    expect(
      formatLiveSyncStatus(
        dropbox: 'Dropbox live (commits on Stop)',
        sftp: const ['SFTP Server'],
        channelErrors: const ['SMB NAS (err: timeout)'],
      ),
      'Sync: Dropbox live (commits on Stop) · SFTP Server · SMB NAS (err: timeout)',
    );
  });

  test('shouldSkipLiveSyncTick when idle or in flight', () {
    expect(
      shouldSkipLiveSyncTick(running: false, tickInFlight: false),
      isTrue,
    );
    expect(
      shouldSkipLiveSyncTick(running: true, tickInFlight: true),
      isTrue,
    );
    expect(
      shouldSkipLiveSyncTick(running: true, tickInFlight: false),
      isFalse,
    );
  });

  test('LiveSessionSync start with no destinations stays idle', () async {
    final sync = LiveSessionSync(
      loadBookmarks: () async => const BookmarkStoreState(),
      readPassword: (_) async => null,
      tickInterval: const Duration(hours: 1),
    );
    addTearDown(() => sync.dispose());

    final dir = await Directory.systemTemp.createTemp('live_sync_idle_');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/session.json').writeAsString('{}');

    await sync.start(
      sessionPath: dir.path,
      settings: const AppSettings(dropboxLiveSync: false),
    );
    expect(sync.isRunning, isFalse);
  });

  test(
    'SFTP + SMB + Dropbox run in parallel; failing server does not block others, '
    'catches up from offset 0 on recovery, and preserves local CSV files',
    () async {
      final dir = await Directory.systemTemp.createTemp('live_sync_resilient_');
      addTearDown(() => dir.delete(recursive: true));
      final metaFile = File('${dir.path}/session.json');
      final eegFile = File('${dir.path}/eeg.csv');
      await metaFile.writeAsString('{"id":1}');
      await eegFile.writeAsString('row1\n', flush: true);

      var now = DateTime.utc(2026, 11, 24, 10, 0, 0);
      final statuses = <String?>[];
      final createdChannels = <String, _FakeIncrementalChannel>{};

      const smbBookmark = ServerBookmark(
        id: 'smb1',
        name: 'NAS',
        protocol: TransferProtocol.smb,
        host: 'nas.local',
        port: 445,
        username: 'u',
        remotePath: 'emotiv',
        smbShare: 'data',
        rememberPassword: true,
        liveSync: true,
      );
      const sftpBookmark = ServerBookmark(
        id: 'sftp1',
        name: 'LabSSH',
        protocol: TransferProtocol.sftp,
        host: 'lab.local',
        port: 22,
        username: 'researcher',
        remotePath: '/data/emotiv',
        rememberPassword: true,
        liveSync: true,
      );

      final sync = LiveSessionSync(
        loadBookmarks: () async => const BookmarkStoreState(
          bookmarks: [smbBookmark, sftpBookmark],
        ),
        readPassword: (_) async => 'secret',
        isDropboxLinked: () async => true,
        tickInterval: const Duration(milliseconds: 25),
        baseBackoff: const Duration(seconds: 5),
        maxBackoff: const Duration(seconds: 30),
        clock: () => now,
        onStatus: statuses.add,
        dropboxChannelBuilder: (sessionPath, folderName, remoteRoot) {
          final ch = _FakeIncrementalChannel(
            shortName: 'Dropbox',
            activeLabel: 'Dropbox live (commits on Stop)',
            committedLabel: 'Dropbox committed',
            sessionPath: sessionPath,
          );
          createdChannels['dropbox'] = ch;
          return ch;
        },
        bookmarkChannelBuilder: (b, pw, sessionPath, folderName) {
          final ch = _FakeIncrementalChannel(
            shortName: '${b.protocol.label} ${b.name}',
            activeLabel: '${b.protocol.label} ${b.name}',
            committedLabel: '${b.protocol.label} ${b.name} ok',
            sessionPath: sessionPath,
            // SMB starts offline at t = 0; SFTP and Dropbox are online!
            shouldFail: b.protocol == TransferProtocol.smb,
          );
          createdChannels[b.id] = ch;
          return ch;
        },
      );
      addTearDown(() => sync.dispose());

      await sync.start(
        sessionPath: dir.path,
        settings: const AppSettings(dropboxLiveSync: true),
      );
      // Let initial tick settle.
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // Both SFTP and SMB bookmarks plus Dropbox were registered.
      expect(createdChannels.keys, containsAll(['dropbox', 'smb1', 'sftp1']));
      // Healthy Dropbox and SFTP received row1 despite SMB failing at t = 0.
      expect(createdChannels['dropbox']!.remoteString('eeg.csv'), 'row1\n');
      expect(createdChannels['sftp1']!.remoteString('eeg.csv'), 'row1\n');
      expect(createdChannels['smb1']!.remoteString('eeg.csv'), isEmpty);
      expect(statuses.last, contains('Dropbox live'));
      expect(statuses.last, contains('SFTP LabSSH'));
      expect(statuses.last, contains('SMB NAS (err:'));

      // Append more local data and bring SMB back online after backoff window.
      await eegFile.writeAsString('row1\nrow2\n', flush: true);
      createdChannels['smb1']!.shouldFail = false;
      now = now.add(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // SMB caught up from byte offset 0 without losing row1!
      expect(
        createdChannels['smb1']!.remoteString('eeg.csv'),
        'row1\nrow2\n',
      );
      expect(
        createdChannels['sftp1']!.remoteString('eeg.csv'),
        'row1\nrow2\n',
      );

      // Final append right before Stop.
      await eegFile.writeAsString('row1\nrow2\nrow3\n', flush: true);
      await sync.stop();

      for (final ch in createdChannels.values) {
        expect(ch.finalized, isTrue);
        expect(ch.remoteString('eeg.csv'), 'row1\nrow2\nrow3\n');
        expect(ch.remoteString('session.json'), '{"id":1}');
      }

      // Local files MUST remain completely intact on disk after successful upload.
      expect(await eegFile.exists(), isTrue);
      expect(await eegFile.readAsString(), 'row1\nrow2\nrow3\n');
      expect(await metaFile.exists(), isTrue);
    },
  );

  test(
    'detaching a slow finalizing session never blocks stop() or starting a new session',
    () async {
      final dir1 = await Directory.systemTemp.createTemp('live_sync_s1_');
      final dir2 = await Directory.systemTemp.createTemp('live_sync_s2_');
      addTearDown(() => dir1.delete(recursive: true));
      addTearDown(() => dir2.delete(recursive: true));
      await File('${dir1.path}/eeg.csv').writeAsString('s1_data\n');
      await File('${dir2.path}/eeg.csv').writeAsString('s2_data\n');

      final s1Blocker = Completer<void>();
      final channelsBySession = <String, _FakeIncrementalChannel>{};

      const sftpBookmark = ServerBookmark(
        id: 'sftp1',
        name: 'LabSSH',
        protocol: TransferProtocol.sftp,
        host: 'lab.local',
        port: 22,
        username: 'u',
        remotePath: '/emotiv',
        rememberPassword: true,
        liveSync: true,
      );

      final sync = LiveSessionSync(
        loadBookmarks: () async => const BookmarkStoreState(
          bookmarks: [sftpBookmark],
        ),
        readPassword: (_) async => 'pw',
        tickInterval: const Duration(hours: 1),
        bookmarkChannelBuilder: (b, pw, sessionPath, folderName) {
          final ch = _FakeIncrementalChannel(
            shortName: 'SFTP ${b.name}',
            activeLabel: 'SFTP ${b.name}',
            committedLabel: 'SFTP ${b.name} ok',
            sessionPath: sessionPath,
            finalizeBlocker: sessionPath == dir1.path ? s1Blocker : null,
          );
          channelsBySession[sessionPath] = ch;
          return ch;
        },
      );
      addTearDown(() => sync.dispose());

      await sync.start(
        sessionPath: dir1.path,
        settings: const AppSettings(dropboxLiveSync: false),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(sync.isRunning, isTrue);

      // Fire-and-forget stop (same as AcquisitionSession._orderedTeardown).
      final stop1Future = sync.stop();
      // Active run detaches synchronously even while session 1 finalize hangs!
      expect(sync.isRunning, isFalse);
      expect(sync.finalizingCount, 1);

      // Starting session 2 completes immediately without waiting on session 1!
      await sync.start(
        sessionPath: dir2.path,
        settings: const AppSettings(dropboxLiveSync: false),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(sync.isRunning, isTrue);
      expect(channelsBySession[dir2.path]!.remoteString('eeg.csv'), 's2_data\n');

      // Release session 1's blocked remote finalize and verify both finish cleanly.
      s1Blocker.complete();
      await stop1Future;
      await sync.stop();

      expect(channelsBySession[dir1.path]!.finalized, isTrue);
      expect(channelsBySession[dir2.path]!.finalized, isTrue);
      expect(await File('${dir1.path}/eeg.csv').exists(), isTrue);
      expect(await File('${dir2.path}/eeg.csv').exists(), isTrue);
    },
  );

  test('dropboxLiveSync defaults true and migrates auto-upload key', () async {
    SharedPreferences.setMockInitialValues({});
    final empty = await SharedPreferences.getInstance();
    expect(AppSettingsRepository.resolveDropboxLiveSync(empty), isTrue);

    SharedPreferences.setMockInitialValues({
      'acq.v1.dropboxAutoUpload': false,
    });
    final legacy = await SharedPreferences.getInstance();
    expect(AppSettingsRepository.resolveDropboxLiveSync(legacy), isFalse);

    SharedPreferences.setMockInitialValues({
      'acq.v1.dropboxAutoUpload': false,
      'acq.v1.dropboxLiveSync': true,
    });
    final migrated = await SharedPreferences.getInstance();
    expect(AppSettingsRepository.resolveDropboxLiveSync(migrated), isTrue);
  });

  test('ServerBookmark liveSync defaults true in JSON for both SMB and SFTP', () {
    const smb = ServerBookmark(
      id: 'smb1',
      name: 'NAS',
      protocol: TransferProtocol.smb,
      host: 'nas.local',
      port: 445,
      username: 'u',
      remotePath: 'emotiv',
      smbShare: 'data',
      rememberPassword: true,
    );
    expect(smb.liveSync, isTrue);
    expect(ServerBookmark.fromJson(smb.toJson()).liveSync, isTrue);

    const sftp = ServerBookmark(
      id: 'sftp1',
      name: 'SSH',
      protocol: TransferProtocol.sftp,
      host: 'ssh.local',
      port: 22,
      username: 'u',
      remotePath: '/emotiv',
      rememberPassword: true,
    );
    expect(sftp.liveSync, isTrue);
    expect(ServerBookmark.fromJson(sftp.toJson()).liveSync, isTrue);
  });
}
