# Bluetooth LE Requirements Document

## Introduction

This document specifies the requirements for implementing a Bluetooth LE client that can successfully communicate with, receive data from, and decode data packets from Emotiv Epoc family headsets (Epoc+ and Epoc X) over Bluetooth Low Energy. This specification complements the USB HID protocol and provides all necessary information to build a BLE-compatible client implementation.

## Glossary

- **BLE**: Bluetooth Low Energy, a wireless communication protocol
- **GATT**: Generic Attribute Profile, the BLE data organization standard
- **Characteristic**: A GATT data endpoint that can be read, written, or provide notifications
- **Service**: A collection of related GATT characteristics
- **UUID**: Universally Unique Identifier used to identify services and characteristics
- **Notification**: Asynchronous data push from BLE device to client
- **MTU**: Maximum Transmission Unit, the maximum packet size for BLE
- **BLE_Key**: 8-character hex value advertised in device name (e.g., "E50202E9")
- **Emotiv_Headset**: An EEG headset manufactured by Emotiv Systems (Epoc+, Epoc X)
- **EEG_Channel**: One of 14 electrode positions: AF3, F7, F3, FC5, T7, P7, O1, O2, P8, T8, FC6, F4, F8, AF4
- **Motion_Data**: 6-axis IMU data (accelerometer and gyroscope)
- **Crypto_Key**: 16-byte AES encryption key derived from BLE key
- **Serial_Number**: 16-byte value derived from BLE key for encryption

## Overview

This requirements document provides a structured, testable specification for implementing an Emotiv Epoc Bluetooth LE client. For the complete technical protocol specification with implementation details, formulas, and pseudocode, see **bluetooth-protocol.md** in this directory.

## Requirements

### Requirement 1: BLE Device Discovery

**User Story:** As a BLE client application, I want to discover Emotiv headsets advertising over Bluetooth LE, so that I can present available devices to the user.

#### Acceptance Criteria

1. WHEN the client application starts scanning, THE Client_Application SHALL initiate a BLE scan with service UUID filter "81072F40-9F3D-11E3-A9DC-0002A5D5C51B"
2. WHEN a device is discovered, THE Client_Application SHALL check if the device name matches pattern "EPOC" or "Emotiv"
3. THE Client_Application SHALL extract the device platform name for display
4. THE Client_Application SHALL maintain a list of discovered devices
5. THE Client_Application SHALL provide a timeout of at least 30 seconds for scanning

### Requirement 2: BLE Key Extraction

**User Story:** As a BLE client application, I want to extract the encryption key from the device's advertised name, so that I can derive the correct AES key for decryption.

#### Acceptance Criteria

1. WHEN a device name is received, THE Client_Application SHALL parse the name for pattern "(XXXXXXXX)" where X is a hexadecimal character
2. THE Client_Application SHALL extract the 8-character hex value from the parentheses
3. IF the pattern is not found, THEN THE Client_Application SHALL raise an exception with message "Invalid device name format"
4. THE Client_Application SHALL store the BLE key for serial number derivation

### Requirement 3: Serial Number Derivation from BLE Key

**User Story:** As a BLE client application, I want to derive a 16-byte serial number from the BLE key, so that I can generate the encryption key.

#### Acceptance Criteria

1. WHEN the BLE key is extracted, THE Client_Application SHALL create a 16-byte array
2. THE Client_Application SHALL fill the first 12 bytes with 0x00
3. THE Client_Application SHALL reverse the byte order of the BLE key: bytes [6:8] + [4:6] + [2:4] + [0:2]
4. THE Client_Application SHALL parse the reversed hex string to 4 bytes
5. THE Client_Application SHALL place the 4 bytes at positions 12-15 of the serial number array
6. THE Client_Application SHALL return a 16-byte serial number

### Requirement 4: Encryption Key Derivation for BLE

**User Story:** As a BLE client application, I want to derive the AES encryption key from the serial number, so that I can decrypt EEG data packets.

#### Acceptance Criteria

1. WHEN the 16-byte serial number is available, THE Client_Application SHALL extract bytes at specific positions
2. THE Client_Application SHALL construct the key using positions: [15, 14, 12, 12, 14, 15, 14, 12, 15, 12, 13, 14, 15, 14, 14, 13]
3. THE Client_Application SHALL create a 16-byte AES key from the extracted bytes
4. THE Client_Application SHALL initialize an AES cipher in ECB mode using the derived key
5. THE Client_Application SHALL store the cipher object for EEG packet decryption

### Requirement 5: BLE Connection Establishment

**User Story:** As a BLE client application, I want to connect to a selected Emotiv device, so that I can access its GATT services.

#### Acceptance Criteria

1. WHEN a device is selected for connection, THE Client_Application SHALL initiate a BLE connection with a timeout of at least 15 seconds
2. WHEN the connection is established, THE Client_Application SHALL extract the BLE key from the device name
3. THE Client_Application SHALL derive the serial number and encryption key
4. THE Client_Application SHALL initiate GATT service discovery
5. IF connection fails, THEN THE Client_Application SHALL log the error and allow retry

### Requirement 6: GATT Service Discovery

**User Story:** As a BLE client application, I want to discover GATT services and characteristics, so that I can access EEG and motion data streams.

#### Acceptance Criteria

1. WHEN connected to a device, THE Client_Application SHALL call the discover services function
2. THE Client_Application SHALL iterate through all discovered services
3. THE Client_Application SHALL iterate through all characteristics in each service
4. WHEN characteristic UUID "81072F41-9F3D-11E3-A9DC-0002A5D5C51B" is found, THE Client_Application SHALL store it as the EEG characteristic
5. WHEN characteristic UUID "81072F42-9F3D-11E3-A9DC-0002A5D5C51B" is found, THE Client_Application SHALL store it as the Motion characteristic
6. THE Client_Application SHALL log all discovered services and characteristics

### Requirement 7: Notification Setup for EEG Data

**User Story:** As a BLE client application, I want to enable notifications on the EEG characteristic, so that I can receive EEG data packets.

#### Acceptance Criteria

1. WHEN the EEG characteristic is found, THE Client_Application SHALL call set_notify_value(TRUE)
2. THE Client_Application SHALL register a callback function for value changes
3. THE Client_Application SHALL log successful notification setup
4. IF notification setup fails, THEN THE Client_Application SHALL log the error

### Requirement 8: Notification Setup for Motion Data

**User Story:** As a BLE client application, I want to enable notifications on the Motion characteristic, so that I can receive IMU data packets.

#### Acceptance Criteria

1. WHEN the Motion characteristic is found, THE Client_Application SHALL call set_notify_value(TRUE)
2. THE Client_Application SHALL register a callback function for value changes
3. THE Client_Application SHALL log successful notification setup
4. IF notification setup fails, THEN THE Client_Application SHALL log the error

### Requirement 9: Data Stream Start Command

**User Story:** As a BLE client application, I want to send start commands to begin data streaming, so that the headset transmits EEG and motion data.

#### Acceptance Criteria

1. WHEN notifications are enabled, THE Client_Application SHALL create a start command byte array [0x00, 0x01, 0x00, 0x00]
2. THE Client_Application SHALL write the start command to the EEG characteristic with response required
3. THE Client_Application SHALL write the start command to the Motion characteristic with response required
4. THE Client_Application SHALL log successful command transmission
5. IF write fails, THEN THE Client_Application SHALL log the error and retry

### Requirement 10: EEG Data Decryption for BLE

**User Story:** As a BLE client application, I want to decrypt EEG notification data, so that I can extract raw sensor values.

#### Acceptance Criteria

1. WHEN an EEG notification is received, THE Client_Application SHALL apply XOR operation with 0x55 to each byte
2. THE Client_Application SHALL decrypt the XOR-processed data using AES-ECB in 16-byte blocks
3. THE Client_Application SHALL concatenate all decrypted blocks
4. THE Client_Application SHALL verify the decrypted data is at least 32 bytes
5. IF decryption fails, THEN THE Client_Application SHALL log the error and skip the packet

### Requirement 11: EEG Data Decoding for BLE

**User Story:** As a BLE client application, I want to decode decrypted EEG data into channel values, so that I can output calibrated microvolts readings.

#### Acceptance Criteria

1. WHEN decrypted EEG data is available, THE Client_Application SHALL extract 16-bit words in little-endian format
2. THE Client_Application SHALL extract words at indices 1 through 14 (skipping 0 and 15)
3. THE Client_Application SHALL map the 14 words to channels: AF3, F7, F3, FC5, T7, P7, O1, O2, P8, T8, FC6, F4, F8, AF4
4. FOR each word, THE Client_Application SHALL compute: value_uv = (word * 0.5128205128205129) * 0.25
5. THE Client_Application SHALL output 14 floating-point values in microvolts

### Requirement 12: Motion Data Parsing for BLE (No Encryption)

**User Story:** As a BLE client application, I want to parse motion notification data without decryption, so that I can extract IMU sensor values.

#### Acceptance Criteria

1. WHEN a Motion notification is received, THE Client_Application SHALL verify the data length is at least 14 bytes
2. THE Client_Application SHALL skip the first 2 bytes (header)
3. THE Client_Application SHALL read signed 16-bit little-endian values at byte offsets: 2, 4, 6, 8, 10, 12
4. THE Client_Application SHALL interpret the first 3 values as accelerometer (AccX, AccY, AccZ)
5. THE Client_Application SHALL interpret the last 3 values as gyroscope (GyroX, GyroY, GyroZ)
6. THE Client_Application SHALL scale accelerometer values by (1.0 / 16384.0) to convert to g units
7. THE Client_Application SHALL scale gyroscope values by (1.0 / 131.0) to convert to degrees/second
8. THE Client_Application SHALL output 6 floating-point values

### Requirement 13: Configurable Sample Rates for BLE

**User Story:** As a BLE client application, I want to configure sample rates for LSL streams and file metadata, so that downstream analysis tools have correct metadata.

#### Acceptance Criteria

1. THE Client_Application SHALL provide configurable sample rate settings for EEG and motion streams
2. THE Client_Application SHALL use default sample rates of 128 Hz for EEG and 16 Hz for motion
3. THE Client_Application SHALL allow users to override default sample rates via configuration
4. THE Client_Application SHALL use configured sample rates for LSL stream metadata
5. THE Client_Application SHALL use configured sample rates for CSV file headers
6. THE Client_Application SHALL process notifications as they arrive without artificial throttling
7. THE Client_Application SHALL timestamp every sample with precise arrival time
8. THE Client_Application SHALL NOT enforce fixed timing based on configured rates - the headset determines actual timing

### Requirement 14: Disconnection Handling

**User Story:** As a BLE client application, I want to handle device disconnection gracefully, so that resources are properly released.

#### Acceptance Criteria

1. WHEN the device disconnects, THE Client_Application SHALL detect the disconnection event
2. THE Client_Application SHALL close all file writers
3. THE Client_Application SHALL close all LSL outlets
4. THE Client_Application SHALL clear stored characteristics
5. THE Client_Application SHALL clear the encryption key
6. THE Client_Application SHALL log the disconnection
7. THE Client_Application SHALL optionally provide automatic reconnection capability

### Requirement 15: Error Handling for BLE

**User Story:** As a BLE client application, I want to validate and handle errors in BLE operations, so that I can maintain robust operation.

#### Acceptance Criteria

1. WHEN a notification has insufficient data, THE Client_Application SHALL log a warning and skip the packet
2. WHEN decryption fails, THE Client_Application SHALL log the error and continue to the next packet
3. WHEN a write operation fails, THE Client_Application SHALL log the error and retry up to 3 times
4. WHEN connection is lost, THE Client_Application SHALL trigger disconnection handling
5. THE Client_Application SHALL not terminate on individual packet errors
6. THE Client_Application SHALL provide debug logging capability for all BLE operations

### Requirement 16: Platform-Specific Permissions

**User Story:** As a BLE client application, I want to request necessary platform permissions, so that BLE operations are authorized.

#### Acceptance Criteria

1. ON iOS, THE Client_Application SHALL request Bluetooth permissions via Info.plist
2. ON Android, THE Client_Application SHALL request Bluetooth and location permissions
3. ON Windows, THE Client_Application SHALL verify Bluetooth adapter capabilities
4. THE Client_Application SHALL provide clear error messages when permissions are denied
5. THE Client_Application SHALL guide users to enable required permissions

### Requirement 17: LSL Stream Publishing for BLE

**User Story:** As a BLE client application, I want to publish decoded data to LSL streams with configurable sample rate metadata, so that other applications can consume the data.

#### Acceptance Criteria

1. WHEN connected, THE Client_Application SHALL create an LSL stream named "Epoc X" with type "EEG", 14 channels, and user-configured sample rate (default: 128 Hz)
2. WHEN connected, THE Client_Application SHALL create an LSL stream named "Epoc X Motion" with type "Accelerometer", 6 channels, and user-configured sample rate (default: 16 Hz)
3. THE Client_Application SHALL use the configured sample rates for LSL stream metadata only
4. WHEN EEG data is decoded, THE Client_Application SHALL push the 14 values to the EEG LSL stream with timestamp
5. WHEN motion data is decoded, THE Client_Application SHALL push the 6 values to the Motion LSL stream with timestamp
6. WHEN disconnected, THE Client_Application SHALL close both LSL streams
7. THE Client_Application SHALL allow LSL to handle irregular sample timing (LSL supports variable-rate streams)

### Requirement 18: File Logging for BLE

**User Story:** As a BLE client application, I want to log decoded data to CSV files, so that data can be analyzed offline.

#### Acceptance Criteria

1. WHEN connected, THE Client_Application SHALL create an EEG CSV file with timestamp in filename
2. WHEN connected, THE Client_Application SHALL create a Motion CSV file with timestamp in filename
3. WHEN EEG data is decoded, THE Client_Application SHALL write the 14 values to the EEG CSV file
4. WHEN motion data is decoded, THE Client_Application SHALL write the 6 values to the Motion CSV file
5. THE Client_Application SHALL flush file buffers periodically
6. WHEN disconnected, THE Client_Application SHALL close all CSV files

### Requirement 19: BLE vs USB Protocol Awareness

**User Story:** As a BLE client application, I want to correctly handle BLE-specific protocol differences, so that data is decoded accurately.

#### Acceptance Criteria

1. THE Client_Application SHALL derive serial number from BLE advertised name, not USB descriptor
2. THE Client_Application SHALL use characteristic UUIDs for packet type identification, not byte[1] value
3. THE Client_Application SHALL decrypt EEG packets with XOR + AES
4. THE Client_Application SHALL parse motion packets without decryption
5. THE Client_Application SHALL handle variable packet sizes (20-32 bytes)
6. THE Client_Application SHALL use notification callbacks, not blocking reads

### Requirement 20: Multi-Device Support

**User Story:** As a BLE client application, I want to support multiple Emotiv models, so that both Epoc+ and Epoc X can be used.

#### Acceptance Criteria

1. THE Client_Application SHALL support device names matching "EPOCX (XXXXXXXX)"
2. THE Client_Application SHALL support device names matching "EPOC+ (XXXXXXXX)"
3. THE Client_Application SHALL use the same encryption key derivation for both models
4. THE Client_Application SHALL handle motion data only for Epoc X
5. THE Client_Application SHALL log the detected model type

### Requirement 21: Sample Rate Configuration

**User Story:** As a user, I want to configure the sample rates for EEG and motion streams, so that LSL metadata matches my headset's actual rates.

#### Acceptance Criteria

1. THE Client_Application SHALL provide a configuration option for EEG sample rate with default value of 128 Hz
2. THE Client_Application SHALL provide a configuration option for motion sample rate with default value of 16 Hz
3. THE Client_Application SHALL accept sample rate values as floating-point numbers
4. THE Client_Application SHALL validate that sample rates are positive values
5. THE Client_Application SHALL apply configured sample rates to LSL stream creation
6. THE Client_Application SHALL apply configured sample rates to CSV file headers
7. THE Client_Application SHALL log the configured sample rates at startup
8. THE Client_Application SHALL allow configuration via at least one method: config file, command line, or UI
9. THE Client_Application SHALL provide a way to reset to default sample rates
