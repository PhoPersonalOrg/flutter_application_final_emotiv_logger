
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-07-08 - Add contextual empty state for Bluetooth scanner
**Learning:** In Flutter widget lists (`children: [...]`), when mapping over a dynamic list using the spread operator (e.g., `...list.map()`), an empty state widget can be seamlessly added using a conditional `if (list.isEmpty)` directly inside the list without an `else` block. When applied to asynchronous scanning lists, the fallback message should conditionally adapt based on the processing state (e.g. distinguishing between 'Searching...' and 'No results') for better UX context.
**Action:** Always provide adaptive empty states for dynamic streaming lists to improve user feedback visibility.
