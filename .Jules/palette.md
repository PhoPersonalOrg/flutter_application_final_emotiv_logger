
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## $(date +%Y-%m-%d) - Add helpful empty state to ScannerWidget
**Learning:** UX Pattern: Always provide fallback UI or helpful empty state messages for dynamic lists populated by streams (e.g., `ScannerWidget`'s device list) to improve feedback visibility when results are empty. In Flutter, you can adapt the message based on the active scanning state (searching vs finished without results) and include conditionally directly inside a list via `if`.
**Action:** Always include empty states for asynchronous or scanning lists when mapping items in Flutter widgets.
