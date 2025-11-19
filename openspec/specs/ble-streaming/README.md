# Emotiv Epoc Bluetooth LE Specification

This directory contains a comprehensive, platform-independent specification for communicating with Emotiv Epoc family headsets over Bluetooth Low Energy (BLE).

## Documents

### spec.md
**High-Level Overview** - Quick reference containing:
- GATT service and characteristic UUIDs
- Key protocol differences from USB
- High-level requirements and scenarios
- Implementation guidance pointers

**Use this document to:** Get a quick overview and understand the main differences from USB

### bluetooth-protocol.md
**Complete Technical Specification** - The main document containing:
- Detailed BLE vs USB comparison
- GATT service discovery procedures
- Serial number derivation from BLE advertised name
- Encryption key derivation algorithms
- EEG packet decryption (XOR + AES)
- Motion packet parsing (plaintext, no encryption)
- Complete pseudocode implementations
- Platform-specific code examples (Flutter, iOS, Android, Windows)
- Troubleshooting guide
- Validation test cases

**Use this document to:** Build a new BLE client implementation in any language/platform

### requirements.md
**Structured Requirements** - EARS-compliant requirements with:
- User stories and acceptance criteria
- Testable specifications for all BLE operations
- Clear success criteria for validation

**Use this document to:** Validate implementation completeness and correctness

## Critical BLE vs USB Differences

### 1. Serial Number Source
- **USB:** Read from USB device descriptor
- **BLE:** Derived from advertised device name (e.g., "EPOCX (E50202E9)")

### 2. Data Delivery
- **USB:** Synchronous blocking read() calls
- **BLE:** Asynchronous notification callbacks

### 3. Packet Type Identification
- **USB:** Check byte[1] value (32 = motion, else EEG)
- **BLE:** Determined by characteristic UUID (0x41 = EEG, 0x42 = motion)

### 4. Motion Data Encryption
- **USB:** Encrypted with XOR + AES
- **BLE:** **NOT encrypted** (plaintext)

### 5. Connection Method
- **USB:** Plug-and-play automatic
- **BLE:** Manual scanning, pairing, and connection

## Quick Start

To implement a new Emotiv BLE client:

1. Read **spec.md** for overview and key differences
2. Read **bluetooth-protocol.md** sections 1-5 for basic communication
3. Implement device discovery (section 3)
4. Implement BLE key extraction and serial number derivation (section 8)
5. Implement encryption key derivation (section 8)
6. Implement GATT service discovery (section 4)
7. Implement EEG decryption (section 7)
8. Implement motion parsing - NO decryption (section 10)
9. Validate against test cases (section 14)

## Supported Models

| Model | Name Pattern | Motion Data | Status |
|-------|--------------|-------------|--------|
| Epoc+ | `EPOC+ (XXXXXXXX)` | No | Documented |
| Epoc X | `EPOCX (XXXXXXXX)` | Yes | Fully validated |

## GATT UUIDs Reference

```
Control Service:  81072F40-9F3D-11E3-A9DC-0002A5D5C51B
EEG Data:         81072F41-9F3D-11E3-A9DC-0002A5D5C51B
Motion Data:      81072F42-9F3D-11E3-A9DC-0002A5D5C51B
```

## Key Algorithms

### BLE Key Extraction
```
Input: "EPOCX (E50202E9)"
Extract: "E50202E9"
```

### Serial Number Derivation
```
Input: "E50202E9"
Reversed: "E902 02E5"
Serial: [0x00 × 12, 0xE9, 0x02, 0x02, 0xE5]
```

### Encryption Key Derivation
```
key = [sn[15], sn[14], sn[12], sn[12],
       sn[14], sn[15], sn[14], sn[12],
       sn[15], sn[12], sn[13], sn[14],
       sn[15], sn[14], sn[14], sn[13]]
```

### EEG Decryption
```
1. XOR each byte with 0x55
2. AES-ECB decrypt in 16-byte blocks
3. Extract 16-bit words (little-endian)
4. Map indices 1-14 to channels
5. Scale: (word * 0.5128205128205129) * 0.25
```

### Motion Parsing (No Decryption!)
```
1. Read int16 values at offsets 2, 4, 6, 8, 10, 12
2. Scale accelerometer: value / 16384.0
3. Scale gyroscope: value / 131.0
```

## Validation Status

This specification has been validated against:

✅ **Flutter BLE Implementation**
- Library: flutter_blue_plus
- Device: Epoc X
- Status: Working EEG and motion data

✅ **Key Derivation**
- BLE key extraction from device name
- Serial number creation (16 bytes)
- Encryption key derivation (matches USB Epoc X)

✅ **EEG Decryption**
- XOR preprocessing with 0x55
- AES-ECB decryption
- 14-channel extraction and scaling

✅ **Motion Parsing**
- Plaintext parsing (no decryption)
- 6-axis IMU data extraction
- Correct scaling factors

✅ **Data Streaming**
- LSL stream publishing
- CSV file logging
- Sample rates documented (~128 Hz EEG, ~16-32 Hz motion varies by firmware)

## 🔍 Critical Findings

### 1. Motion Data NOT Encrypted
**Most important difference from USB:** Motion data over BLE is transmitted in plaintext. Do not apply decryption to motion packets.

### 2. Configurable Sample Rates
**User-configurable with defaults:** 
- **EEG:** Default 128 Hz (standard for Emotiv devices)
- **Motion:** Default 16 Hz (may be 16, 32, or other Hz depending on firmware)
- **Implementation:** Make sample rates configurable - users can override defaults if their firmware uses different rates
- **Usage:** Configured rates are used for LSL metadata and file headers, not for enforcing timing

### 3. Serial Number from Device Name
**BLE-specific:** Serial number is derived from the 8-character hex value in the advertised device name (e.g., "EPOCX (E50202E9)"), not from a USB descriptor.

## Platform Support

### Tested Platforms
- ✅ Flutter (Android/iOS) - Primary reference implementation
- ✅ iOS (CoreBluetooth) - Code examples provided
- ✅ Android (Bluetooth LE API) - Code examples provided

### Documented Platforms
- 📝 Windows (WinRT Bluetooth LE) - Code examples provided
- 📝 Linux (BlueZ) - General guidance provided
- 📝 macOS (CoreBluetooth) - Similar to iOS

## Known Issues and Limitations

### BLE-Specific Limitations
1. **Range:** Limited to ~10-30 meters (vs unlimited for USB)
2. **Latency:** 7.5-30ms connection interval (vs <1ms for USB)
3. **Reliability:** More prone to packet loss than USB
4. **Battery:** Headset battery drains faster than USB mode
5. **Interference:** Susceptible to 2.4 GHz interference (WiFi, microwaves)

### Platform-Specific Issues
- **iOS:** Requires Bluetooth permissions in Info.plist
- **Android:** Requires location permissions for BLE scanning (Android 6+)
- **Windows:** BLE support varies by Bluetooth adapter
- **All:** May require pairing/bonding before connection

### Implementation Notes
- Motion data may arrive before start command is sent
- Packet sizes may vary (20-32 bytes) due to MTU negotiation
- Connection drops may occur randomly - implement reconnection logic

## Troubleshooting

### "No devices found"
- Verify headset is powered on
- Check Bluetooth is enabled
- Ensure headset not connected to another device
- Check platform-specific permissions

### "EEG data is garbage"
- Verify BLE key extraction is correct
- Check serial number derivation (should be 16 bytes)
- Verify encryption key derivation
- Ensure XOR 0x55 is applied before AES

### "Motion data is all zeros"
- Verify motion characteristic is found
- Check notifications are enabled
- Ensure headset is moving
- **Verify no decryption is applied** (motion is plaintext)

## Contributing

If you find discrepancies or have additional validation data, please document:
- Model and firmware version
- Platform and BLE library used
- Specific byte values and expected vs actual results
- BLE adapter information

## References

### Implementation Files
- `lib/emotiv_ble_manager.dart` - Flutter BLE manager
- `lib/crypto_utils.dart` - Encryption and decoding utilities
- `lib/eeg_file_writer.dart` - EEG data logging
- `lib/motion_file_writer.dart` - Motion data logging

### Related Specifications
- USB HID protocol specification (separate document)
- LSL stream format specification
- Emotiv SDK documentation (official, if available)

## License and Usage

This specification document is provided for educational and development purposes. It is derived from analysis of working implementations and publicly available information.

**Disclaimer:** This is a reverse-engineered specification. Emotiv Systems Inc. has not officially endorsed or validated this document. Use at your own risk.

---

**Last Updated:** 2025  
**Version:** 1.0  
**Status:** Complete and Validated
