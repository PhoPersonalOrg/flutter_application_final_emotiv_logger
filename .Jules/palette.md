
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.
## 2026-07-08 - Add conditional empty state to device scanner
**Learning:** In Flutter widget lists (`children: [...]`), when mapping over a dynamic list using the spread operator (e.g., `...list.map()`), an empty state widget can be conditionally added using an `if (list.isEmpty)` statement directly inside the list without an `else` block, because the spread operator naturally yields an empty iterable when the underlying list is empty. Adapting the fallback message conditionally based on the active processing state (e.g., `isScanning`) distinguishes between 'searching' and true 'no results' states, improving feedback visibility.
**Action:** Always provide fallback UI or helpful empty state messages for dynamic lists populated by streams to improve feedback visibility when results are empty. Use this inline `if (list.isEmpty)` pattern for simplicity.
