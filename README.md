# Emotiv Acquisition Logger

Flutter app that acquires Emotiv **EPOC X** 14-channel EEG, 9-axis Motion/IMU, per-electrode Contact Quality (`CQ`), Battery, and Hardware Trigger (`marker_hw`) over BLE GATT (`81072f40-9f3d-11e3-a9dc-0002a5d5c51b`), with **CSV + LSL as first-class sinks** and clean-room parity against `CortexService.exe` (`4.8.16.1`).

## Architecture (acquisition-first)

```
Headset BLE (81072f40 + DIS 0x180A)
  → AcquisitionSession (Active Scan, ATT_MTU >= 87, High Priority, FSM)
  → DecodePipeline (Isolate: 64B/84B Split, V2 AES-128 / V4 AES-256, CQ & Battery Demux)
  → SampleHub (bounded queues)
       ├─ CsvSink      (first-class: session.json, eeg.csv, motion.csv, cq.csv, raw.csv)
       ├─ LslSink      (first-class: Epoc X, Epoc X eQuality, Epoc X Motion)
       ├─ NetworkSink  (best-effort NDJSON UDP/TCP, never backpressures BLE)
       └─ UI preview   (throttled 14-ch plot + per-electrode scalp CQ map & history strip)
```

Explicit states: `Idle → Scanning → Connecting → Preparing → Streaming`, with `Reconnecting` / `Stopping` / `Failed`. Subscriptions are cancelled as a bag on every session exit; teardown is awaited in order (stop packets → cancel notifies → flush CSV → close LSL → disconnect).

## BLE Protocol & Codec Summary

- **Active Scanning:** Physical EPOC X places `"EPOCX (<8HEX>)"` (`AD 0x09`) in `ADV_IND` and places `81072f40-9f3d-11e3-a9dc-0002a5d5c51b` (`AD 0x07`) in `SCAN_RSP`. Active scanning (`SCAN_REQ`) is enabled automatically.
- **Link Negotiation & GATT Reads:** Requests `ATT_MTU >= 87` (`247` requested on Android; headset locks `87` for `84B` super-frames) and `ConnectionPriority.high` (`7.5–10 ms` interval). Reads DIS `0x2A25` (`5` binary serial bytes), DIS `0x2A26` (`2` BE firmware bytes), and `81072f44` (`6` mode configuration bytes: `128`/`256` Hz EEG, `14`/`16`-bit EEG, `0`/`32`/`64`/`128` Hz MEMS). Subscribes CCCD `01 00` on `81072f41` with **zero** unlock/challenge writes.
- **Notification Splitting (`81072f41`, `fw > 0x0710`):**
  - `64` bytes: `2 × 32B` encrypted EEG frames (`[0..32]`, `[32..64]`).
  - `84` bytes (`0x54`): `2 × 32B` encrypted EEG frames + `20B` Motion/MEMS tail (`[64..84]`).
- **Hardware Key Schedules (`V2` & `V4`):**
  - **Version 2 (`fw <= 0x073E`):** `AES-128-ECB`, `preXor = 0x55` on `32B` EEG; `20B` BLE Motion is unencrypted pass-through.
  - **Version 4 (`fw >= 0x073F`):** `AES-256-ECB` (`SHA256("Vohcha7e" + S8[0..4] + "Ut3phaej" + S8[4..8] + fwHex4)`), `preXor = 0x14` on `32B` EEG, and `16B AES-256-ECB + 4B XOR 0x14` on `20B` BLE Motion.
- **EEG, Per-Electrode CQ, Battery & IMU Orientation:**
  - **EEG (`uV`):** `15 × uint16 LE` unpacked in 10-20 order (`AF3..AF4`), scaled by `÷7.8` (`16`-bit) or `÷1.95` (`14`-bit), plus `marker_hw = (P[1] >> 7) & 1`.
  - **In-Band Battery:** Latched strictly on `counter == eegRateHz - 1` (`127` @ `128 Hz`, `255` @ `256 Hz`) when `words[7] != 0`: `batteryPct = clamp(words[7] & 0x7F, 0, 100)`.
  - **Per-Electrode CQ:** Demultiplexed via `slot = counter % (eegRateHz ~/ 2)` (`0..13`) in ASIC order (`F3..F4`) using `(0.25 * words[7]) / CQ_SCALE[slot]` into discrete Cortex grades (`0, 1, 2, 4`), held across each `0.5 s` (`2 Hz`) cycle and emitted in `AF3..AF4` order.
  - **Motion/IMU (`Q0..Q3, AccX..Z, MagX..Z`):** Configurable `Headband orientation` in Settings (`Top of head` default axis swap/negation vs. `Back of head` identity).

## Session files

Each connect creates (CSV/`raw.csv` is **always on** when the session folder opens — no toggle). On iOS the folder is under app Documents.

```
{saveDir}/session_{iso}/
  session.json   # btKeyHex, disSerialHex, headsetFirmwareHex, cryptoVersion, headsetConfigHex, rates, …
  eeg.csv        # wall_ms, mono_us, counter, marker_hw, AF3…AF4
  motion.csv     # wall_ms, mono_us, counter_mems, Q0…Q3, AccX/Y/Z, MagX/Y/Z
  cq.csv         # wall_ms, mono_us, counter, overall_cq, battery_pct, qAF3…qAF4
  raw.csv        # wall_ms, mono_us, kind, char_uuid, bytes
```

`raw.csv` stores undecrypted BLE notify payloads (`64B` / `84B` / `20B`) **before** split/decrypt gates. `btKeyHex` (`8`-char uppercase hex) and `serialSource: "ble_hex"` are preserved alongside `disSerialHex` (`10`-char hex from `0x2A25`) and `headsetFirmwareHex` for backward-compatible offline replay.

## LSL

In-process outlets via vendored `liblsl` (`packages/liblsl`), advertising the configured **Hostname** from Settings (default `iPhone`, shown in LabRecorder as `Epoc X (iPhone)`) at the active rates reported by `81072f44`:

| Stream | Type | Channels | Rate |
|--------|------|----------|------|
| Epoc X | EEG | 14 (`AF3..AF4`, `uV`) | `128` or `256` Hz |
| Epoc X Motion | Accelerometer | 10 (`Q0–Q3`, `Acc XYZ`, `Mag XYZ`) | `32` / `64` / `128` Hz |
| Epoc X eQuality | Raw | 14 (`qAF3..qAF4`, per-electrode Cortex CQ `0, 1, 2, 4`) | `128` or `256` Hz |

If outlet creation fails (e.g. missing native `liblsl`), LSL becomes **Degraded** and acquisition + CSV continue.

## Tests & Ground-Truth Verification

```bash
fvm flutter analyze
fvm flutter test
```

## Sessions tab & Live Dropbox / SMB / SFTP sync

While recording, the app incrementally pushes growing `eeg.csv`, `motion.csv`, `cq.csv`, and `raw.csv` (plus `session.json`) to configured Dropbox, SMB, and SFTP destinations without blocking BLE capture.

## Setup & Build

```bash
fvm use 3.47.9
fvm flutter pub get
./scripts/run_release.sh
```
