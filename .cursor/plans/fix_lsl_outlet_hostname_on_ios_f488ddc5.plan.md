---
name: Fix LSL Outlet Hostname on iOS
overview: ""
todos:
  - id: vendor-liblsl
    content: Copy liblsl-0.9.1 from pub-cache to packages/liblsl and switch pubspec.yaml to path dependency
    status: pending
  - id: patch-tcp-server
    content: Modify tcp_server.cpp to not overwrite hostname if already set (conditional guard)
    status: pending
  - id: add-lsl-set-hostname-c-api
    content: Add lsl_set_hostname to lsl_streaminfo_c.cpp + declaration in streaminfo.h
    status: pending
  - id: regen-dart-bindings
    content: Run ffigen to regenerate native_liblsl.dart with new lsl_set_hostname binding
    status: pending
  - id: integrate-in-dart
    content: In _initializeLSLOutlet(), get WiFi IP via network_info_plus and call lsl_set_hostname before lsl_create_outlet
    status: pending
---

# Fix LSL Outlet Hostname on iOS

## Root Cause

In [`liblsl/src/tcp_server.cpp`](https://github.com/labstreaminglayer/liblsl/blob/master/src/tcp_server.cpp) line 153:

```cpp
info_->hostname(asio::ip::host_name());
```

`asio::ip::host_name()` calls `gethostname()` which returns `"localhost"` on iOS devices (unlike macOS where it returns the `.local` mDNS name). This hostname is then **baked into pre-cached protocol messages** via `begin_serving()`, so no post-creation XML manipulation can fix it.

## Why the current stack can't be patched in-place

- **`lsl_bindings-0.0.5`** (used by `lsl_flutter`) ships a **pre-built `lsl.xcframework`** for iOS — the C++ source is already compiled into a binary. Source changes have no effect.
- **`liblsl-0.9.1`** uses `native_toolchain_c` and **compiles from source** on every build — source changes DO take effect.

## Plan

Vendor `liblsl-0.9.1` as a local path dependency, add a one-line conditional guard in `tcp_server.cpp` + expose `lsl_set_hostname` in the C API, regenerate Dart bindings, then call it from Dart with the device's real WiFi IP before outlet creation.

### Files changed

| File | Change |

|------|--------|

| `packages/liblsl/src/liblsl-bea40e2c/src/tcp_server.cpp` | Conditionally set hostname only if not already set |

| `packages/liblsl/src/liblsl-bea40e2c/src/lsl_streaminfo_c.cpp` | Add `lsl_set_hostname` C export |

| `packages/liblsl/src/liblsl-bea40e2c/include/lsl/streaminfo.h` | Declare `lsl_set_hostname` |

| `packages/liblsl/lib/native_liblsl.dart` | Re-run `ffigen` to expose new binding |

| `pubspec.yaml` | Switch `liblsl:` to `path: packages/liblsl` |

| [`lib/emotiv_ble_manager.dart`](lib/emotiv_ble_manager.dart) | Call `lsl_set_hostname` with WiFi IP before `LSL.createOutlet` |

### Key code changes

**`tcp_server.cpp` — guard (don't overwrite if already set):**

```cpp
// was: info_->hostname(asio::ip::host_name());
if (info_->hostname().empty() || info_->hostname() == "localhost")
    info_->hostname(asio::ip::host_name());
```

**`lsl_streaminfo_c.cpp` — new export:**

```cpp
LIBLSL_C_API void lsl_set_hostname(lsl_streaminfo info, const char *hostname) {
    info->hostname(hostname);
}
```

**`emotiv_ble_manager.dart` — call site (uses `network_info_plus`):**

```dart
final wifiIP = await NetworkInfo().getWifiIP() ?? '';
if (wifiIP.isNotEmpty) {
    lsl.bindings.lsl_set_hostname(nativeInfo, wifiIP.toNativeUtf8().cast());
}
// then: lsl.bindings.lsl_create_outlet(nativeInfo, ...)
```

This requires also completing the migration from `lsl_flutter` → `liblsl` (the pending `reimplement_lsl_outlets_with_liblsl` plan), since `lsl_flutter` uses the pre-built binary and the new binding is only available in the vendored `liblsl`.