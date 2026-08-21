
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-08-21 - Add dynamic empty states for streaming lists
**Learning:** When implementing dynamic lists populated by asynchronous streams or scanning operations (like `ScannerWidget`'s device list), lacking a fallback UI creates poor visibility when no results are found. In Flutter widget lists, an empty state widget can be conditionally added using an `if (list.isEmpty)` statement directly inside the list `children` array without an `else` block, because the spread operator naturally handles empty iterables.
**Action:** Always provide adaptive empty state messages (e.g. differentiating between 'searching...' and 'no results') for dynamic lists to improve user feedback and confidence.
