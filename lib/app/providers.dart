import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../acquisition/acquisition_session.dart';
import '../domain/acquisition_state.dart';
import '../plot/live_eeg_ring_buffer.dart';
import '../sessions/background_transfer.dart';
import '../sessions/bookmark_store.dart';
import '../sessions/dropbox_sync.dart';
import '../sessions/server_bookmark.dart';
import '../sessions/session_library.dart';
import 'settings.dart';

final settingsRepositoryProvider = Provider<AppSettingsRepository>((ref) {
  return AppSettingsRepository();
});

final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    Future.microtask(_load);
    return const AppSettings();
  }

  Future<void> _load() async {
    state = await ref.read(settingsRepositoryProvider).load();
  }

  Future<void> save(AppSettings next) async {
    state = next;
    await ref.read(settingsRepositoryProvider).save(next);
  }

  /// Apply settings already persisted elsewhere (e.g. preferred device).
  void applyLocal(AppSettings next) {
    state = next;
  }
}

final dropboxSyncProvider = Provider<DropboxSync>((ref) {
  return DropboxSync();
});

final dropboxLinkedProvider = FutureProvider<bool>((ref) async {
  return ref.watch(dropboxSyncProvider).isLinked();
});

final acquisitionSessionProvider = Provider<AcquisitionSession>((ref) {
  final bookmarks = ref.read(bookmarkRepositoryProvider);
  final session = AcquisitionSession(
    initialSettings: ref.read(settingsProvider),
    dropboxSync: ref.read(dropboxSyncProvider),
    loadBookmarks: bookmarks.load,
    readPassword: bookmarks.readPassword,
    persistSettings: (settings) async {
      await ref.read(settingsRepositoryProvider).save(settings);
      ref.read(settingsProvider.notifier).applyLocal(settings);
    },
  );
  ref.listen<AppSettings>(settingsProvider, (prev, next) {
    unawaited(session.updateSettings(next));
  });
  ref.onDispose(() {
    unawaited(session.dispose());
  });
  return session;
});

final acquisitionStateProvider = StreamProvider<AcquisitionState>((ref) {
  final session = ref.watch(acquisitionSessionProvider);
  // Seed with current state so UI is not stuck loading forever.
  return Stream<AcquisitionState>.multi((controller) {
    controller.add(session.state);
    final sub = session.stateStream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });
});

/// Drains `SampleHub.takeUiEeg` into a preallocated [LiveEegRingBuffer] and
/// emits downsampled [LiveEegPlotSnapshot] frames coalesced to <=20 Hz.
final liveEegPlotSnapshotProvider =
    StreamProvider<LiveEegPlotSnapshot>((ref) {
  final session = ref.watch(acquisitionSessionProvider);
  const frameInterval = Duration(milliseconds: 50); // 20 Hz max

  return Stream<LiveEegPlotSnapshot>.multi((controller) {
    final ring = LiveEegRingBuffer();
    Timer? flushTimer;
    var dirty = false;

    void emitSnapshot() {
      if (controller.isClosed) return;
      dirty = false;
      controller.add(ring.snapshot());
    }

    void scheduleFlush() {
      dirty = true;
      if (flushTimer != null && flushTimer!.isActive) return;
      flushTimer = Timer(frameInterval, () {
        flushTimer = null;
        if (dirty) {
          emitSnapshot();
        }
      });
    }

    void drainAvailable() {
      while (true) {
        final batch = session.hub.takeUiEeg(max: 64);
        if (batch.isEmpty) break;
        ring.pushAll(batch);
        scheduleFlush();
      }
    }

    // Seed initial snapshot so consumers render immediately without spinner flicker.
    drainAvailable();
    controller.add(ring.snapshot());

    final uiSub = session.hub.uiAvailable.listen(
      (_) => drainAvailable(),
      onError: controller.addError,
      onDone: controller.close,
    );

    final stateSub = session.stateStream.listen((state) {
      if (state is AcquisitionIdle ||
          state is AcquisitionScanning ||
          state is AcquisitionConnecting) {
        if (ring.length > 0 || ring.cqHistoryLength > 0) {
          ring.clear();
          flushTimer?.cancel();
          flushTimer = null;
          emitSnapshot();
        }
      }
    });

    controller.onCancel = () async {
      flushTimer?.cancel();
      flushTimer = null;
      await uiSub.cancel();
      await stateSub.cancel();
    };
  });
});

/// Emits the latest sample wallClock when fresh EEG data reaches the UI plot path.
final uiEegActivityProvider = Provider<AsyncValue<DateTime?>>((ref) {
  return ref
      .watch(liveEegPlotSnapshotProvider)
      .whenData((snap) => snap.lastWallClock);
});

final bookmarkRepositoryProvider = Provider<BookmarkStore>((ref) {
  return BookmarkStore();
});

final bookmarkStoreProvider =
    AsyncNotifierProvider<BookmarkStoreNotifier, BookmarkStoreState>(
  BookmarkStoreNotifier.new,
);

class BookmarkStoreNotifier extends AsyncNotifier<BookmarkStoreState> {
  @override
  Future<BookmarkStoreState> build() {
    return ref.read(bookmarkRepositoryProvider).load();
  }

  Future<void> upsert(ServerBookmark bookmark, {String? password}) async {
    final store = ref.read(bookmarkRepositoryProvider);
    final current = state.value ?? await store.load();
    await store.upsert(bookmark, password: password, current: current);
    state = AsyncData(await store.load());
  }

  Future<void> delete(String id) async {
    final store = ref.read(bookmarkRepositoryProvider);
    final current = state.value ?? await store.load();
    state = AsyncData(await store.delete(id, current: current));
  }

  Future<void> setLastUsed(String id) async {
    final store = ref.read(bookmarkRepositoryProvider);
    final current = state.value ?? await store.load();
    await store.setLastUsed(id, current);
    state = AsyncData(await store.load());
  }

  Future<String?> readPassword(String bookmarkId) {
    return ref.read(bookmarkRepositoryProvider).readPassword(bookmarkId);
  }
}

final sessionListProvider =
    AsyncNotifierProvider<SessionListNotifier, List<SessionRecord>>(
  SessionListNotifier.new,
);

class SessionListNotifier extends AsyncNotifier<List<SessionRecord>> {
  @override
  Future<List<SessionRecord>> build() async {
    final settings = ref.watch(settingsProvider);
    // Rebuild when acquisition state changes so the active session flag updates.
    ref.watch(acquisitionStateProvider);
    final session = ref.read(acquisitionSessionProvider);
    return SessionLibrary.listSessions(
      saveDirectory: settings.saveDirectory,
      // Only mark active while CSV is open / flushing — not after Idle Stop.
      activeSessionPath: session.state.activeCsvSessionPath,
    );
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final backgroundTransferProvider =
    NotifierProvider<BackgroundTransferNotifier, BackgroundTransferState>(
  BackgroundTransferNotifier.new,
);
