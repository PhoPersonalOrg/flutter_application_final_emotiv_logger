---
name: Auto-set Save Directory on Launch
overview: ""
todos:
  - id: persist-dir-settings
    content: Add saveDirectory field + SharedPreferences key to AppSettings and AppSettingsRepository
    status: completed
  - id: auto-set-on-load
    content: In _loadAppSettings(), resolve and apply directory (saved or app documents fallback) then call setCustomSaveDirectory
    status: completed
  - id: wire-save-on-apply
    content: Pass selectedDirectory into AppSettings.saveDirectory when user applies settings from FileSettingsScreen
    status: completed
---

# Auto-set Save Directory on Launch

On startup, `_selectedDirectory` is never set, so `_bleManager._customSaveDirectory` stays `null` until the user manually opens Settings and picks a folder. The fix persists the directory in `SharedPreferences` and restores (or defaults to the app documents dir) on launch.

## Changes

### 1. [`lib/settings/app_settings.dart`](lib/settings/app_settings.dart)

Add `saveDirectory` to `AppSettings` and `AppSettingsRepository`:

- New field `String? saveDirectory` on `AppSettings`
- `_saveDirectoryKey = 'settings.saveDirectory'` in `AppSettingsRepository`
- Read/write it in `load()` / `save()`

### 2. [`lib/main.dart`](lib/main.dart)

- Add `import 'package:path_provider/path_provider.dart';`
- In `_loadAppSettings()`: after loading settings, resolve the directory (`settings.saveDirectory` if persisted, else `getApplicationDocumentsDirectory().path`), then call `setState(() => _selectedDirectory = resolvedDir)` and `_bleManager.setCustomSaveDirectory(resolvedDir)`
- When the user saves from `FileSettingsScreen`, the chosen directory is already passed into `AppSettings.saveDirectory` before calling `_settingsRepository.save()`

## Result

The directory shown in the log (`/private/var/mobile/.../Documents`) is automatically applied on every cold start — no user interaction required.