
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-08-10 - Add empty state to dynamic lists populated by streams
**Learning:** For dynamic lists like a Bluetooth scanner populated asynchronously, failing to provide fallback feedback leaves users unsure if a scan is in progress or completed with zero results. Leveraging conditional UI statements (e.g., `if (list.isEmpty)`) directly within spread-mapped iterables in a Flutter `Column` is a clean way to introduce these states.
**Action:** Always provide empty state fallback UI for dynamic lists, and conditionally adapt the message to distinguish between an active processing state (e.g., "searching...") and a true "no results" state.
