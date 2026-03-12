---
name: Reimplement LSL Outlets with liblsl
overview: ""
todos:
  - id: update-pubspec
    content: Remove lsl_flutter from pubspec.yaml dependencies
    status: pending
  - id: rewrite-ble-manager-lsl
    content: Reimplement LSL outlets in emotiv_ble_manager.dart using liblsl API
    status: pending
  - id: verify-build
    content: Verify the project builds successfully after the migration
    status: pending
---

# Reimplement LSL Outlets with `liblsl`

Replace the `lsl_flutter` `OutletWorker`-based LSL implementation in [`lib/emotiv_ble_manager.dart`](lib/emotiv_ble_manager.dart) with direct `liblsl` `LSLOutlet` objects. The `liblsl: ^0.9.1` package is already in `pubspec.yaml` and locked. The `lsl_flutter: ^0.0.6` dependency will be removed.

## Current vs New API

| Concern | `lsl_flutter` (current) | `liblsl` (new) |

|---|---|---|

| Import | `lsl_flutter/lsl_flutter.dart` | `liblsl/lsl.dart` |

| Stream creation | `StreamInfoFactory.createDoubleStreamInfo(...)` | `await LSL.createStreamInfo(streamName:, streamType:, ...)` → `LSLStreamInfo` |

| Outlet creation | `await OutletWorker.spawn()` + `worker.addStream(info)` | `await LSL.createOutlet(streamInfo: info)` → `LSLOutlet` |

| Push sample | `worker.pushSample("StreamName", data)` | `outlet.pushSample(data)` |

| Teardown | `worker.removeStream("name")` | `outlet.destroy()` + `streamInfo.destroy()` |

## Changes

### [`lib/emotiv_ble_manager.dart`](lib/emotiv_ble_manager.dart)

1. **Import**: swap `lsl_flutter` → `liblsl`
2. **Fields**: replace single `OutletWorker? _lslWorker` + `StreamInfo?` pair with two direct outlets:
```dart
LSLOutlet? _eegOutlet;
LSLOutlet? _motionOutlet;
LSLStreamInfo? _eegStreamInfo;
LSLStreamInfo? _motionStreamInfo;
```

3. **`_initializeLSLOutlet()`**: replace `OutletWorker.spawn()` + `addStream()` pattern with:
```dart
_eegStreamInfo = await LSL.createStreamInfo(streamName: 'Epoc X', streamType: LSLContentType.eeg, channelCount: 14, sampleRate: 128.0, channelFormat: LSLChannelFormat.float32, sourceId: deviceId);
_eegOutlet = await LSL.createOutlet(streamInfo: _eegStreamInfo!, chunkSize: 0, maxBuffer: 360);
_motionStreamInfo = await LSL.createStreamInfo(streamName: 'Epoc X Motion', streamType: LSLContentType.custom('Accelerometer'), channelCount: 6, sampleRate: 16.0, channelFormat: LSLChannelFormat.float32, sourceId: deviceId);
_motionOutlet = await LSL.createOutlet(streamInfo: _motionStreamInfo!, chunkSize: 0, maxBuffer: 360);
```

4. **`_pushToLSL()`**: `await _eegOutlet!.pushSample(sample)` (returns `int` error code, 0 = success)
5. **`_pushMotionToLSL()`**: `await _motionOutlet!.pushSample(sample)` 
6. **`_closeLSLOutlet()`**: replace `removeStream` calls with `await _eegOutlet?.destroy()` + `await _eegStreamInfo?.destroy()` (and same for motion)
7. **`getLSLStatus()` / `isLSLHealthy()`**: replace `workerActive: _lslWorker != null` with `eegOutletActive: _eegOutlet != null`

### [`pubspec.yaml`](pubspec.yaml)

- Remove `lsl_flutter: ^0.0.6`

### [`lib/testing/liblsl_example.dart`](lib/testing/liblsl_example.dart)

- No changes needed (already uses `liblsl` API correctly)