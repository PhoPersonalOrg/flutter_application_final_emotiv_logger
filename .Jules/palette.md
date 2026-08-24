
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2024-05-18 - Add Empty State to Device Scanner
**Learning:** When displaying a dynamic list of devices from a stream (like a Bluetooth scanner), users need feedback when the list is empty. Providing an empty state message that adapts to the current state (e.g., 'Searching...' vs 'No devices found') significantly improves visibility of system status.
**Action:** Always provide conditionally rendered empty state widgets (`if (list.isEmpty)`) inside dynamic lists, with messages tailored to the current asynchronous operation state.
