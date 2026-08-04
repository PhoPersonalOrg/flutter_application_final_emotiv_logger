
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.
## $(date +%Y-%m-%d) - Add Empty State to Device Scanner Widget
**Learning:** Adding an empty state to dynamic lists populated by streams significantly improves usability. Without it, users may think the app is broken or scanning hasn't started when the list is genuinely empty.
**Action:** Always provide fallback UI or helpful empty state messages for dynamic lists (e.g., `if (list.isEmpty) EmptyStateWidget()`) to improve feedback visibility when results are empty.
