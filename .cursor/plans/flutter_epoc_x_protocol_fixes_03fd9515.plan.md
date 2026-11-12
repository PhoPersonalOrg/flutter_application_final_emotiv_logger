---
name: Flutter Epoc X protocol fixes
overview: Correct the Flutter Epoc X logger's EEG channel mapping, ADC scaling, and motion decoding to match the reverse-engineered Android protocol, and fold the newly verified facts into the RE spec docs.
todos:
  - id: eeg-order-scale
    content: "Fix decryptEeg in lib/decode/crypto_codec.dart: apply sample-index order [2,3,0,1,4,5,6,8,9,10,13,14,11,12] and scale by /1.95 (drop the *0.25)"
    status: completed
  - id: motion-be
    content: Fix decodeMotion to read big-endian int16 (Android convert_pkgs_motion); update crypto_codec_test and decode_pipeline_test fixtures to BE
    status: completed
  - id: connect-seq
    content: Remove spurious startCmd writes in acquisition_session._armNotifications; optionally write 02 1E to 5d1c1b02 when present
    status: completed
  - id: uuids
    content: Add service-B EEG UUID 5d1c1b04 alias and battery 0x2a19 to ble_uuids.dart and accept either EEG UUID in _armNotifications
    status: completed
  - id: newfw-todo
    content: Add documented decode-failure/TODO path for new-firmware AES-256/SHA (findKey) EEG; do not guess
    status: completed
  - id: spec-refresh
    content: Fold verified facts (channel map, ADC divisors, EpocPlus 32B layout, 20B BE motion, old/new crypto split, connect seq) into epocx-ble-protocol.md + epocx-ble-ghidra.md and the LSL-discrepancy table
    status: completed
  - id: validate
    content: Run flutter analyze + flutter test; verify EEG order/scale and BE motion
    status: completed
isProject: false
---

# Correct the Flutter Epoc X implementation against the Android protocol

All Android facts below are verified directly from `libEmbeddedLibQt.so` via objdump (not from `emotiv-lsl`). Android is the source of truth.

## What the Flutter app gets right (keep)
- Key derivation: `[crypto_codec.dart](lib/decode/crypto_codec.dart)` `deriveEpocXKeyFromSerial` reproduces Android `aesKeyVersion2_EpocXMode` (perm `[0,1,3,3,1,0,1,3,0,3,2,1,0,1,1,2]`, verified `tbl` vector at `0xc413a0`) given serial `s0=sn[15],s1=sn[14],s2=sn[13],s3=sn[12]`.
- EEG crypto shape for old firmware: XOR `0x55` + AES-128-ECB, no padding.
- Channel label set/order `AF3,F7,F3,FC5,T7,P7,O1,O2,P8,T8,FC6,F4,F8,AF4` in `[samples.dart](lib/domain/samples.dart)` matches `channel2StringDb`.
- Treating motion as unencrypted (old-fw pass-through) is correct.

## Bugs to fix

### 1. EEG channel order (wrong) — `[crypto_codec.dart](lib/decode/crypto_codec.dart)` `decryptEeg`
Android `getRawEegId` (`0x27bee10`, type 7) selects samples `[2,3,0,1,4,5,6,8,9,10,13,14,11,12]`, where `sample[k]` = LE uint16 at plaintext bytes `2+2k..3+2k` (15 samples in bytes 2..31; bytes 0-1 are counter+type).
- Current code returns `words[1..14]` = `sample[0..13]` in identity order. Replace with explicit index list:
  - `const eegOrder = [2,3,0,1,4,5,6,8,9,10,13,14,11,12];`
  - Build `sample[k]` for k=0..14 from `dec`, then output `[for i in eegOrder: sample[i] / 1.95]`.

### 2. EEG amplitude scale (4x too small) — same function
Android `convertADCToMicrovolt` divides by **1.95** (normal) or 7.8 (low gain). Current code does `* 0.5128 * 0.25` = `/7.8` (hardcoded low-gain). Change to `/1.95` (drop the `* 0.25`). Keep `multiplier = 1/1.95`; add a comment that 7.8 is the low-gain alternate (`[ExtractedPackage+0xb4]==0x10`).

### 3. Motion decoding (wrong endianness + wrong field count) — `[crypto_codec.dart](lib/decode/crypto_codec.dart)` `decodeMotion`
Android `convert_pkgs_motion` (`0x2804704`): 20-byte packet = counter byte + **big-endian** int16 fields at bytes 2,4,6,8,10,12,14,16,18 (`ldurh;rev;asr#16`). Current code reads little-endian and only 6 fields.
- Read BE int16: `(data[o]<<8)|data[o+1]`, sign-extend.
- Keep the 6 Acc/Gyro outputs the app already exposes (offsets 2..12), but as BE. Document that Android also carries 3 more int16 (likely magnetometer) and applies axis swap/negate (`correctMotionDirection` `0x280b2f4`: swap+negate on fields `0x168/0x16c/0x174/0x178/0x184/0x188`) plus device-specific divisors from `.bss 0x51df7e8` that could not be read statically — leave physical-unit scaling as the current `accScale`/`gyroScale` and mark the swap/divisors as a known approximation.
- Update `[crypto_codec_test.dart](test/crypto_codec_test.dart)` and `[decode_pipeline_test.dart](test/decode_pipeline_test.dart)`: the "AccX=1g" fixtures write bytes `[2]=0x00,[3]=0x40` (LE 16384); under BE that is `0x0040`. Rewrite fixtures to set the BE bytes for 16384 (`[2]=0x40,[3]=0x00`) so tests assert BE.

### 4. Spurious start-command writes — `[acquisition_session.dart](lib/acquisition/acquisition_session.dart)` `_armNotifications`
Android starts streaming via CCCD notify-enable only (no data-char write); it optionally writes `02 1E` to control char `5d1c1b02` when present. Remove the `eegChar.write(startCmd)` / `motionChar.write(startCmd)` block (lines ~317-326). Optionally (guarded) write `02 1E` to `5d1c1b02` if that characteristic is discovered.

### 5. Missing service-B / battery UUIDs — `[ble_uuids.dart](lib/domain/ble_uuids.dart)`
Android binds EEG to `81072f41…` **or** `5d1c1b04-863c-11e6-ae22-56b6b6499611`, motion to `81072f42…`, and battery to `0x2a19`. Add the service-B EEG UUID as an accepted alias in `_armNotifications` (match either), and add the battery UUID constant. Battery/CQ decode itself is out of scope for this pass (see Deferred).

## Deferred / documented-as-unknown (no code change now)
- New-firmware EEG path (version > `0x73e`): device-specific XOR byte + **AES-256**-ECB with SHA-256 `findKey()` key. Flutter only implements old-fw AES-128. Add a `TODO` + a clear decode-failure path; do not guess the SHA input.
- Contact quality (CQ) from EEG when `type==0x10`, and battery from `0x2a19` — enhancements, not correctness fixes.

## Spec refresh (RE repo) — satisfies the existing `spec-refresh` / `channels-verify` / `pkg-bit-layouts` / `motion-layout` todos
Update `.specify/memory/epocx-ble-protocol.md` and `EXTERNAL/ANDROID/.../notes/epocx-ble-ghidra.md` with the now-verified: full `Channel_t` enum→name table, EEG sample-index map `[2,3,0,1,4,5,6,8,9,10,13,14,11,12]`, ADC divisors 1.95/7.8, EpocPlus-mode 32-byte layout (counter, `type=byte1&0x7f`, 15 LE uint16), 20-byte BE motion layout, old-vs-new firmware crypto split (AES-128 perm key vs AES-256 SHA key), and the `02 1E`/CCCD connect sequence. Refresh the LSL-discrepancy table. Do not edit the plan files.

## Validation
- `flutter analyze` and `flutter test` (updated crypto/motion/pipeline tests).
- Re-decode a captured 32-byte EEG packet (if available) and confirm channel order + amplitude against an EmotivPRO reference; otherwise rely on unit tests for ordering/scaling and BE motion.