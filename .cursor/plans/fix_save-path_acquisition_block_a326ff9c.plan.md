---
name: Fix save-path acquisition block
overview: Save-path permission errors currently abort Preparing and prevent EEG entirely. Make CSV path failures degrade/fallback so BLE acquisition and LSL continue, defaulting to the always-writable app documents directory.
todos:
  - id: csv-fallback
    content: "CsvSink: probe custom path, fall back to app documents, only fail if both unwritable"
    status: completed
  - id: prepare-decouple
    content: "AcquisitionSession: CSV path failure must not abort Preparing / Streaming"
    status: completed
  - id: settings-clear-path
    content: "Settings: Clear save directory button + note about app-documents default"
    status: completed
  - id: health-message
    content: Expose CSV fallback/denied message on AcquisitionHealth / home UI
    status: completed
isProject: false
---

# Fix save-path blocking EEG acquisition

## Will EEG work today?

**Not if the configured save path is unwritable.** In [`lib/acquisition/acquisition_session.dart`](lib/acquisition/acquisition_session.dart), `_prepareAndStream` awaits CSV setup before arming BLE notifies:

```216:257:lib/acquisition/acquisition_session.dart
final sessionPath = await _csv.startSession(...);
// ... LSL, network, then _armNotifications ...
} catch (e) {
  await _orderedTeardown(disconnectBle: true);
  _emit(AcquisitionFailed(message: 'Prepare failed: $e', ...));
}
```

Any `PathAccessException` / permission error from [`CsvSink.startSession`](lib/sinks/csv_sink.dart) fails the whole session. LSL never starts; no EEG packets are accepted.

If `saveDirectory` is **null** (Settings shows “(app documents)”), CSV uses `getApplicationDocumentsDirectory()`, which does not need the file-picker permission and should work on iOS/Android. A leftover custom path from Settings (or an old prefs value) is the usual failure mode—especially iOS security-scoped picker paths that are not durable across relaunches.

## Fix (concrete)

1. **CSV resilient start** in [`lib/sinks/csv_sink.dart`](lib/sinks/csv_sink.dart)
   - Try custom `saveDirectory` with a quick writable probe (create session dir + write `session.json`).
   - On failure, fall back to app documents and succeed.
   - Return both `sessionPath` and whether fallback was used (or throw only if *both* fail).

2. **Do not fail Preparing on CSV path issues** in [`lib/acquisition/acquisition_session.dart`](lib/acquisition/acquisition_session.dart)
   - Treat CSV like LSL: path/fallback problems update health (`csvSessionPath`, message) and continue to `_armNotifications`.
   - Only fail Preparing for hard acquisition errors (identity parse, missing EEG characteristic, connect/discover failure).

3. **Settings UX** in [`lib/app/settings_page.dart`](lib/app/settings_page.dart)
   - Add **Clear / use app documents** so a bad path can be wiped (`copyWith(clearSaveDirectory: true)` already exists on [`AppSettings`](lib/app/settings.dart)).
   - Show a short note that custom folders can fail on iOS/Android and app documents is the reliable default.

4. **Health visibility**
   - Surface “CSV using app documents (custom path denied)” in health/UI so permission issues are obvious without killing Streaming.

## After the fix

EEG acquisition works as long as BLE connect + decrypt succeed, even when the custom save folder is denied. CSV still lands somewhere writable; LSL remains independent.

**Immediate workaround (no code):** Settings → clear custom save directory / leave “(app documents)” → Apply → connect again.