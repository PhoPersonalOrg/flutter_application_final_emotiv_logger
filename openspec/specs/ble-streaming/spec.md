## ADDED Requirements
### Requirement: BLE Streaming for Emotiv Epoc X/Plus
The app SHALL connect to Emotiv Epoc X/Plus headsets over BLE, decode EEG and MEMS payloads, and publish LSL streams.

#### Scenario: Discover and connect over BLE
- WHEN the user scans for headsets
- THEN the app SHALL list available devices advertising the Emotiv control service `81072F40-9F3D-11E3-A9DC-0002A5D5C51B`
- AND the user SHALL be able to initiate a connection

#### Scenario: Start notifications for EEG and MEMS
- WHEN connected
- THEN the app SHALL enable notifications for EEG `81072F41-...` and MEMS `81072F42-...`
- AND the app SHALL send the start command to begin streaming

#### Scenario: EEG decode XOR+AES
- WHEN a 32-byte EEG notification is received (UUID 0x41)
- THEN the app SHALL XOR each byte with 0x55, AES-ECB decrypt with a 16-byte key derived from the device serial/model, and map to 14 EEG channels
- AND the nominal sample rate SHALL be 128 Hz

#### Scenario: MEMS decode IMU
- WHEN a MEMS notification is received (UUID 0x42)
- THEN the app SHALL parse 6-axis IMU (Acc, Gyro) from the payload; if firmware requires, apply XOR+AES conditionally
- AND the nominal sample rate SHALL be ~16 Hz

#### Scenario: Publish LSL streams
- WHEN decoded EEG samples are available
- THEN the app SHALL publish to an LSL stream named `Epoc X` (type `EEG`, 14 channels, 128 Hz)
- AND WHEN decoded motion samples are available
- THEN the app SHALL publish to an LSL stream named `Epoc X Motion` (type `Accelerometer`, 6 channels, ~16 Hz)

#### Scenario: Close resources on disconnect
- WHEN the headset disconnects
- THEN the app SHALL close EEG and Motion LSL outlets and stop file logging


