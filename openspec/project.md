# Project Context

## Purpose
Cross‑platform Flutter app to connect to Emotiv Epoc X / Epoc+ over BLE, decrypt EEG and MEMS data on‑device, and stream it via LabStreamingLayer (LSL). The app also supports local logging of EEG and motion data for offline analysis.

Goals:
- Reliable BLE acquisition of Epoc X/Plus data on Android/iOS/desktop.
- Correct decryption and channel mapping aligned with the reference implementation in `emotiv-lsl`.
- Publish two LSL streams (EEG and Motion) and optionally electrode quality.
- Simple file recording for EEG and motion (CSV/plaintext).

## Tech Stack
- Flutter (Dart SDK ^3.8.1)
- BLE: `flutter_blue_plus`
- Crypto: `encrypt` (AES)
- LSL: `liblsl` (FFI) and `lsl_flutter`
- Storage/OS: `path_provider`, `file_picker`, `device_info_plus`, `shared_preferences`, `permission_handler`
- Platforms: Android (Kotlin Gradle, NDK 27.0.12077973), iOS (Swift), Windows, Linux, macOS

Key packages (from `pubspec.yaml`):
- `flutter_blue_plus:^1.31.x`, `encrypt:^5.x`, `liblsl:^0.9.x`, `lsl_flutter:^0.0.6`

## Project Conventions

### Code Style
- Follow `flutter_lints:^6` defaults.
- Dart null‑safety everywhere; prefer immutable data and explicit types for public APIs.
- 2‑space indentation; descriptive identifiers; early returns over deep nesting.
- Avoid catching broad exceptions without handling; log at appropriate levels.

### Architecture Patterns
- Modular services under `lib/`:
  - `emotiv_ble_manager.dart`: device discovery, connect, per‑characteristic notification handling.
  - `crypto_utils.dart`: XOR + AES helpers, key derivation interop.
  - `eeg_file_writer.dart` / `motion_file_writer.dart` / `generic_file_writer.dart`: local logging.
  - `directory_helper.dart`, `file_storage.dart`: storage utilities.
- UI orchestrates start/stop, permissions, and shows status; data path remains in services.
- LSL publishing is isolated behind a thin adapter (see `testing/liblsl_example.dart` and `liblsl`/`lsl_flutter`).

### Testing Strategy
- Unit tests where feasible (crypto utilities, parsers, file writers).
- Device/integration testing for BLE flows (real hardware; emulators lack BLE reliability).
- Validation with external viewer: use `bsl_stream_viewer` to confirm EEG (14 ch @ 128 Hz) and Motion (6 ch @ ~16 Hz) stream shape and rates.
- Debug mode can emit hex dumps for first N frames to aid diagnosis.

### Git Workflow
- Feature branches (`feature/<name>`), short‑lived and regularly rebased.
- Conventional Commits style recommended (e.g., `feat:`, `fix:`, `refactor:`).
- Small, focused PRs; CI to build at least Android APK in verbose mode when possible.

## Domain Context
Emotiv Epoc X/Plus BLE framing and decryption mirrors the reference in `emotiv-lsl`:
- Separate characteristics for EEG (`DATA_UUID`) and MEMS (`MEMS_UUID`). Process notifications into per‑UUID queues to avoid cross‑contamination.
- EEG decryption path: XOR each byte with `0x55` → AES‑ECB decrypt with device key → parse 14‑channel EEG according to Epoc X mapping. Do not use the legacy Epoc+ “`data[1]==32` motion sentinel” on BLE.
- MEMS path: parse 6‑channel IMU (Accel/Gyro). Some firmware may require XOR+AES; handle both clear‑text and decrypted paths safely.
- LSL streams:
  - EEG stream name: `Epoc X` (14 channels, 128 Hz; source_id derived from serial).
  - Motion stream name: `Epoc X Motion` (6 channels, ~16 Hz).
  - Optional electrode quality stream (guarded feature until offsets confirmed).

Keying/interop:
- BLE key derivation matches CyKit‑style helpers used in `emotiv-lsl` (`CyKitCompatibilityHelpers.get_sn(...)`). The Flutter app should derive the same 16‑byte key from the device serial/model to ensure AES compatibility.

## Important Constraints
- Mobile BLE permissions and runtime prompts vary by platform (location/nearby devices on Android 12+).
- liblsl on Android requires correct ABI and NDK toolchain. Known issue: symbol resolution failures (e.g., `__cxa_init_primary_exception`) when ABI/C++ runtime mismatch; ensure proper `liblsl.so` packaging for arm64/armv7 with matching STL.
- Keep CPU/battery usage low; avoid heavy logging in release builds.
- EEG data is sensitive; data is stored locally by default and never transmitted to cloud services by this app.

## External Dependencies
- Hardware: Emotiv Epoc X / Epoc+ headset (BLE mode).
- Libraries: `liblsl` native binaries per platform.
- Validation tools: Brain‑Signal Lab `bsl_stream_viewer` (from `bsl` project) to verify stream integrity.
- Reference implementation: `emotiv-lsl` for BLE decoding specifics and stream structure.
