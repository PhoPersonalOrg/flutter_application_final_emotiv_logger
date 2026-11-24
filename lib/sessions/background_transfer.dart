import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import 'dropbox_config.dart';
import 'server_bookmark.dart';
import 'session_transfer.dart';

typedef BackgroundTransferRunner = Future<BatchTransferReport> Function(
  TransferProgressCallback onProgress,
  bool Function() isCancelled,
);

/// One queued background session-transfer batch.
class BackgroundTransferJob {
  const BackgroundTransferJob({
    required this.destinationLabel,
    required this.sessionPaths,
    required this.run,
  });

  final String destinationLabel;
  final List<String> sessionPaths;
  final BackgroundTransferRunner run;
}

/// Immutable UI state for non-blocking background server transfers.
class BackgroundTransferState {
  const BackgroundTransferState({
    this.isRunning = false,
    this.activeDestination,
    this.activeSessionCount = 0,
    this.progress,
    this.queuedJobs = 0,
    this.lastReport,
  });

  final bool isRunning;
  final String? activeDestination;
  final int activeSessionCount;
  final TransferProgress? progress;
  final int queuedJobs;
  final BatchTransferReport? lastReport;

  bool get hasVisibleBanner => isRunning || lastReport != null;

  BackgroundTransferState copyWith({
    bool? isRunning,
    String? activeDestination,
    bool clearActiveDestination = false,
    int? activeSessionCount,
    TransferProgress? progress,
    bool clearProgress = false,
    int? queuedJobs,
    BatchTransferReport? lastReport,
    bool clearLastReport = false,
  }) {
    return BackgroundTransferState(
      isRunning: isRunning ?? this.isRunning,
      activeDestination: clearActiveDestination
          ? null
          : (activeDestination ?? this.activeDestination),
      activeSessionCount: activeSessionCount ?? this.activeSessionCount,
      progress: clearProgress ? null : (progress ?? this.progress),
      queuedJobs: queuedJobs ?? this.queuedJobs,
      lastReport: clearLastReport ? null : (lastReport ?? this.lastReport),
    );
  }
}

/// Runs manual `Sessions` tab transfers (Dropbox, SMB, SFTP) asynchronously in
/// the background so navigation and new BLE recordings are never blocked,
/// continuing across remaining files/sessions on error and always keeping local files.
class BackgroundTransferNotifier extends Notifier<BackgroundTransferState> {
  final List<BackgroundTransferJob> _queue = [];
  bool _processing = false;
  bool _cancelCurrent = false;

  @override
  BackgroundTransferState build() {
    return const BackgroundTransferState();
  }

  /// Enqueues an SFTP or SMB batch upload in the background.
  void enqueueBookmark({
    required ServerBookmark bookmark,
    required String password,
    required List<String> sessionPaths,
  }) {
    if (sessionPaths.isEmpty) return;
    final copy = List<String>.unmodifiable(sessionPaths);
    enqueueJob(
      BackgroundTransferJob(
        destinationLabel: '${bookmark.name} (${bookmark.protocol.label})',
        sessionPaths: copy,
        run: (onProgress, isCancelled) => SessionTransfer.uploadSessions(
          bookmark: bookmark,
          password: password,
          sessionPaths: copy,
          onProgress: onProgress,
          isCancelled: isCancelled,
        ),
      ),
    );
  }

  /// Enqueues a Dropbox App Folder batch upload in the background.
  void enqueueDropbox({
    required List<String> sessionPaths,
    required String remoteRoot,
  }) {
    if (sessionPaths.isEmpty) return;
    final copy = List<String>.unmodifiable(sessionPaths);
    final dropbox = ref.read(dropboxSyncProvider);
    enqueueJob(
      BackgroundTransferJob(
        destinationLabel: 'Dropbox',
        sessionPaths: copy,
        run: (onProgress, isCancelled) async {
          if (!DropboxConfig.isConfigured) {
            return BatchTransferReport(
              destinationLabel: 'Dropbox',
              totalSessions: copy.length,
              succeededSessions: const [],
              failures: const [
                TransferItemFailure(
                  sessionFolder: 'Dropbox',
                  error: 'Dropbox app key not configured (see README)',
                ),
              ],
            );
          }
          return dropbox.uploadSessions(
            copy,
            remoteRoot: remoteRoot,
            onProgress: onProgress,
            isCancelled: isCancelled,
          );
        },
      ),
    );
  }

  /// Enqueues an arbitrary [BackgroundTransferJob] and starts pumping asynchronously.
  void enqueueJob(BackgroundTransferJob job) {
    _queue.add(job);
    if (_processing) {
      state = state.copyWith(queuedJobs: _queue.length);
      return;
    }
    unawaited(_pump());
  }

  /// Cancels the currently running transfer and clears any queued jobs.
  void cancelActive() {
    _queue.clear();
    _cancelCurrent = true;
    if (state.isRunning) {
      state = state.copyWith(queuedJobs: 0);
    }
  }

  /// Clears the most recent completion/error banner.
  void dismissReport() {
    state = state.copyWith(clearLastReport: true);
  }

  Future<void> _pump() async {
    if (_processing) return;
    _processing = true;
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.removeAt(0);
        _cancelCurrent = false;
        state = BackgroundTransferState(
          isRunning: true,
          activeDestination: job.destinationLabel,
          activeSessionCount: job.sessionPaths.length,
          progress: null,
          queuedJobs: _queue.length,
          lastReport: state.lastReport,
        );

        BatchTransferReport report;
        try {
          report = await job.run(
            (p) {
              state = state.copyWith(
                progress: p,
                queuedJobs: _queue.length,
              );
            },
            () => _cancelCurrent,
          );
        } catch (e) {
          report = BatchTransferReport(
            destinationLabel: job.destinationLabel,
            totalSessions: job.sessionPaths.length,
            succeededSessions: const [],
            failures: [
              TransferItemFailure(
                sessionFolder: job.destinationLabel,
                error: '$e',
              ),
            ],
            cancelled: _cancelCurrent,
          );
        }

        state = BackgroundTransferState(
          isRunning: _queue.isNotEmpty,
          activeDestination: null,
          activeSessionCount: 0,
          progress: null,
          queuedJobs: _queue.length,
          lastReport: report,
        );
      }
    } finally {
      _processing = false;
    }
  }
}
