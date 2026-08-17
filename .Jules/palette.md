
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2024-08-17 - Add helpful empty state to dynamic lists
**Learning:** UX Pattern: Always provide fallback UI or helpful empty state messages for dynamic lists populated by streams (e.g., `ScannerWidget`'s device list) to improve feedback visibility when results are empty. In Flutter, the spread operator `...list.map()` can be preceded directly by an `if (list.isEmpty)` statement within a list's children array to elegantly handle this.
**Action:** When implementing empty states for asynchronous or scanning lists, adapt the fallback message conditionally based on the active processing state (e.g., `isScanning`) to distinguish between 'searching' and true 'no results' states.
