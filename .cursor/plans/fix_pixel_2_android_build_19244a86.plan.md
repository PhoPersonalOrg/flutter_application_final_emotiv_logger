---
name: Fix Pixel 2 Android build
overview: The cryptic Gradle error `25.0.4` is Java 25 running Gradle 8.12 (incompatible). Upgrade to latest Flutter stable and an AGP 9 / Gradle 9.3 Android stack that supports Java 25, bump dependencies, then build and run on the attached Pixel 2.
todos:
  - id: upgrade-flutter-fvm
    content: Install/use latest Flutter stable via FVM; update .fvmrc and workspace SDK path
    status: completed
  - id: upgrade-android-gradle
    content: Bump Gradle 9.3.1, AGP 9.1.0, KGP 2.4.0; set builtInKotlin/newDsl false; align app/build.gradle.kts
    status: completed
  - id: upgrade-pubs
    content: fvm flutter pub upgrade --major-versions and fix compile breaks
    status: completed
  - id: run-pixel2
    content: Clean, build, and flutter run on Pixel 2 FA7B71A02109
    status: completed
  - id: update-readme-pin
    content: Update README Flutter version pin to match FVM
    status: completed
isProject: false
---

# Fix Pixel 2 Android build (Java 25 / Gradle)

## Root cause

Terminal failure:

```text
* What went wrong:
25.0.4
```

This is the known **Java 25 + Gradle 8.x** crash (Flutter even added a better message later). Your machine is on JDK **25.0.4**; the project uses **Gradle 8.12** ([`android/gradle/wrapper/gradle-wrapper.properties`](android/gradle/wrapper/gradle-wrapper.properties)) and **AGP 8.7.3** ([`android/settings.gradle.kts`](android/settings.gradle.kts)). That combination cannot start the Gradle daemon.

`local.properties` still points at FVM **3.42.0-0.0.pre**, while you ran bare `flutter run` against the Pixel 2 (`FA7B71A02109`).

## Approach

Upgrade Flutter + Android toolchain to versions that support Java 25 (Gradle **9.3.1** + AGP **9.1.0**, matching current Flutter stable templates). Keep **built-in Kotlin disabled** (`android.builtInKotlin=false`) so plugins that still apply `kotlin-android` (e.g. BLE/LSL) keep building. Then `pub upgrade` and `flutter run` on the Pixel 2.

## Steps

1. **Flutter toolchain**
   - `fvm install` / `fvm use` latest **stable** (expect ~3.47.x).
   - Update [`.fvmrc`](.fvmrc), workspace `dart.flutterSdkPath`, and regenerate `android/local.properties` via `fvm flutter pub get`.
   - Prefer `fvm flutter ...` for all subsequent commands so the pin matches the build.

2. **Android Gradle stack** (Java 25–compatible)
   - [`android/gradle/wrapper/gradle-wrapper.properties`](android/gradle/wrapper/gradle-wrapper.properties): `gradle-9.3.1-all.zip`
   - [`android/settings.gradle.kts`](android/settings.gradle.kts):
     - `com.android.application` **9.1.0**
     - `org.jetbrains.kotlin.android` **2.4.0** (keep `apply false`; do not remove yet)
   - [`android/gradle.properties`](android/gradle.properties): add
     - `android.builtInKotlin=false`
     - `android.newDsl=false`
     so AGP 9 does not force built-in Kotlin / new DSL before plugins are ready.
   - [`android/app/build.gradle.kts`](android/app/build.gradle.kts):
     - `ndkVersion = flutter.ndkVersion` (drop hard-coded `28.2...` unless Flutter requires a pin)
     - Keep `minSdk = 27` (Pixel 2 / BLE needs)
     - Align Java/Kotlin JVM target with Flutter template (17 if the new template requires it)

3. **Dependencies**
   - `fvm flutter pub upgrade --major-versions` for app packages (`flutter_blue_plus`, `permission_handler`, Riverpod, etc.).
   - Fix any breakages from major bumps (imports / API) only as needed to compile.

4. **Build and run on Pixel 2**
   - Confirm device: `fvm flutter devices` → `Pixel 2 • FA7B71A02109`
   - `fvm flutter clean && fvm flutter pub get`
   - `fvm flutter run -d FA7B71A02109`
   - If Gradle still complains about JDK, set Flutter’s JDK explicitly to a compatible install only as a last resort; primary fix is Gradle 9.3.1.

5. **Docs touch**
   - Update README Flutter setup line from `3.42.0-0.0.pre` to the new FVM pin.

## Success criteria

- `assembleDebug` / `flutter run` completes without the `25.0.4` Gradle abort.
- App installs and launches on the attached Pixel 2.

## Note on LSL

Android LSL native load may still degrade at runtime (known prior issue); that must not block the APK build. Acquisition + CSV remain the reliability path if LSL is Degraded.