# Emotiv Acquisition Logger

Flutter app that reliably acquires Emotiv Epoc X / Epoc+ EEG and motion over BLE, with **CSV + LSL as first-class sinks**. Network NDJSON streaming is optional and best-effort.

## Architecture (acquisition-first)

```
Headset BLE → AcquisitionSession (FSM)
                → DecodePipeline (isolate)
                → SampleHub (bounded queues)
                     ├─ CsvSink      (first-class)
                     ├─ LslSink      (first-class; Degraded if native lib fails)
                     ├─ NetworkSink  (best-effort, never backpressures BLE)
                     └─ UI preview   (throttled)
```

Explicit states: `Idle → Scanning → Connecting → Preparing → Streaming`, with `Reconnecting` / `Stopping` / `Failed`. Subscriptions are cancelled as a bag on every session exit; teardown is awaited in order (stop packets → cancel notifies → flush CSV → close LSL → disconnect).

## Session files

Each connect creates:

```
{saveDir}/session_{iso}/
  session.json   # device name, key fingerprint, rates
  eeg.csv        # wall_ms, mono_us, AF3…AF4
  motion.csv     # wall_ms, mono_us, Acc/Gyro
  raw.csv        # wall_ms, mono_us, kind, bytes
```

Timestamps are receive-time (headset clock is not available on this BLE path).

## LSL

In-process outlets via `lsl_flutter` only:

| Stream | Type | Channels | Rate |
|--------|------|----------|------|
| Epoc X | EEG | 14 | 128 Hz |
| Epoc X Motion | Accelerometer | 6 | 16 Hz |

If outlet creation fails (e.g. Android `liblsl.so`), LSL becomes **Degraded** and acquisition + CSV continue.

## Network streaming (optional)

Settings → enable network stream (UDP/TCP NDJSON). Failures never pause BLE.

Companion receiver:

```bash
python EXTERNAL/SCRIPTS/test_reciever.py --port 9878
# optional LSL rebroadcast:
pip install pylsl
python EXTERNAL/SCRIPTS/test_reciever.py --lsl --port 9878
```

## Setup (macOS)

```bash
brew tap leoafarias/fvm
brew install fvm
fvm install 3.42.0-0.0.pre
fvm use 3.42.0-0.0.pre
fvm flutter pub get
```

## Build / run

Use the status-bar Flutter device picker for the target, then:

```bash
fvm flutter run
# or workspace Action Buttons: Run Device / Debug Device / Build iOS
```

iOS simulator builds work for UI only; **real headset acquisition requires a physical device**.

## Health UI

Home screen shows acquisition state, EEG/motion Hz, decode failures, gap count, CSV/LSL drop counts, LSL status, and session path.
