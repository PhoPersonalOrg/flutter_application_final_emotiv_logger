
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-07-07 - Add fallback empty state for Bluetooth Device List
**Learning:** Dynamic lists populated by streams (like `ScannerWidget`'s device list) can appear broken or inactive if they are empty without explanation. Adding an empty state provides critical feedback visibility.
**Action:** Always provide fallback UI or helpful empty state messages for dynamic lists to improve visibility when results are empty.
