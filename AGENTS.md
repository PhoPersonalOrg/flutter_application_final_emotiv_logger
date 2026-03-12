<!-- OPENSPEC:START -->
# OpenSpec Instructions

These instructions are for AI assistants working in this project.

Always open `@/openspec/AGENTS.md` when the request:
- Mentions planning or proposals (words like proposal, spec, change, plan)
- Introduces new capabilities, breaking changes, architecture shifts, or big performance/security work
- Sounds ambiguous and you need the authoritative spec before coding

Use `@/openspec/AGENTS.md` to learn:
- How to create and apply change proposals
- Spec format and conventions
- Project structure and guidelines

Keep this managed block so 'openspec update' can refresh the instructions.

<!-- OPENSPEC:END -->

## Cursor Cloud specific instructions

### Project overview

This is a **Flutter desktop/mobile app** (`flutter_emotiv_logger`) that connects to Emotiv EEG headsets via BLE, decrypts data, and streams via LSL or network. A companion **Python test receiver** (`EXTERNAL/SCRIPTS/test_reciever.py`) is also included.

### Flutter (primary service)

- **SDK**: Flutter 3.41.4+ (Dart 3.11+), installed at `/opt/flutter`. The `.fvmrc` says 3.22.3 but is outdated; `pubspec.lock` requires `flutter >= 3.38.4`.
- **Lint**: `flutter analyze` — produces info/warning level issues (mostly `avoid_print`), no errors.
- **Test**: `flutter test` — runs unit tests (currently `test/app_settings_test.dart`).
- **Build**: `flutter build linux` — builds the Linux desktop release binary.
- **Run (dev)**: `flutter run -d linux` — launches in debug mode with hot-reload.
- The `liblsl` Dart package compiles a native C++ shared library at build time using `/usr/lib/llvm-18/bin/clang`. This requires `libstdc++-14-dev`, `lld-18`, and `llvm-18` to be installed. Without these, both `flutter test` and `flutter build linux` will fail with missing C++ headers or linker errors.
- The `libstdc++.so` symlink must exist at `/usr/lib/x86_64-linux-gnu/libstdc++.so` (pointing to `libstdc++.so.6`) for clang to link successfully.

### Python (optional companion)

- **Version**: Python 3.13.12 (per `.python-version`), managed by `uv`.
- **Install**: `CC=gcc CXX=g++ uv sync --all-extras` (needs `CC`/`CXX` set because `numpy` build fails with clang's default C++ search paths).
- **Run receiver**: `uv run python EXTERNAL/SCRIPTS/test_reciever.py --port 9878`
- Add `--lsl` flag to enable LSL rebroadcast.

### Gotchas

- BLE scanning requires a physical Bluetooth adapter; without one the app runs but finds no devices.
- On first build, the `liblsl` native compilation can take 20-30 seconds.
- `flutter pub get` must complete before `flutter analyze`/`flutter test`/`flutter build linux`.