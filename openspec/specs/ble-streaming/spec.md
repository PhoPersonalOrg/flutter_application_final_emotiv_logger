# Emotiv Epoc Bluetooth LE Streaming Specification

## Overview

This specification defines the complete Bluetooth LE communication protocol for Emotiv Epoc family headsets (Epoc+ and Epoc X). It covers device discovery, connection, GATT service interaction, data decryption, and decoding.

## Documentation Structure

This specification consists of three complementary documents:

1. **spec.md** (this file) - High-level overview and quick reference
2. **bluetooth-protocol.md** - Complete technical specification with implementation details
3. **requirements.md** - Structured EARS-compliant requirements for validation

## Quick Reference

### GATT Service UUIDs

- **Control Service:** `81072F40-9F3D-11E3-A9DC-0002A5D5C51B`
- **EEG Data Characteristic:** `81072F41-9F3D-11E3-A9DC-0002A5D5C51B`
- **Motion Data Characteristic:** `81072F42-9F3D-11E3-A9DC-0002A5D5C51B`

### Key Protocol Differences from USB

| Feature | USB HID | Bluetooth LE |
|---------|---------|--------------|
| **Serial Number** | USB descriptor | Derived from advertised name |
| **Data Delivery** | Blocking read | Notification callback |
| **Packet ID** | byte[1] value | Characteristic UUID |
| **EEG Encryption** | Yes (XOR + AES) | Yes (XOR + AES) |
| **Motion Encryption** | Yes (XOR + AES) | **No (plaintext)** |

### Critical Implementation Notes

1. **Motion data is NOT encrypted** over BLE (unlike USB)
2. Serial number is derived from advertised device name, not USB descriptor
3. BLE key format: 8-character hex in device name (e.g., "EPOCX (E50202E9)")
4. Start command: `[0x00, 0x01, 0x00, 0x00]` sent to both characteristics
5. **Sample rates are user-configurable:** Default 128 Hz (EEG), 16 Hz (motion)
6. Configured rates are used for metadata only - process notifications as they arrive

## High-Level Requirements

### Requirement: BLE Streaming for Emotiv Epoc X/Plus

The app SHALL connect to Emotiv Epoc X/Plus headsets over BLE, decode EEG and MEMS payloads, and publish LSL streams.

#### Scenario: Discover and connect over BLE
- WHEN the user scans for headsets
- THEN the app SHALL list available devices advertising the Emotiv control service `81072F40-9F3D-11E3-A9DC-0002A5D5C51B`
- AND the user SHALL be able to initiate a connection
- AND the app SHALL extract the BLE key from the device name pattern "(XXXXXXXX)"

#### Scenario: Derive encryption key from BLE key
- WHEN connected to a device
- THEN the app SHALL extract the 8-character hex key from the device name
- AND the app SHALL create a 16-byte serial number (12 zeros + 4 reversed key bytes)
- AND the app SHALL derive the 16-byte AES key using Epoc X key mapping

#### Scenario: Start notifications for EEG and MEMS
- WHEN connected
- THEN the app SHALL enable notifications for EEG `81072F41-...` and MEMS `81072F42-...`
- AND the app SHALL send the start command `[0x00, 0x01, 0x00, 0x00]` to begin streaming

#### Scenario: EEG decode XOR+AES
- WHEN an EEG notification is received (UUID 0x41)
- THEN the app SHALL XOR each byte with 0x55
- AND the app SHALL AES-ECB decrypt in 16-byte blocks with the derived key
- AND the app SHALL extract 14 EEG channels from word indices 1-14
- AND the app SHALL scale values: (word * 0.5128205128205129) * 0.25
- AND the nominal sample rate SHALL be 128 Hz

#### Scenario: MEMS decode IMU (no encryption)
- WHEN a MEMS notification is received (UUID 0x42)
- THEN the app SHALL parse 6-axis IMU (Acc, Gyro) from plaintext bytes
- AND the app SHALL read signed int16 values at offsets 2, 4, 6, 8, 10, 12
- AND the app SHALL scale accelerometer by 1/16384.0 (g units)
- AND the app SHALL scale gyroscope by 1/131.0 (deg/s units)
- AND the nominal sample rate SHALL be ~16 Hz

#### Scenario: Publish LSL streams
- WHEN decoded EEG samples are available
- THEN the app SHALL publish to an LSL stream named `Epoc X` (type `EEG`, 14 channels, 128 Hz)
- AND WHEN decoded motion samples are available
- THEN the app SHALL publish to an LSL stream named `Epoc X Motion` (type `Accelerometer`, 6 channels, ~16 Hz)

#### Scenario: Close resources on disconnect
- WHEN the headset disconnects
- THEN the app SHALL close EEG and Motion LSL outlets and stop file logging
- AND the app SHALL clear stored characteristics and encryption keys

## Implementation Guidance

For complete implementation details including:
- Pseudocode algorithms
- Platform-specific code examples (Flutter, iOS, Android, Windows)
- Byte-level packet structures
- Troubleshooting guides
- Validation test cases

**See:** `bluetooth-protocol.md` in this directory

For structured requirements and acceptance criteria:

**See:** `requirements.md` in this directory

## Validation Status

This specification has been validated against:
- Flutter BLE implementation (flutter_blue_plus)
- Working Epoc X BLE connection
- Successful EEG and motion data decoding
- LSL stream publishing
- File logging functionality

## Known Limitations

1. BLE range limited to ~10-30 meters
2. Higher latency than USB (7.5-30ms connection interval)
3. Susceptible to 2.4 GHz interference
4. Platform-specific permission requirements
5. Battery drain higher than USB mode

## References

- Flutter implementation: `lib/emotiv_ble_manager.dart`
- Crypto utilities: `lib/crypto_utils.dart`
- USB protocol comparison: See USB protocol specification documents


