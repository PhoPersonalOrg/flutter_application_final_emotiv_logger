# Emotiv Epoc Bluetooth LE Protocol Specification

## Document Information

**Version:** 1.0  
**Date:** 2025  
**Status:** Complete Technical Specification  
**Purpose:** Platform-independent specification for Bluetooth LE communication with Emotiv Epoc headsets

## Executive Summary

This document specifies the Bluetooth Low Energy (BLE) communication protocol for Emotiv Epoc family headsets (Epoc+ and Epoc X). Unlike USB HID communication, BLE uses GATT (Generic Attribute Profile) services and characteristics for data transmission. This specification is derived from analysis of the Flutter BLE reference implementation and validated against working BLE implementations.

**Critical Difference:** BLE protocol differs significantly from USB HID in connection method, packet structure, data flow, and encryption handling.

## Table of Contents

1. BLE vs USB Protocol Differences
2. GATT Service and Characteristic UUIDs
3. Device Discovery and Connection
4. GATT Service Discovery
5. Data Stream Initialization
6. Data Reception and Decoding
7. Encryption and Decryption (BLE-Specific)
8. Serial Number Derivation (BLE-Specific)
9. EEG Data Decoding (BLE)
10. Motion Data Decoding (BLE)
11. Platform-Specific Implementation
12. Known Limitations and Issues

---

## 1. BLE vs USB Protocol Differences

### Communication Method Comparison

| Aspect | USB HID | Bluetooth LE |
|--------|---------|--------------|
| **Transport** | USB cable | Wireless (2.4 GHz) |
| **Protocol** | HID over USB | GATT over BLE |
| **Connection** | Plug-and-play | Pairing + connection |
| **Discovery** | USB enumeration | BLE scanning |
| **Data Flow** | Blocking read() | Notification callbacks |
| **Packet Size** | Fixed 32 bytes | Variable (typically 20-32 bytes) |
| **Serial Number** | USB descriptor field | Derived from advertised name |
| **Encryption Key** | Derived from USB serial | Derived from BLE advertised key |
| **XOR Preprocessing** | Applied to all 32 bytes | Applied to all bytes |
| **Decryption** | AES-ECB on full packet | AES-ECB on 16-byte blocks |
| **EEG Packet ID** | byte[1] != 32 | Characteristic UUID 0x41 |
| **Motion Packet ID** | byte[1] == 32 | Characteristic UUID 0x42 |
| **Motion Encryption** | Encrypted | **NOT encrypted** |

### Key Architectural Differences

**USB HID:**
- Single data stream with packet type identification
- Synchronous blocking reads
- All packets encrypted (EEG and motion)
- Serial number from USB descriptor

**Bluetooth LE:**
- Separate GATT characteristics for EEG and motion
- Asynchronous notification-based
- **Only EEG packets encrypted, motion packets are plaintext**
- Serial number derived from advertised device name

---

## 2. GATT Service and Characteristic UUIDs

### Primary Service UUID

**Emotiv Control Service:**
```
UUID: 81072F40-9F3D-11E3-A9DC-0002A5D5C51B
```

This service is advertised and used for device discovery.

### Data Characteristic UUIDs

| Characteristic | UUID | Purpose | Encryption | Sample Rate |
|----------------|------|---------|------------|-------------|
| **EEG Data** | `81072F41-9F3D-11E3-A9DC-0002A5D5C51B` | 14-channel EEG | **Yes** (XOR + AES) | ~128 Hz |
| **Motion Data** | `81072F42-9F3D-11E3-A9DC-0002A5D5C51B` | 6-axis IMU | **No** | ~16-32 Hz* |

**Note:** Motion sample rate varies by firmware version and may be 16 Hz, 32 Hz, or other rates. The rate is determined by how frequently the headset sends motion notifications.

### Characteristic Properties

Both data characteristics support:
- **Read:** No (data only via notifications)
- **Write:** Yes (for start/stop commands)
- **Notify:** Yes (primary data delivery method)
- **Indicate:** No

---

## 3. Device Discovery and Connection

### Discovery Algorithm

```
FUNCTION discover_emotiv_devices():
    // Start BLE scan with service filter
    START_BLE_SCAN(
        service_uuids: ["81072F40-9F3D-11E3-A9DC-0002A5D5C51B"],
        timeout: 30 seconds
    )
    
    discovered_devices = []
    
    FOR EACH scan_result IN scan_results:
        device_name = scan_result.device.platform_name
        
        // Filter for Emotiv devices
        IF device_name MATCHES "EPOC" OR device_name MATCHES "Emotiv":
            discovered_devices.ADD(scan_result.device)
            LOG("Found: " + device_name)
        END IF
    END FOR
    
    RETURN discovered_devices
END FUNCTION
```

### Device Name Patterns

Emotiv devices advertise with specific name patterns:

| Model | Name Pattern | Example |
|-------|--------------|---------|
| Epoc X | `EPOCX (XXXXXXXX)` | `EPOCX (E50202E9)` |
| Epoc+ | `EPOC+ (XXXXXXXX)` | `EPOC+ (3B9ACCA6)` |

**Critical:** The 8-character hex value in parentheses is the **BLE key** used for serial number derivation.

### Connection Procedure

```
FUNCTION connect_to_device(device):
    TRY:
        // Connect with timeout
        AWAIT device.connect(timeout: 15 seconds)
        
        // Extract BLE key from device name
        ble_key = EXTRACT_HEX_FROM_NAME(device.platform_name)
        
        // Derive serial number and encryption key
        serial_number = CREATE_SERIAL_NUMBER(ble_key)
        encryption_key = DERIVE_EPOC_X_KEY(serial_number)
        
        // Store for later use
        STORE(encryption_key)
        
        // Discover services
        AWAIT discover_services(device)
        
        RETURN SUCCESS
        
    CATCH connection_error:
        LOG_ERROR("Connection failed: " + connection_error)
        RETURN FAILURE
    END TRY
END FUNCTION
```

---

## 4. GATT Service Discovery

### Service Discovery Algorithm

```
FUNCTION discover_services(device):
    services = AWAIT device.discover_services()
    
    FOR EACH service IN services:
        LOG("Service: " + service.uuid)
        
        FOR EACH characteristic IN service.characteristics:
            uuid = characteristic.uuid.to_upper()
            
            IF uuid == "81072F41-9F3D-11E3-A9DC-0002A5D5C51B":
                eeg_characteristic = characteristic
                AWAIT setup_eeg_characteristic(characteristic)
                
            ELSE IF uuid == "81072F42-9F3D-11E3-A9DC-0002A5D5C51B":
                motion_characteristic = characteristic
                AWAIT setup_motion_characteristic(characteristic)
            END IF
        END FOR
    END FOR
    
    // Enable data streaming
    AWAIT enable_data_streams()
END FUNCTION
```

### Characteristic Setup

```
FUNCTION setup_eeg_characteristic(characteristic):
    // Enable notifications
    AWAIT characteristic.set_notify_value(TRUE)
    
    // Register callback for data
    characteristic.on_value_changed(CALLBACK: process_eeg_data)
    
    LOG("EEG characteristic configured")
END FUNCTION

FUNCTION setup_motion_characteristic(characteristic):
    // Enable notifications
    AWAIT characteristic.set_notify_value(TRUE)
    
    // Register callback for data
    characteristic.on_value_changed(CALLBACK: process_motion_data)
    
    LOG("Motion characteristic configured")
END FUNCTION
```

---

## 5. Data Stream Initialization

### Start Command Protocol

After enabling notifications, send start commands to begin data streaming:

```
FUNCTION enable_data_streams():
    // Start command: 0x0100 in little-endian format
    start_command = [0x00, 0x01, 0x00, 0x00]
    
    // Send to EEG characteristic
    IF eeg_characteristic EXISTS:
        AWAIT eeg_characteristic.write(start_command, without_response: FALSE)
        LOG("EEG stream started")
    END IF
    
    // Send to Motion characteristic
    IF motion_characteristic EXISTS:
        AWAIT motion_characteristic.write(start_command, without_response: FALSE)
        LOG("Motion stream started")
    END IF
END FUNCTION
```

### Command Structure

| Byte | Value | Description |
|------|-------|-------------|
| 0 | 0x00 | Command low byte |
| 1 | 0x01 | Command high byte (0x0100 = start) |
| 2 | 0x00 | Reserved |
| 3 | 0x00 | Reserved |

**Alternative Commands:**
- `0x0100` (256 decimal): Start streaming
- `0x0000` (0 decimal): Stop streaming (if supported)

---

## 6. Data Reception and Decoding

### Notification Callback Pattern

```
FUNCTION on_eeg_notification(data):
    IF data.length > 0:
        process_eeg_data(data)
    END IF
END FUNCTION

FUNCTION on_motion_notification(data):
    IF data.length > 0:
        process_motion_data(data)
    END IF
END FUNCTION
```

### Data Flow Architecture

```
BLE Device
    ↓
[EEG Characteristic 0x41] → Notification (~128 Hz) → Decrypt → Decode → 14 EEG channels
    ↓
[Motion Characteristic 0x42] → Notification (~16-32 Hz) → Parse → 6 IMU channels
```

**Key Difference from USB:** No packet type identification needed - the characteristic UUID determines the data type.

### Sample Rate Handling

**EEG Data:**
- Nominal rate: 128 Hz
- Actual rate: Determined by notification frequency from headset
- Consistent across firmware versions

**Motion Data:**
- Nominal rate: 16-32 Hz (varies by firmware)
- Actual rate: Determined by notification frequency from headset
- May be 16 Hz, 32 Hz, or other rates depending on headset model and firmware
- **Important:** Do not assume a fixed rate - measure actual notification timing

**Implementation Note:** The application should not enforce artificial timing. Process notifications as they arrive and let the headset determine the actual sample rate. Use timestamps for precise timing analysis.

---

## 7. Encryption and Decryption (BLE-Specific)

### Critical Encryption Differences

**EEG Data (0x41):**
- **Encrypted:** Yes
- **Method:** XOR 0x55 + AES-ECB
- **Key:** 16 bytes derived from BLE advertised key

**Motion Data (0x42):**
- **Encrypted:** No
- **Method:** Direct parsing of plaintext bytes
- **Key:** Not applicable

### EEG Decryption Algorithm

```
FUNCTION decrypt_eeg_ble(encrypted_data, encryption_key):
    // Step 1: XOR preprocessing with 0x55
    xored_data = BYTEARRAY(encrypted_data.length)
    FOR i = 0 TO encrypted_data.length - 1:
        xored_data[i] = encrypted_data[i] XOR 0x55
    END FOR
    
    // Step 2: AES-ECB decryption in 16-byte blocks
    cipher = AES_ECB(encryption_key)
    decrypted_blocks = []
    
    FOR offset = 0 TO xored_data.length STEP 16:
        IF offset + 16 <= xored_data.length:
            block = xored_data[offset : offset + 16]
            decrypted_block = cipher.decrypt(block)
            decrypted_blocks.APPEND(decrypted_block)
        END IF
    END FOR
    
    // Step 3: Concatenate all decrypted blocks
    decrypted_data = CONCATENATE(decrypted_blocks)
    
    RETURN decrypted_data
END FUNCTION
```

**Critical:** The XOR operation with 0x55 is applied to **every byte** before AES decryption, just like USB Epoc X.

---

## 8. Serial Number Derivation (BLE-Specific)

### BLE Key Extraction

Extract the 8-character hex key from the advertised device name:

```
FUNCTION extract_ble_key(device_name):
    // Example: "EPOCX (E50202E9)" → "E50202E9"
    pattern = REGEX("\(([A-F0-9]{8})\)")
    match = pattern.find(device_name)
    
    IF match:
        RETURN match.group(1)
    ELSE:
        RAISE Exception("Invalid device name format")
    END IF
END FUNCTION
```

### Serial Number Creation

```
FUNCTION create_serial_number(ble_key):
    // Create 16-byte serial number:
    // - First 12 bytes: zeros
    // - Last 4 bytes: BLE key in reversed byte order
    
    serial_number = BYTEARRAY(16)
    
    // Fill first 12 bytes with zeros
    FOR i = 0 TO 11:
        serial_number[i] = 0x00
    END FOR
    
    // Parse BLE key in reversed byte order
    // Example: "E50202E9" → bytes [E9, 02, 02, E5]
    reversed_key = ble_key[6:8] + ble_key[4:6] + ble_key[2:4] + ble_key[0:2]
    
    // Convert hex string to bytes
    FOR i = 0 TO 3:
        hex_pair = reversed_key[i*2 : i*2+2]
        serial_number[12 + i] = PARSE_HEX(hex_pair)
    END FOR
    
    RETURN serial_number
END FUNCTION
```

**Example:**
- Input: `"E50202E9"`
- Reversed: `"E902 02E5"` → `[0xE9, 0x02, 0x02, 0xE5]`
- Serial: `[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xE9, 0x02, 0x02, 0xE5]`

### Encryption Key Derivation

```
FUNCTION derive_epoc_x_key(serial_number):
    // Epoc X key derivation (same as USB)
    // Extract specific positions from 16-byte serial
    
    sn = serial_number
    key = BYTEARRAY([
        sn[15], sn[14], sn[12], sn[12],
        sn[14], sn[15], sn[14], sn[12],
        sn[15], sn[12], sn[13], sn[14],
        sn[15], sn[14], sn[14], sn[13]
    ])
    
    RETURN key  // 16-byte AES key
END FUNCTION
```

**Critical:** The key derivation is identical to USB Epoc X, but the serial number source is different.

---

## 9. EEG Data Decoding (BLE)

### Complete EEG Processing Pipeline

```
FUNCTION process_eeg_data(encrypted_data):
    // Step 1: Decrypt
    decrypted_data = decrypt_eeg_ble(encrypted_data, encryption_key)
    
    IF decrypted_data.length < 32:
        LOG_WARNING("Insufficient decrypted data")
        RETURN []
    END IF
    
    // Step 2: Extract 16-bit words (little-endian)
    words = []
    FOR i = 0 TO decrypted_data.length - 1 STEP 2:
        IF i + 1 < decrypted_data.length AND words.length < 16:
            word = (decrypted_data[i+1] << 8) | decrypted_data[i]
            words.APPEND(word)
        END IF
    END FOR
    
    // Step 3: Map to 14 EEG channels (skip indices 0 and 15)
    eeg_channels = [
        words[1],   // AF3
        words[2],   // F7
        words[3],   // F3
        words[4],   // FC5
        words[5],   // T7
        words[6],   // P7
        words[7],   // O1
        words[8],   // O2
        words[9],   // P8
        words[10],  // T8
        words[11],  // FC6
        words[12],  // F4
        words[13],  // F8
        words[14]   // AF4
    ]
    
    // Step 4: Scale to microvolts
    multiplier = 0.5128205128205129
    scale_factor = 0.25
    
    eeg_values = []
    FOR EACH word IN eeg_channels:
        value_uv = (word * multiplier) * scale_factor
        eeg_values.APPEND(value_uv)
    END FOR
    
    RETURN eeg_values  // 14 float values in µV
END FUNCTION
```

### Scaling Formula

```
microvolts = (raw_word * 0.5128205128205129) * 0.25
```

**Note:** This differs slightly from USB scaling but produces comparable results.

---

## 10. Motion Data Decoding (BLE)

### Critical Difference: No Encryption

**Motion packets from BLE are NOT encrypted.** This is the most significant difference from USB.

### Motion Data Structure

```
Byte Index | Content
-----------|----------
0-1        | Header (counter/flags)
2-3        | AccX (int16, little-endian)
4-5        | AccY (int16, little-endian)
6-7        | AccZ (int16, little-endian)
8-9        | GyroX (int16, little-endian)
10-11      | GyroY (int16, little-endian)
12-13      | GyroZ (int16, little-endian)
14-31      | Reserved/padding
```

### Motion Decoding Algorithm

```
FUNCTION process_motion_data(raw_data):
    IF raw_data.length < 14:
        LOG_WARNING("Insufficient motion data")
        RETURN [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    END IF
    
    // Helper function to read signed 16-bit little-endian
    FUNCTION read_int16_le(data, offset):
        value = data[offset] | (data[offset + 1] << 8)
        // Convert to signed
        IF value >= 0x8000:
            value = value - 0x10000
        END IF
        RETURN value
    END FUNCTION
    
    // Read raw IMU values (skip 2-byte header)
    acc_x_raw = read_int16_le(raw_data, 2)
    acc_y_raw = read_int16_le(raw_data, 4)
    acc_z_raw = read_int16_le(raw_data, 6)
    gyro_x_raw = read_int16_le(raw_data, 8)
    gyro_y_raw = read_int16_le(raw_data, 10)
    gyro_z_raw = read_int16_le(raw_data, 12)
    
    // Scale factors
    acc_scale = 1.0 / 16384.0   // ±2g range
    gyro_scale = 1.0 / 131.0    // ±250 deg/s range
    
    // Apply scaling
    motion_values = [
        acc_x_raw * acc_scale,   // g
        acc_y_raw * acc_scale,   // g
        acc_z_raw * acc_scale,   // g
        gyro_x_raw * gyro_scale, // deg/s
        gyro_y_raw * gyro_scale, // deg/s
        gyro_z_raw * gyro_scale  // deg/s
    ]
    
    RETURN motion_values
END FUNCTION
```

### IMU Specifications

| Sensor | Range | Resolution | Scale Factor |
|--------|-------|------------|--------------|
| Accelerometer | ±2g | 16384 LSB/g | 1/16384.0 |
| Gyroscope | ±250 deg/s | 131 LSB/(deg/s) | 1/131.0 |

**IMU Chip:** ICM-20948 (same as USB)

---

## 11. Platform-Specific Implementation

### Flutter/Dart Implementation

**BLE Library:** `flutter_blue_plus`

```dart
// Device discovery
await FlutterBluePlus.startScan(
  withServices: [Guid("81072F40-9F3D-11E3-A9DC-0002A5D5C51B")],
  timeout: Duration(seconds: 30)
);

// Connection
await device.connect(timeout: Duration(seconds: 15));

// Service discovery
List<BluetoothService> services = await device.discoverServices();

// Enable notifications
await characteristic.setNotifyValue(true);

// Listen for data
characteristic.lastValueStream.listen((data) {
  processData(Uint8List.fromList(data));
});

// Send start command
await characteristic.write([0x00, 0x01, 0x00, 0x00], withoutResponse: false);
```

### iOS/Swift Implementation

**Framework:** CoreBluetooth

```swift
// Scan for devices
centralManager.scanForPeripherals(
  withServices: [CBUUID(string: "81072F40-9F3D-11E3-A9DC-0002A5D5C51B")]
)

// Connect
centralManager.connect(peripheral, options: nil)

// Discover services
peripheral.discoverServices([CBUUID(string: "81072F40-9F3D-11E3-A9DC-0002A5D5C51B")])

// Enable notifications
peripheral.setNotifyValue(true, for: characteristic)

// Send start command
let startCommand = Data([0x00, 0x01, 0x00, 0x00])
peripheral.writeValue(startCommand, for: characteristic, type: .withResponse)
```

### Android/Kotlin Implementation

**API:** Android Bluetooth LE

```kotlin
// Scan for devices
bluetoothLeScanner.startScan(
  listOf(ScanFilter.Builder()
    .setServiceUuid(ParcelUuid.fromString("81072F40-9F3D-11E3-A9DC-0002A5D5C51B"))
    .build()),
  scanSettings,
  scanCallback
)

// Connect
bluetoothGatt = device.connectGatt(context, false, gattCallback)

// Discover services
bluetoothGatt.discoverServices()

// Enable notifications
bluetoothGatt.setCharacteristicNotification(characteristic, true)
val descriptor = characteristic.getDescriptor(UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"))
descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
bluetoothGatt.writeDescriptor(descriptor)

// Send start command
characteristic.value = byteArrayOf(0x00, 0x01, 0x00, 0x00)
bluetoothGatt.writeCharacteristic(characteristic)
```

---

## 12. Sample Rate Configuration

### Configurable Sample Rates

**Implementation Approach:** Sample rates should be **user-configurable** with sensible defaults. The application should allow users to specify the expected sample rates for LSL stream metadata and file headers.

### Default Sample Rates

| Stream | Default Rate | Configurable | Notes |
|--------|--------------|--------------|-------|
| **EEG** | 128 Hz | Yes | Standard rate for Emotiv Epoc devices |
| **Motion** | 16 Hz | Yes | May vary by firmware (16-32 Hz typical) |

### Configuration Parameters

```
STRUCTURE SampleRateConfig:
    eeg_sample_rate: FLOAT = 128.0      // Default: 128 Hz
    motion_sample_rate: FLOAT = 16.0    // Default: 16 Hz
END STRUCTURE
```

### Implementation Pattern

```
FUNCTION initialize_streams(config: SampleRateConfig):
    // Create EEG stream with user-specified rate
    eeg_stream = create_lsl_stream(
        name: "Epoc X",
        type: "EEG",
        channels: 14,
        sample_rate: config.eeg_sample_rate  // User-configurable
    )
    
    // Create Motion stream with user-specified rate
    motion_stream = create_lsl_stream(
        name: "Epoc X Motion",
        type: "Accelerometer",
        channels: 6,
        sample_rate: config.motion_sample_rate  // User-configurable
    )
    
    LOG("EEG stream configured at " + config.eeg_sample_rate + " Hz")
    LOG("Motion stream configured at " + config.motion_sample_rate + " Hz")
    
    RETURN (eeg_stream, motion_stream)
END FUNCTION
```

### Configuration Options

**Option 1: Configuration File**
```json
{
  "sample_rates": {
    "eeg_hz": 128.0,
    "motion_hz": 16.0
  }
}
```

**Option 2: Command Line Arguments**
```bash
./emotiv_client --eeg-rate 128 --motion-rate 16
```

**Option 3: UI Settings**
```
Settings Panel:
  EEG Sample Rate: [128] Hz
  Motion Sample Rate: [16] Hz
  [Apply] [Reset to Defaults]
```

### Why User-Configurable?

1. **Firmware Variations:** Different firmware versions may use different rates
2. **Model Differences:** Epoc+ vs Epoc X may have different rates
3. **User Knowledge:** User may know their specific headset's actual rate
4. **LSL Metadata:** Downstream tools use this metadata for analysis
5. **File Headers:** CSV files should document the expected rate

### Handling Actual vs Configured Rates

**Important:** The configured rate is used for **metadata only**. The application should:

1. **Process notifications as they arrive** - no artificial throttling
2. **Timestamp every sample** - record precise arrival time
3. **Use configured rate for LSL metadata** - tells downstream tools what to expect
4. **Let LSL handle timing** - LSL supports irregular sample timing

**Example:**
```
// User configures motion rate as 16 Hz
config.motion_sample_rate = 16.0

// Create LSL stream with this metadata
motion_stream = create_lsl_stream("Epoc X Motion", sample_rate: 16.0)

// But process notifications as they arrive (may be 16, 32, or other Hz)
ON motion_notification(data):
    timestamp = get_current_time()
    decoded_data = decode_motion_data(data)
    motion_stream.push_sample(decoded_data, timestamp)
END ON
```

### Recommendations

**For Most Users:**
- Use defaults: 128 Hz (EEG), 16 Hz (motion)
- These work for most Emotiv Epoc devices

**For Advanced Users:**
- If you know your firmware uses 32 Hz motion, configure it
- If you have a different model with different rates, adjust accordingly
- The configured rate is metadata - actual timing comes from notifications

**For Developers:**
- Always provide configuration options
- Document the defaults clearly
- Allow runtime configuration changes
- Log the configured rates at startup

---

## 13. Known Limitations and Issues

### BLE-Specific Limitations

1. **Range:** Bluetooth LE has limited range (~10-30 meters) compared to USB
2. **Interference:** Susceptible to 2.4 GHz interference (WiFi, microwaves)
3. **Latency:** Higher latency than USB (typically 7.5-30ms connection interval)
4. **Packet Loss:** More prone to packet loss than wired USB
5. **Battery:** Headset battery drains faster than USB mode
6. **Sample Rate Variability:** Motion sample rate varies by firmware (16-32 Hz)

### Platform-Specific Issues

**iOS:**
- Requires Bluetooth permissions in Info.plist
- Background scanning limited by iOS
- May require MFi certification for production apps

**Android:**
- Requires location permissions for BLE scanning (Android 6+)
- Bluetooth permissions vary by Android version
- Some devices have unreliable BLE stacks

**Windows:**
- BLE support varies by Bluetooth adapter
- May require specific drivers
- UWP apps have better BLE support than Win32

### Known Bugs and Workarounds

**Issue 1: Data starts before start command**
- **Symptom:** EEG/motion data arrives before sending 0x0100 command
- **Cause:** Headset may auto-start streaming on notification enable
- **Workaround:** Handle data immediately after enabling notifications

**Issue 2: Motion packet size varies**
- **Symptom:** Motion packets sometimes 20 bytes instead of 32
- **Cause:** BLE MTU negotiation
- **Workaround:** Only require first 14 bytes for IMU data

**Issue 3: Connection drops randomly**
- **Symptom:** Unexpected disconnections
- **Cause:** BLE connection interval mismatch or interference
- **Workaround:** Implement automatic reconnection logic

---

## 13. Complete Implementation Example

### Pseudocode: Full BLE Client

```
FUNCTION main_emotiv_ble_client():
    // Initialize BLE
    ble_manager = INITIALIZE_BLE()
    
    // Scan for devices
    devices = AWAIT discover_emotiv_devices()
    
    IF devices.length == 0:
        LOG_ERROR("No Emotiv devices found")
        RETURN
    END IF
    
    // Select first device
    device = devices[0]
    LOG("Connecting to: " + device.name)
    
    // Extract BLE key and derive encryption key
    ble_key = extract_ble_key(device.name)
    serial_number = create_serial_number(ble_key)
    encryption_key = derive_epoc_x_key(serial_number)
    
    // Connect
    AWAIT connect_to_device(device)
    
    // Discover services
    services = AWAIT device.discover_services()
    
    // Find characteristics
    eeg_char = FIND_CHARACTERISTIC(services, "81072F41-...")
    motion_char = FIND_CHARACTERISTIC(services, "81072F42-...")
    
    // Enable notifications
    AWAIT eeg_char.set_notify_value(TRUE)
    AWAIT motion_char.set_notify_value(TRUE)
    
    // Register callbacks
    eeg_char.on_value_changed(CALLBACK: 
        FUNCTION(data):
            eeg_values = process_eeg_data(data)
            output_eeg_stream(eeg_values)
        END FUNCTION
    )
    
    motion_char.on_value_changed(CALLBACK:
        FUNCTION(data):
            motion_values = process_motion_data(data)
            output_motion_stream(motion_values)
        END FUNCTION
    )
    
    // Send start commands
    start_cmd = [0x00, 0x01, 0x00, 0x00]
    AWAIT eeg_char.write(start_cmd)
    AWAIT motion_char.write(start_cmd)
    
    LOG("Streaming started")
    
    // Keep running until disconnection
    AWAIT device.wait_for_disconnection()
    
    LOG("Disconnected")
END FUNCTION
```

---

## 14. Validation and Testing

### Test Cases

**Test 1: Device Discovery**
```
GIVEN: Emotiv Epoc X powered on and in range
WHEN: BLE scan is initiated with service filter
THEN: Device appears in scan results
AND: Device name matches pattern "EPOCX (XXXXXXXX)"
```

**Test 2: Connection and Service Discovery**
```
GIVEN: Emotiv device discovered
WHEN: Connection is established
THEN: GATT services are discovered
AND: Characteristics 0x41 and 0x42 are found
```

**Test 3: EEG Data Decryption**
```
GIVEN: EEG notification received
WHEN: Decryption is applied
THEN: 14 EEG values are extracted
AND: Values are in range -10000 to +10000 µV
```

**Test 4: Motion Data Parsing**
```
GIVEN: Motion notification received
WHEN: Parsing is applied (no decryption)
THEN: 6 IMU values are extracted
AND: Accelerometer values are in range -2 to +2 g
AND: Gyroscope values are in range -250 to +250 deg/s
```

### Validation Checklist

- [ ] Device discovery finds Emotiv headsets
- [ ] BLE key extraction works for all name formats
- [ ] Serial number derivation produces 16 bytes
- [ ] Encryption key derivation matches USB implementation
- [ ] EEG decryption produces valid data
- [ ] Motion parsing produces valid IMU data
- [ ] Sample rates are approximately correct (128 Hz EEG, 16 Hz motion)
- [ ] Disconnection is handled gracefully
- [ ] Reconnection works after disconnection

---

## 15. Troubleshooting Guide

### Common Issues

**Issue: "No devices found"**
- Verify headset is powered on
- Check Bluetooth is enabled on client device
- Ensure headset is not already connected to another device
- Try moving closer to headset
- Check platform-specific permissions (location on Android, Bluetooth on iOS)

**Issue: "Connection fails"**
- Headset may be in pairing mode with another device
- Try power cycling the headset
- Clear Bluetooth cache (Android)
- Forget device and re-pair

**Issue: "EEG data is garbage"**
- Verify BLE key extraction is correct
- Check serial number derivation (should be 16 bytes)
- Verify encryption key derivation
- Ensure XOR 0x55 is applied before AES decryption
- Compare with known good implementation

**Issue: "Motion data is all zeros"**
- Verify motion characteristic is found
- Check that notifications are enabled
- Ensure headset is moving (motion packets may be sparse when stationary)
- Verify no decryption is applied to motion data

**Issue: "Data rate is too slow"**
- Check BLE connection interval (should be 7.5-15ms)
- Verify no packet buffering in BLE stack
- Check for BLE interference
- Try reducing distance to headset

---

## 16. Comparison with USB Protocol

### Summary of Key Differences

| Feature | USB HID | Bluetooth LE |
|---------|---------|--------------|
| **Serial Number Source** | USB descriptor | Advertised name |
| **Data Delivery** | Blocking read | Notification callback |
| **Packet Identification** | byte[1] value | Characteristic UUID |
| **EEG Encryption** | Yes (XOR + AES) | Yes (XOR + AES) |
| **Motion Encryption** | Yes (XOR + AES) | **No (plaintext)** |
| **Packet Size** | Always 32 bytes | Variable (20-32 bytes) |
| **Connection** | Automatic | Manual pairing |
| **Latency** | <1ms | 7.5-30ms |
| **Reliability** | Very high | Moderate |

### When to Use BLE vs USB

**Use BLE when:**
- Wireless operation is required
- Mobile device integration needed
- Portability is important
- USB port not available

**Use USB when:**
- Maximum reliability required
- Lowest latency needed
- Continuous power preferred
- Desktop/laptop application

---

## 17. Appendix A: Quick Reference

### UUIDs
```
Control Service:  81072F40-9F3D-11E3-A9DC-0002A5D5C51B
EEG Data:         81072F41-9F3D-11E3-A9DC-0002A5D5C51B
Motion Data:      81072F42-9F3D-11E3-A9DC-0002A5D5C51B
```

### Start Command
```
[0x00, 0x01, 0x00, 0x00]
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

### Motion Parsing (No Decryption)
```
1. Read int16 values at offsets 2, 4, 6, 8, 10, 12
2. Scale accelerometer: value / 16384.0
3. Scale gyroscope: value / 131.0
```

---

## 18. Document Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025 | AI Assistant | Initial BLE specification |

---

## 19. License and Usage

This specification document is provided for educational and development purposes. It is derived from analysis of open-source implementations and publicly available information.

**Disclaimer:** This is a reverse-engineered specification. Emotiv Systems Inc. has not officially endorsed or validated this document. Use at your own risk.

---

**END OF BLE SPECIFICATION**
