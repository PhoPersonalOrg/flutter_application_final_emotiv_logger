
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-07-08 - Add empty state to device scanner list
**Learning:** When using the spread operator (`...list.map()`) in a Flutter `children` list, providing a fallback empty state is cleanly achieved by adding an `if (list.isEmpty)` widget before or after the spread. This leverages Flutter's collection if to display the fallback without needing a ternary condition that wraps the entire list generation. Differentiating empty states based on active background operations (e.g. `isScanning`) prevents users from misinterpreting a "searching" state as a "no results" state.
**Action:** Always provide fallback UI or helpful empty state messages for dynamic lists populated by streams (like the device list). Adapt the fallback message conditionally based on the active processing state (e.g., `isScanning`) to distinguish between 'searching' and true 'no results' states.
