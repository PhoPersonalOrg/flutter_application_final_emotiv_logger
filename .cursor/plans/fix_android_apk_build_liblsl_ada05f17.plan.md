---
name: Fix Android APK build liblsl
overview: The APK build fails because the liblsl Dart package's native-asset build references a missing NDK path for libc++_shared.so. The app does not use liblsl at runtime (it uses lsl_flutter). Removing liblsl and the example that depends on it restores the Android build; no Flutter re-download is required.
todos: []
isProject: false
---

# Fix Android APK build (liblsl native-asset failure)

## What’s going wrong

The error is **not** from the Flutter version. It comes from the **liblsl** Dart package’s native-asset build when targeting Android:

```text
Hook.build hook of package:liblsl has invalid output
- Code asset "package:liblsl/libc++_shared.so" file (...\ndk\27.0.12077973\...\arm-linux-androideabi\libc++_shared.so) does not exist as a file.
```

So:

- **Flutter**: No need to download or change the Flutter version.
- **Real cause**: `liblsl` (or its toolchain) expects `libc++_shared.so` at an NDK path that doesn’t exist on your machine (NDK 27 layout may differ, or the package’s path logic is wrong). This is a known class of issue with native Dart packages on Android (e.g. [dart-lang/native#2099](https://github.com/dart-lang/native/issues/2099)).

## How the project uses LSL

- **Runtime LSL**: The app uses **lsl_flutter** only. [lib/emotiv_ble_manager.dart](lib/emotiv_ble_manager.dart) uses `StreamInfoFactory` and `OutletManager<double>` from `lsl_flutter`; there are no `import 'package:liblsl/...'` in the main app.
- **liblsl**: Only referenced in [lib/testing/liblsl_example.dart](lib/testing/liblsl_example.dart) (`import 'package:liblsl/lsl.dart'`). That file is a standalone example (and referenced in the reimplement plan), not used by the main app.

So the APK does **not** need `liblsl` to run; it only needs `lsl_flutter` (and its native bits, which are separate and working).

## Recommended fix: drop liblsl for now so Android builds

1. **Remove the `liblsl` dependency** from [pubspec.yaml](pubspec.yaml) so the native-asset build for liblsl is no longer run and the missing `libc++_shared.so` path is no longer required.
2. **Handle the only consumer of liblsl** so the rest of the app still compiles:
  - **Option A (simplest)**: Delete [lib/testing/liblsl_example.dart](lib/testing/liblsl_example.dart). You can re-add a liblsl example later when you do the “reimplement LSL with liblsl” migration (and when liblsl’s Android build is fixed or you build only on other platforms).
  - **Option B**: Keep the file but remove the liblsl dependency from it (e.g. replace with a stub that prints that the example is disabled until the liblsl migration), so the file no longer imports `package:liblsl`.

After that, `flutter build apk` should succeed using only `lsl_flutter` / `lsl_bindings` for LSL on Android.

## If you want to keep liblsl in the project

- **Upgrade**: Check [pub.dev/packages/liblsl](https://pub.dev/packages/liblsl) for a newer version that might fix the Android/NDK path.
- **Report**: Open an issue (or comment on an existing one) in the [liblsl.dart repo](https://github.com/NexusDynamic/liblsl.dart) with your NDK version (27.0.12077973) and the full error; the path may need to be updated for NDK 27.
- **Workaround**: You could try a different NDK version (e.g. 25 or 26) in [android/app/build.gradle.kts](android/app/build.gradle.kts) (`ndkVersion`) and see if the path exists there, but that’s trial-and-error and may conflict with other plugins.

The robust way to get the APK building **now** is to remove the liblsl dependency and the example that uses it, then restore liblsl when you do the full migration and the package (or NDK) situation is resolved.