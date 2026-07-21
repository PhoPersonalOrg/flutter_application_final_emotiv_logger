
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-07-21 - Add empty state to ScannerWidget
**Learning:** For dynamic lists populated by streams or asynchronous events (e.g., a Bluetooth device scanner list), always provide fallback UI or helpful empty state messages to improve feedback visibility when results are empty.
**Action:** When adding or modifying a list that can be dynamically empty, include an `isEmpty` condition that renders an explicit, context-aware empty state (like "No headsets found. Click Start to scan.").
