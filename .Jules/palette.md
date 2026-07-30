
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-07-08 - Add empty state to dynamic lists
**Learning:** Providing fallback UI or helpful empty state messages for dynamic lists populated by streams improves feedback visibility and accessibility when results are empty.
**Action:** Always provide empty state messages (e.g., "No headsets found yet.") for lists to ensure users understand the current state when no data is available.
