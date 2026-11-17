---
name: Enable LSL for Android
overview: "Ensure LabStreamingLayer (LSL) outlets work on Android with the same behavior as on iOS: confirm no platform guard, verify Android build/permissions, and align any hostname fix (from the iOS plan) for both platforms."
todos: []
isProject: false
---

# Enable LSL Outlets for Android (parity with iOS)

## Current state

- **Dart**: LSL is already initialized on **both** platforms. In [lib/emotiv_ble_manager.dart](lib/emotiv_ble_manager.dart), `_initializeLSLOutlet()` is called unconditionally from `connectToDevice()` (line 515). There is **no** `Platform.isIOS`-only guard that skips LSL on Android; the only platform use is for the status string (`"Initializing LSL outlet on iOS/Android..."`).
- **Stack**: The app uses **lsl_flutter** with `OutletManager<double>` (per [re-enable_lsl_flutter_via_outletmanager_664f0d30.plan.md](.cursor/plans/re-enable_lsl_flutter_via_outletmanager_664f0d30.plan.md)); [reimplement_lsl_outlets_with_liblsl_f39ab4b4.plan.md](.cursor/plans/reimplement_lsl_outlets_with_liblsl_f39ab4b4.plan.md) and [fix_lsl_outlet_hostname_on_ios_f488ddc5.plan.md](.cursor/plans/fix_lsl_outlet_hostname_on_ios_f488ddc5.plan.md) refer to a future migration to **liblsl** and an iOS hostname fix.
- **Android config**: [android/app/build.gradle.kts](android/app/build.gradle.kts) uses `minSdk = 27` (lsl_flutter requires ≥26). [android/app/src/main/AndroidManifest.xml](android/app/src/main/AndroidManifest.xml) already declares the LSL-related permissions: `INTERNET`, `CHANGE_WIFI_MULTICAST_STATE`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE` (and the same in debug/profile manifests).

So at the Dart and manifest level, LSL is already “enabled” for Android in the same way as iOS. The remaining work is to **explicitly ensure parity** and to **align the hostname fix** so that when it is implemented, it applies to Android as well.

---

## 1. Confirm no platform-only LSL path

- **Check**: Ensure no code path skips LSL on Android (e.g. `if (Platform.isIOS) await _initializeLSLOutlet();`).
- **Result**: No such guard exists. `_initializeLSLOutlet()` is always called on connect. No code changes required for this.

---

## 2. Android build and permissions (verification only)

- **minSdk**: Already 27 in [android/app/build.gradle.kts](android/app/build.gradle.kts) (≥26 required by lsl_flutter).
- **Permissions**: All required permissions for LSL (and for liblsl) are present in the main and debug/profile manifests.
- **Action**: No changes needed unless you see runtime errors on Android (e.g. missing native lib); then verify that `lsl_flutter` / `lsl_bindings` are included in the Android build (e.g. `flutter build apk` and inspect that the plugin is registered and native libs are packaged).

---

## 3. Hostname fix parity (when migrating to liblsl)

[fix_lsl_outlet_hostname_on_ios_f488ddc5.plan.md](.cursor/plans/fix_lsl_outlet_hostname_on_ios_f488ddc5.plan.md) describes setting the outlet hostname to the device’s WiFi IP on iOS so discovery works (instead of `localhost`). The same issue can occur on Android (`gethostname()` may not be suitable for discovery).

When you implement that plan (after or as part of the liblsl migration):

- In `_initializeLSLOutlet()` (or the liblsl equivalent), obtain the WiFi IP on **both** iOS and Android (e.g. `network_info_plus`’s `getWifiIP()`).
- Call the hostname setter (e.g. `lsl_set_hostname` in the vendored liblsl C API) **for both platforms** before creating the outlet, so Android outlets are discoverable the same way as iOS.

No code change in the current repo is required until the liblsl migration and hostname fix are implemented; the plan is to implement the hostname logic in a platform-agnostic way (same code path for iOS and Android).

---

## 4. Optional cleanup

- [lib/main.dart](lib/main.dart) line 54: `final bool _useLSLStreams = false;` is never read. You can remove it or wire it to a real feature flag if you want to toggle LSL from the UI later.

---

## Summary


| Item                         | Action                                                                                                                     |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Platform guard               | None found; LSL already runs on Android on connect.                                                                        |
| Android minSdk & permissions | Already correct; no change.                                                                                                |
| Hostname fix                 | When applying the iOS hostname fix (post-liblsl), use WiFi IP on **both** iOS and Android in the same initialization path. |
| Dead code                    | Optionally remove or use `_useLSLStreams` in main.dart.                                                                    |


If LSL still fails on Android at runtime, the next step is to confirm that the `lsl_bindings` (or, after migration, liblsl) native Android library is built and included in the APK and that no plugin registration is missing for Android.