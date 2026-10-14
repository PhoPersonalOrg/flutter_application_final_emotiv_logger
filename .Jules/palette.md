
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2024-06-25 - Fallback empty state for stream lists
**Learning:** UX Pattern: Always provide fallback UI or helpful empty state messages for dynamic lists populated by streams (e.g., `ScannerWidget`'s device list) to improve feedback visibility when results are empty. Use `if (list.isEmpty)` directly in the widget tree when combined with the spread operator.
**Action:** When implementing asynchronous lists (especially those dealing with Bluetooth scanning or dynamic searches), explicitly handle the empty state conditionally based on the `isScanning` status to distinguish between "searching" and "no results".
