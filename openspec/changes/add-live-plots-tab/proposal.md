## Why
Users need an immediate way to verify that EEG and Motion streams are alive, correctly mapped, and within expected ranges without relying on external tools. A lightweight, in-app live visualization improves confidence during setup and recording.

## What Changes
- Add a new bottom navigation tab that displays live, scrolling line plots for EEG and Motion.
- Show the last 10 seconds of data per channel in vertically stacked plots (one plot per channel).
- Provide two banks: EEG (14 channels @ 128 Hz) and Motion (6 channels @ ~16 Hz).
- Include sensible defaults for scaling (auto-range per channel with clamped min/max), gridlines, and labels (compact) to maintain clarity.
- Optimize rendering and buffering to keep CPU/GPU usage low on mobile devices.
- Pause plots when the app is backgrounded or no device is connected; resume seamlessly when foregrounded/connected.

## Impact
- Affected specs: `ui-live-plots` (new capability).
- Affected code:
  - UI: `lib/main.dart` (navigation), new widgets under `lib/` for plots and data adapters.
  - Data: reuse existing EEG/Motion pipelines; add lightweight ring buffers for the last 10 seconds.
  - No changes to BLE decode or LSL publishing behavior.

## Out of Scope
- Electrode quality visualization and per-channel notch/band filters (future enhancements).
- Advanced plot interactions (zoom/pan, crosshairs) beyond basic scrolling.


