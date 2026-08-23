
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2024-10-24 - Add contextual empty state to ScannerWidget
**Learning:** In Flutter widget lists (`children: [...]`), when mapping over a dynamic list using the spread operator (e.g., `...list.map()`), an empty state widget can be conditionally added using an `if (list.isEmpty)` statement directly inside the list without an `else` block, because the spread operator naturally yields an empty iterable when the underlying list is empty. Adapting the empty message conditionally based on the active processing state (e.g., `isScanning`) distinguishes between 'searching' and true 'no results' states, significantly improving feedback visibility.
**Action:** When implementing lists populated by streams or async operations, always provide fallback UI or helpful empty state messages, adapting the message contextually if the parent widget represents an active searching/loading state versus a completed empty state.
