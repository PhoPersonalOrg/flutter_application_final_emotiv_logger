import 'package:flutter_emotiv_logger/sessions/session_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldSkipIdenticalRemoteFile', () {
    test('skips when remote size equals local size', () {
      expect(
        shouldSkipIdenticalRemoteFile(localBytes: 1024, remoteBytes: 1024),
        isTrue,
      );
    });

    test('does not skip when remote is missing', () {
      expect(
        shouldSkipIdenticalRemoteFile(localBytes: 1024, remoteBytes: null),
        isFalse,
      );
    });

    test('does not skip when remote size differs', () {
      expect(
        shouldSkipIdenticalRemoteFile(localBytes: 1024, remoteBytes: 512),
        isFalse,
      );
      expect(
        shouldSkipIdenticalRemoteFile(localBytes: 0, remoteBytes: 1),
        isFalse,
      );
    });

    test('skips zero-byte match', () {
      expect(
        shouldSkipIdenticalRemoteFile(localBytes: 0, remoteBytes: 0),
        isTrue,
      );
    });
  });

  group('TransferProgress.skipped', () {
    test('defaults to false', () {
      const p = TransferProgress(
        sessionFolder: 'session_x',
        fileName: 'eeg.csv',
        fileIndex: 1,
        fileCount: 1,
        bytesSent: 0,
        bytesTotal: 10,
      );
      expect(p.skipped, isFalse);
      expect(p.done, isFalse);
    });

    test('reports skipped files as complete', () {
      const p = TransferProgress(
        sessionFolder: 'session_x',
        fileName: 'eeg.csv',
        fileIndex: 1,
        fileCount: 2,
        bytesSent: 10,
        bytesTotal: 10,
        skipped: true,
      );
      expect(p.skipped, isTrue);
      expect(p.fraction, 1.0);
    });
  });
}
