
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-07-08 - Add conditional empty states to dynamic lists
**Learning:** For dynamic lists populated by streams (like bluetooth scanning results), always provide a fallback UI or empty state to improve visibility. Adapting the empty message based on the active state (e.g., distinguishing "searching" from true "no results") provides critical context for the user during asynchronous actions.
**Action:** When mapping over a dynamic list in a Flutter widget (e.g. `...list.map()`), use a preceding `if (list.isEmpty)` to conditionally show a helpful empty state that reacts to the underlying process state (like `isScanning`).
