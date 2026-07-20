
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-07-20 - Add empty state to ScannerWidget
**Learning:** For dynamic lists populated by streams (like discovered Bluetooth devices), users might feel stuck or unsure if the scan is working when results are empty. Adding a fallback empty state (e.g., "No headsets found yet. Try restarting scan.") improves feedback visibility and confidence.
**Action:** Always provide a fallback UI or helpful empty state message for dynamic lists instead of leaving an empty space to improve UX.
