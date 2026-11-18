import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_emotiv_logger/app/settings.dart';
import 'package:flutter_emotiv_logger/sessions/live_session_sync.dart';
import 'package:flutter_emotiv_logger/sessions/server_bookmark.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  test('formatLiveSyncStatus joins channels and errors', () {
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

  test('ServerBookmark liveSync defaults true in JSON', () {
    const bookmark = ServerBookmark(
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
    expect(bookmark.liveSync, isTrue);
    final decoded = ServerBookmark.fromJson(bookmark.toJson());
    expect(decoded.liveSync, isTrue);

    final legacy = ServerBookmark.fromJson({
      'id': 'old',
      'name': 'Old',
      'protocol': 'smb',
      'host': 'h',
      'port': 445,
      'username': 'u',
      'remotePath': '',
      'smbShare': 's',
      'rememberPassword': true,
    });
    expect(legacy.liveSync, isTrue);
  });
}
