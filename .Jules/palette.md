
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2024-07-17 - Add helpful empty state to Bluetooth scanner
**Learning:** For dynamic lists populated by streams (like the Bluetooth device scanner), users can be left confused when the list is empty, unsure if the app is still searching or if nothing was found. Adding an explicit empty state improves UX by providing immediate feedback on system status.
**Action:** Always provide fallback UI or helpful empty state messages for dynamic lists populated by streams to improve feedback visibility when results are empty.
