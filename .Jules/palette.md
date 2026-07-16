
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2024-05-18 - Add Empty State to Bluetooth Scanner List
**Learning:** For dynamic lists populated by streams (like discovered Bluetooth devices), it's critical to provide an empty state or fallback message. An empty UI with no indication of what to do (e.g., just an empty space under "Found headsets:") leaves users confused about whether the app is working, scanning, or failing.
**Action:** Always provide clear fallback UI (e.g., "Scanning for devices..." or "No devices found") for lists that start empty and update asynchronously.
