import 'dart:async';
import 'dart:io';

import 'package:flutter_emotiv_logger/app/providers.dart';
import 'package:flutter_emotiv_logger/sessions/background_transfer.dart';
import 'package:flutter_emotiv_logger/sessions/dropbox_sync.dart';
import 'package:flutter_emotiv_logger/sessions/session_transfer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeBatchAdapter implements BatchRemoteAdapter {
  _FakeBatchAdapter({
    this.failingSessionDirs = const {},
    this.failingFiles = const {},
  });

  final Set<String> failingSessionDirs;
  final Set<String> failingFiles; // "$folderName/$fileName"

  final Map<String, List<int>> uploaded = {};
  int resetCount = 0;
  bool closed = false;

  @override
  Future<void> ensureSessionDir(String folderName) async {
    if (failingSessionDirs.contains(folderName)) {
      throw SocketException('mkdir failed for $folderName');
    }
  }

  @override
  Future<Map<String, int>> remoteFileSizes(String folderName) async {
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
    final key = '$folderName/$fileName';
    if (failingFiles.contains(key)) {
      throw SocketException('broken pipe on $key');
    }
    final bytes = await localFile.readAsBytes();
    onFileProgress(bytes.length, length);
    uploaded[key] = bytes;
  }

  @override
  Future<void> resetConnection() async {
    resetCount++;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

Future<Directory> _makeSession(
  Directory root,
  String name,
  Map<String, String> files,
) async {
  final dir = Directory(p.join(root.path, name));
  await dir.create(recursive: true);
  for (final entry in files.entries) {
    await File(p.join(dir.path, entry.key)).writeAsString(entry.value);
  }
  return dir;
}

void main() {
  test(
    'SessionTransfer.runResilientBatch continues across file and session errors '
    'and always keeps all local files intact',
    () async {
      final root = await Directory.systemTemp.createTemp('batch_resilient_');
      addTearDown(() => root.delete(recursive: true));

      final s1 = await _makeSession(root, 'session_1', {
        'eeg.csv': 's1_eeg',
        'motion.csv': 's1_motion',
        'session.json': '{"s":1}',
      });
      final s2 = await _makeSession(root, 'session_2', {
        'eeg.csv': 's2_eeg',
        'session.json': '{"s":2}',
      });
      final s3 = await _makeSession(root, 'session_3', {
        'eeg.csv': 's3_eeg',
        'raw.csv': 's3_raw',
        'session.json': '{"s":3}',
      });

      final adapter = _FakeBatchAdapter(
        failingFiles: {'session_1/eeg.csv'},
        failingSessionDirs: {'session_2'},
      );

      final report = await SessionTransfer.runResilientBatch(
        destinationLabel: 'LabSFTP',
        sessionPaths: [s1.path, s2.path, s3.path],
        adapter: adapter,
      );

      // Session 3 succeeded despite session 1 file error and session 2 dir error.
      expect(report.totalSessions, 3);
      expect(report.succeededSessions, ['session_3']);
      expect(report.failures.length, 2);
      expect(
        report.failures.map((f) => f.label),
        containsAll([
          contains('session_1/eeg.csv'),
          contains('session_2:'),
        ]),
      );

      // Remaining files in session_1 AND all files in session_3 still uploaded!
      expect(
        adapter.uploaded.keys,
        containsAll([
          'session_1/motion.csv',
          'session_1/session.json',
          'session_3/eeg.csv',
          'session_3/raw.csv',
          'session_3/session.json',
        ]),
      );
      expect(adapter.resetCount, 2);
      expect(adapter.closed, isTrue);

      // Every local file in succeeded AND failed sessions is preserved intact.
      expect(await File(p.join(s1.path, 'eeg.csv')).readAsString(), 's1_eeg');
      expect(
        await File(p.join(s1.path, 'motion.csv')).readAsString(),
        's1_motion',
      );
      expect(await File(p.join(s2.path, 'eeg.csv')).readAsString(), 's2_eeg');
      expect(await File(p.join(s3.path, 'eeg.csv')).readAsString(), 's3_eeg');
      expect(await File(p.join(s3.path, 'raw.csv')).readAsString(), 's3_raw');
    },
  );

  test(
    'DropboxSync.uploadSessions continues after a file error and preserves local files',
    () async {
      final root = await Directory.systemTemp.createTemp('dropbox_resilient_');
      addTearDown(() => root.delete(recursive: true));

      final s1 = await _makeSession(root, 'session_a', {
        'eeg.csv': 'a_eeg',
        'session.json': '{"a":1}',
      });
      final s2 = await _makeSession(root, 'session_b', {
        'eeg.csv': 'b_eeg',
        'session.json': '{"b":2}',
      });

      final uploadedRemote = <String>[];
      final dropbox = DropboxSync(
        ensureReadyOverride: () async {},
        rawUpload: (localPath, remotePath, onProgress) async {
          if (remotePath.endsWith('/session_a/eeg.csv')) {
            throw StateError('503 service unavailable');
          }
          final len = await File(localPath).length();
          onProgress(len, len);
          uploadedRemote.add(remotePath);
        },
      );

      final report = await dropbox.uploadSessions(
        [s1.path, s2.path],
        remoteRoot: 'EmotivSessions',
      );

      expect(report.totalSessions, 2);
      expect(report.succeededSessions, ['session_b']);
      expect(report.failures.length, 1);
      expect(report.failures.single.sessionFolder, 'session_a');
      expect(report.failures.single.fileName, 'eeg.csv');
      expect(
        uploadedRemote,
        containsAll([
          '/EmotivSessions/session_a/session.json',
          '/EmotivSessions/session_b/eeg.csv',
          '/EmotivSessions/session_b/session.json',
        ]),
      );

      // Local files remain untouched.
      expect(await File(p.join(s1.path, 'eeg.csv')).readAsString(), 'a_eeg');
      expect(await File(p.join(s2.path, 'eeg.csv')).readAsString(), 'b_eeg');
    },
  );

  test(
    'BackgroundTransferNotifier runs queued jobs asynchronously without blocking caller',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(backgroundTransferProvider.notifier);
      final gate1 = Completer<void>();
      final gate2 = Completer<void>();

      // Enqueue two jobs synchronously — caller returns immediately.
      notifier.enqueueJob(
        BackgroundTransferJob(
          destinationLabel: 'NAS (SMB)',
          sessionPaths: const ['/tmp/s1'],
          run: (onProgress, isCancelled) async {
            onProgress(
              const TransferProgress(
                sessionFolder: 's1',
                fileName: 'eeg.csv',
                fileIndex: 1,
                fileCount: 1,
                bytesSent: 50,
                bytesTotal: 100,
              ),
            );
            await gate1.future;
            return const BatchTransferReport(
              destinationLabel: 'NAS (SMB)',
              totalSessions: 1,
              succeededSessions: ['s1'],
            );
          },
        ),
      );
      notifier.enqueueJob(
        BackgroundTransferJob(
          destinationLabel: 'Lab (SFTP)',
          sessionPaths: const ['/tmp/s2'],
          run: (onProgress, isCancelled) async {
            await gate2.future;
            return const BatchTransferReport(
              destinationLabel: 'Lab (SFTP)',
              totalSessions: 1,
              succeededSessions: [],
              failures: [
                TransferItemFailure(sessionFolder: 's2', error: 'timeout'),
              ],
            );
          },
        ),
      );

      await Future<void>.delayed(Duration.zero);
      var state = container.read(backgroundTransferProvider);
      expect(state.isRunning, isTrue);
      expect(state.activeDestination, 'NAS (SMB)');
      expect(state.queuedJobs, 1);
      expect(state.progress?.fraction, 0.5);

      gate1.complete();
      await Future<void>.delayed(Duration.zero);
      state = container.read(backgroundTransferProvider);
      expect(state.isRunning, isTrue);
      expect(state.activeDestination, 'Lab (SFTP)');
      expect(state.queuedJobs, 0);
      expect(state.lastReport?.destinationLabel, 'NAS (SMB)');
      expect(state.lastReport?.isFullSuccess, isTrue);

      gate2.complete();
      await Future<void>.delayed(Duration.zero);
      state = container.read(backgroundTransferProvider);
      expect(state.isRunning, isFalse);
      expect(state.lastReport?.destinationLabel, 'Lab (SFTP)');
      expect(state.lastReport?.hasFailures, isTrue);
      expect(state.lastReport?.summaryLine(), contains('local files kept'));

      notifier.dismissReport();
      expect(container.read(backgroundTransferProvider).lastReport, isNull);
    },
  );
}
