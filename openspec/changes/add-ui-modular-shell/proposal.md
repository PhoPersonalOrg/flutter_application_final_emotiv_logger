## Why
The current UI mixes connection controls, status, and data previews in a single page, making it harder to navigate and scale. A modular shell with a persistent connection bar and tabbed content clarifies responsibilities and keeps data views focused.

## What Changes
- Add a persistent connection bar at the top with live connection status and Connect/Disconnect controls.
- Move all data views into a tabbed content area below the bar with two tabs:
  - Live Plots (EEG and Motion banks)
  - Live Table Previews (EEG records preview)
- When no device is connected, both tabs display an empty state and do not attempt to render.
- Keep business logic in `EmotivBLEManager`; UI shell only observes streams and issues connect/disconnect actions.

## Impact
- Affected specs: `ui-modular-shell` (new capability), references `ui-live-plots`.
- Affected code: `lib/main.dart` (layout refactor), extract widgets under `lib/ui/` for `ConnectionBar`, `LivePlotsTab`, and `LiveTableTab`.
- No changes to BLE decode or file/LSL pipelines.

## Out of Scope
- Deep redesign of plot rendering or table formatting beyond moving into tabs.
- Cross-screen routing or persistence of tab selection across launches.


