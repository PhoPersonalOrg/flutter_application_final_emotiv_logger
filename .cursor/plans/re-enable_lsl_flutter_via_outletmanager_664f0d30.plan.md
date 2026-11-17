---
name: Re-enable lsl_flutter via OutletManager
overview: ""
todos:
  - id: rewrite-lsl-in-ble-manager
    content: Replace OutletWorker with OutletManager<double> in emotiv_ble_manager.dart
    status: completed
  - id: update-status-methods
    content: Update getLSLStatus() and isLSLHealthy() to reference new OutletManager fields
    status: completed
  - id: verify-build
    content: Verify the project builds cleanly after the migration
    status: completed
---

# Re-enable `lsl_flutter` via `OutletManager`

The `lsl_flutter: ^0.0.6` package is already in `pubspec.yaml`. The current implementation in [`lib/emotiv_ble_manager.dart`](lib/emotiv_ble_manager.dart) uses `OutletWorker` (the isolate-based worker) which has bugs and is unnecessarily complex. Replace it with the package's proper high-level `OutletManager<double>` — a direct, synchronous manager that avoids isolate lifecycle issues.

## Why `OutletManager` instead of `OutletWorker`

| | `OutletWorker` (current, broken) | `OutletManager` (new) |

|---|---|---|

| Setup | `await OutletWorker.spawn()` + isolate init with 10s timeout | Direct constructor, no async spawn |

| Push | `await worker.pushSample(name, data)` — async round-trip to isolate | `manager.pushSample(data)` — synchronous FFI call |

| Teardown | `removeStream` + missing `shutdown()` → isolate leaks | `manager.destroy()` |

| Failure mode | Isolate spawn timeout on mobile | Immediate exception, catchable |

## Changes to [`lib/emotiv_ble_manager.dart`](lib/emotiv_ble_manager.dart)

### Fields — replace the single worker + typed StreamInfo fields:

```dart
// Remove:
OutletWorker? _lslWorker;
StreamInfo? _eegStreamInfo;
StreamInfo? _motionStreamInfo;

// Add:
OutletManager<double>? _eegOutletManager;
OutletManager<double>? _motionOutletManager;
```

### `_initializeLSLOutlet()` — remove isolate spawn, create managers directly:

```dart
final eegInfo = StreamInfoFactory.createDoubleStreamInfo('Epoc X', 'EEG', Float32ChannelFormat(), channelCount: 14, nominalSRate: 128.0, sourceId: deviceId);
_eegOutletManager = OutletManager<double>(eegInfo);

final motionInfo = StreamInfoFactory.createDoubleStreamInfo('Epoc X Motion', 'Accelerometer', Float32ChannelFormat(), channelCount: 6, nominalSRate: 16.0, sourceId: deviceId);
_motionOutletManager = OutletManager<double>(motionInfo);
```

### `_pushToLSL()` — synchronous push, no async:

```dart
_eegOutletManager!.pushSample(sample);
```

### `_pushMotionToLSL()` — synchronous push, no async:

```dart
_motionOutletManager!.pushSample(sample);
```

### `_closeLSLOutlet()` — proper teardown:

```dart
_eegOutletManager?.destroy();
_motionOutletManager?.destroy();
_eegOutletManager = null;
_motionOutletManager = null;
```

### `getLSLStatus()` / `isLSLHealthy()` — update field references from `_lslWorker` to `_eegOutletManager`

No changes to `pubspec.yaml` — `lsl_flutter` stays, `liblsl` stays (used by the test example).