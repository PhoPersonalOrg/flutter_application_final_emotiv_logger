import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../acquisition/acquisition_session.dart';
import '../domain/acquisition_state.dart';
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
  final session = AcquisitionSession(
    initialSettings: ref.read(settingsProvider),
    dropboxSync: ref.read(dropboxSyncProvider),
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

/// Throttled latest EEG values for optional preview.
final uiEegPreviewProvider = StreamProvider<List<double>>((ref) async* {
  final session = ref.watch(acquisitionSessionProvider);
  await for (final _ in session.hub.uiAvailable) {
    final batch = session.hub.takeUiEeg(max: 1);
    if (batch.isNotEmpty) {
      yield batch.last.values;
    }
  }
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
      activeSessionPath: session.health.csvSessionPath,
    );
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}
