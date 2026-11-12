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
  motion.csv     # wall_ms, mono_us, Q0…Q3, AccX/Y/Z, MagX/Y/Z
  raw.csv        # wall_ms, mono_us, kind, bytes
```

Timestamps are receive-time (headset clock is not available on this BLE path).

## Sessions tab (transfer)

Bottom nav **Sessions** lists prior `session_*` folders. Multi-select and transfer over **SFTP** (`dartssh2`) or **SMB** (`dart_smb2`) to a remembered server bookmark (host/user/path in SharedPreferences; optional password in secure storage). The live recording folder is not transferable/deletable while acquisition is open. SFTP over Tailscale is the usual path; SMB on LAN may need Local Network permission on iOS.

## Decoding

Packet layouts, channel order and scale factors follow the EmotivPRO V4 Android library (see `lib/decode/crypto_codec.dart` for the function each one was read from).

- **EEG**: 32-byte packages, XOR `0x55` + AES-128-ECB. ADC divisor comes from the headset config characteristic when present (`/1.95` for 14-bit, `/7.8` for 16-bit); otherwise defaults to 16-bit.
- **Motion**: 20-byte unencrypted packages holding an orientation quaternion, accelerometer (g) and magnetometer. There is no gyroscope data in the Epoc X motion package.
- **Not supported**: headset firmware newer than `0x73e` (AES-256 keying) and headsets switched to legacy EPOC mode. Both decrypt to noise; the Health card shows a warning when the EEG package counters stop being sequential. `raw.csv` always keeps the undecrypted packets.

## LSL

In-process outlets via `lsl_flutter` only:

| Stream | Type | Channels | Rate |
|--------|------|----------|------|
| Epoc X | EEG | 14 | 128 Hz |
| Epoc X Motion | Accelerometer | 10 (Q0–Q3, Acc XYZ, Mag XYZ) | 16 Hz |

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
fvm install 3.47.9
fvm use 3.47.9
fvm flutter pub get
```

Android builds require **JDK 17+** (Java 25 works with this project's Gradle **9.3.1** / AGP **9.1.1**). Prefer `fvm flutter` so the pin matches the build.

## Build / run

Use the status-bar Flutter device picker for the target, then:

```bash
fvm flutter run
# Pixel 2 example:
fvm flutter run -d FA7B71A02109
# or workspace Action Buttons: Run Device / Debug Device / Build iOS
```

iOS simulator builds work for UI only; **real headset acquisition requires a physical device**.

## Health UI

Record tab shows acquisition state, EEG/motion Hz, decode failures, gap count, CSV/LSL drop counts, LSL status, and session path.
