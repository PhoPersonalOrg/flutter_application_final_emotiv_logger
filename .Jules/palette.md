
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.
## 2026-10-13 - Add dynamic empty state to ScannerWidget
**Learning:** When dealing with dynamic lists populated by streams (e.g., device scanners), omitting a fallback UI can leave users confused when results are empty. Adding conditional empty states adapts to the active processing state and improves feedback visibility.
**Action:** Always provide adaptive empty states or helpful fallback messages for dynamic lists to ensure clarity.
