
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-07-08 - Empty States for Scanning Lists
**Learning:** Always provide fallback UI or helpful empty state messages for dynamic lists populated by streams (like `ScannerWidget`'s device list) to improve feedback visibility when results are empty. Adapting the fallback message conditionally based on active processing state (e.g., `isScanning`) distinguishes between 'searching' and true 'no results' states.
**Action:** In Flutter widget lists (`children: [...]`), map over dynamic lists using the spread operator (`...list.map()`) and conditionally add an empty state widget using `if (list.isEmpty)` directly inside the list without an `else` block, because the spread operator yields an empty iterable when the underlying list is empty.
