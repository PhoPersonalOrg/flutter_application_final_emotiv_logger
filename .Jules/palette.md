
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-07-08 - Add empty state to dynamic streams
**Learning:** UX Pattern: Always provide fallback UI or helpful empty state messages for dynamic lists populated by streams (e.g., `ScannerWidget`'s device list) to improve feedback visibility when results are empty. In Flutter widget lists using spread operator, an empty state widget can be conditionally added using an `if (list.isEmpty)` statement directly inside the list without an `else` block.
**Action:** Always provide empty state fallbacks for lists that start empty and conditionally display context-aware messages based on current state (e.g., scanning vs idle).
