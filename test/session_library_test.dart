import 'dart:convert';
import 'dart:io';

import 'package:flutter_emotiv_logger/sessions/server_bookmark.dart';
import 'package:flutter_emotiv_logger/sessions/session_library.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('listSessions finds session_* with session.json', () async {
    final root = await Directory.systemTemp.createTemp('emotiv_sessions_');
    addTearDown(() => root.delete(recursive: true));

    final session = Directory('${root.path}/session_2026-01-01T00-00-00');
    await session.create();
    await File('${session.path}/session.json').writeAsString(
      const JsonEncoder().convert({
        'deviceName': 'EPOCX (TEST)',
        'startedAt': '2026-01-01T00:00:00.000Z',
      }),
    );
    await File('${session.path}/eeg.csv').writeAsString('wall_ms,mono_us\n');

    // Incomplete folder without session.json should be ignored.
    await Directory('${root.path}/session_incomplete').create();
    await Directory('${root.path}/other_dir').create();

    final listed = await SessionLibrary.listSessions(
      baseDirectoryOverride: root.path,
      activeSessionPath: session.path,
    );

    expect(listed, hasLength(1));
    expect(listed.single.deviceName, 'EPOCX (TEST)');
    expect(listed.single.folderName, 'session_2026-01-01T00-00-00');
    expect(listed.single.isActive, isTrue);
    expect(listed.single.totalBytes, greaterThan(0));
  });

  test('ServerBookmark JSON round-trip excludes password fields', () {
    const bookmark = ServerBookmark(
      id: 'abc',
      name: 'Lab NAS',
      protocol: TransferProtocol.smb,
      host: 'nas.local',
      port: 445,
      username: 'user',
      remotePath: 'emotiv',
      smbShare: 'data',
      domain: 'WORKGROUP',
      rememberPassword: true,
    );

    final encoded = ServerBookmark.encodeList([bookmark]);
    expect(encoded.contains('password'), isFalse);

    final decoded = ServerBookmark.decodeList(encoded);
    expect(decoded, hasLength(1));
    expect(decoded.single.id, 'abc');
    expect(decoded.single.protocol, TransferProtocol.smb);
    expect(decoded.single.smbShare, 'data');
    expect(decoded.single.rememberPassword, isTrue);
  });
}
