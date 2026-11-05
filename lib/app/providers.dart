import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../acquisition/acquisition_session.dart';
import '../domain/acquisition_state.dart';
import 'settings.dart';

final settingsRepositoryProvider = Provider<AppSettingsRepository>((ref) {
  return AppSettingsRepository();
});

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  return SettingsNotifier(ref.watch(settingsRepositoryProvider));
});

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier(this._repo) : super(const AppSettings()) {
    _load();
  }

  final AppSettingsRepository _repo;

  Future<void> _load() async {
    state = await _repo.load();
  }

  Future<void> save(AppSettings next) async {
    state = next;
    await _repo.save(next);
  }
}

final acquisitionSessionProvider = Provider<AcquisitionSession>((ref) {
  final session = AcquisitionSession(
    initialSettings: ref.read(settingsProvider),
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
