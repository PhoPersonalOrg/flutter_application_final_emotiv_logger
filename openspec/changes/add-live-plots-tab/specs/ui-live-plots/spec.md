## ADDED Requirements
### Requirement: Live Plots Tab for EEG and Motion
The app SHALL provide a bottom navigation tab that renders live, scrolling line plots for EEG and Motion streams, displaying the last 10 seconds per channel in vertically stacked plots.

#### Scenario: Show EEG plots
- **WHEN** a headset is connected and EEG samples are flowing
- **THEN** the tab SHALL display 14 vertically stacked line plots, one per EEG channel
- **AND** each plot SHALL show the last 10 seconds of data with a continuously scrolling window

#### Scenario: Show Motion plots
- **WHEN** a headset is connected and Motion samples are flowing
- **THEN** the tab SHALL display 6 vertically stacked line plots, one per Motion channel (Accel/Gyro)
- **AND** each plot SHALL show the last 10 seconds of data with a continuously scrolling window

#### Scenario: Performance constraints
- **WHEN** the plots are rendering on a mid‑range mobile device
- **THEN** average CPU utilization attributable to plotting SHOULD remain below 10% during continuous streaming
- **AND** frame pacing SHOULD maintain a smooth experience (no sustained jank)

#### Scenario: Lifecycle and connectivity
- **WHEN** the app is backgrounded or the headset disconnects
- **THEN** plots MUST pause updates and release rendering pressure
- **AND** upon foregrounding or reconnection, plots MUST resume within one second without data corruption

#### Scenario: Usability defaults
- **WHEN** the plots render
- **THEN** each channel SHALL have a compact label and light gridlines
- **AND** vertical scaling SHALL auto‑range with clamped min/max to avoid outlier-induced collapse


