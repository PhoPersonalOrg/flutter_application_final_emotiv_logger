## ADDED Requirements
### Requirement: Modular UI Shell with Persistent Connection Bar
The app SHALL present a persistent connection bar at the top that displays current connection status and provides Connect/Disconnect controls, with the main content below organized as tabs.

#### Scenario: Connection bar controls
- **WHEN** a headset is not connected
- **THEN** the bar SHALL show a Connect action and current Bluetooth status
- **AND** WHEN connected, the bar SHALL show the device name and a Disconnect action

#### Scenario: Tabbed content areas
- **WHEN** the user views data screens
- **THEN** the content area SHALL be tabbed with at least two tabs: Live Plots and Live Table Previews
- **AND** the Live Plots tab SHALL reference existing `ui-live-plots` behavior for EEG and Motion banks

#### Scenario: Empty state when disconnected
- **WHEN** no device is connected
- **THEN** both tabs MUST display an empty state and avoid attempting to render data

#### Scenario: Separation of concerns
- **WHEN** rendering the shell
- **THEN** data acquisition MUST remain in the BLE manager, and the connection bar SHALL observe connection/status streams and issue connect/disconnect via the manager API


