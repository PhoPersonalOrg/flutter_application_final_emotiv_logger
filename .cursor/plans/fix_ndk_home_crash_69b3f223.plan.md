---
name: Fix NDK HOME crash
overview: Resolve `flutter run` failure caused by Windows environment detection in `android_libcpp_shared` and verify Android NDK alignment with this app’s pinned version.
todos:
  - id: check-env
    content: Inspect current user/shell variables for HOME and Android SDK/NDK paths
    status: completed
  - id: set-env
    content: "Set persistent user variables: HOME, ANDROID_SDK_ROOT, ANDROID_HOME, ANDROID_NDK_HOME"
    status: completed
  - id: verify-ndk
    content: Confirm NDK 28.2.13676358 exists under Android SDK
    status: completed
  - id: rebuild-verify
    content: Rebuild with flutter clean/pub get/run and confirm error is resolved
    status: completed
isProject: false
---

# Fix Windows NDK Locator Crash

## What’s failing
- The crash is inside `android_libcpp_shared` where `HOME` is force-unwrapped on Windows (`Platform.environment['HOME']!`), so `flutter run` fails if `HOME` is unset.
- Your project already has Android SDK/Flutter paths in [`android/local.properties`](C:/Users/pho/repos/EmotivEpoc/META/META_HEADSET_HW/flutter_application_final_emotiv_logger/android/local.properties).
- The app pins NDK `28.2.13676358` in [`android/app/build.gradle.kts`](C:/Users/pho/repos/EmotivEpoc/META/META_HEADSET_HW/flutter_application_final_emotiv_logger/android/app/build.gradle.kts), so machine env should match that.
- The null-unwrap source is in cached package code at [`locate_ndk.dart`](C:/Users/pho/AppData/Local/Pub/Cache/hosted/pub.dev/android_libcpp_shared-0.1.1/lib/src/locate_ndk.dart).

## Implementation Plan (machine-level only)
- Verify current shell/user env values (`HOME`, `USERPROFILE`, `ANDROID_SDK_ROOT`, `ANDROID_HOME`, `ANDROID_NDK_HOME`) and confirm whether `HOME` is missing.
- Persist `HOME` at user scope to `%USERPROFILE%` (Windows-safe fix for this package behavior).
- Ensure Android SDK env vars are set consistently to `C:\Users\pho\AppData\Local\Android\sdk` (`ANDROID_SDK_ROOT` and `ANDROID_HOME`).
- Ensure NDK `28.2.13676358` is installed under SDK `ndk/` and set `ANDROID_NDK_HOME` to that exact directory.
- Restart terminal session, run `flutter clean`, `flutter pub get`, and `flutter run` to validate the fix end-to-end.

## Validation
- `flutter run` no longer throws `Null check operator used on a null value` from `android_libcpp_shared`.
- Build proceeds past native assets hook and into Gradle compile/install steps.
- If build still fails, capture updated stack trace to distinguish env resolution from downstream native-link issues.