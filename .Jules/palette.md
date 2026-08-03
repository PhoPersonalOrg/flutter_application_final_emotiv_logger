
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2024-11-20 - Add empty state message for Bluetooth scanner
**Learning:** UX Pattern: Always provide fallback UI or helpful empty state messages for dynamic lists populated by streams (e.g., `ScannerWidget`'s device list) to improve feedback visibility when results are empty. In Flutter widget lists (`children: [...]`), when mapping over a dynamic list using the spread operator (e.g., `...list.map()`), an empty state widget can be conditionally added using an `if (list.isEmpty)` statement directly inside the list without an `else` block, because the spread operator naturally yields an empty iterable when the underlying list is empty.
**Action:** Always add an empty state message when displaying lists that depend on dynamic input streams. Use conditional `if` in lists instead of ternary operators for clean Flutter UI structure.
