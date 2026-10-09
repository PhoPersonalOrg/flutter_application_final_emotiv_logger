
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2024-10-09 - Empty states for asynchronous lists
**Learning:** UX Pattern: Always provide fallback UI or helpful empty states messages for dynamic lists populated by streams (e.g. `ScannerWidget`'s device list) to improve feedback visibility when results are empty. Adapt the fallback message conditionally based on the active processing state (e.g. `isScanning`) to distinguish between 'searching' and true 'no results' states.
**Action:** When working with stream-based or dynamic lists, always include an `isEmpty` check to display an empty state, and consider the loading/scanning state to provide more contextual feedback to the user.
