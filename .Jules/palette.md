
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-07-08 - Add empty state feedback for asynchronous lists
**Learning:** For dynamic lists populated by asynchronous streams or scanning operations (e.g., Bluetooth device lists), displaying a blank area when the list is empty provides poor UX.
**Action:** Always provide conditionally rendered fallback UI or helpful empty state messages for dynamic lists. Furthermore, adapt the fallback message conditionally based on the active processing state (e.g., `isScanning`) to distinguish between 'searching' and true 'no results' states.
