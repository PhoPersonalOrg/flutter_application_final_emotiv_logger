
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.
## 2024-11-07 - Add Conditional Empty State to Dynamic Widget Lists
**Learning:** In Flutter widget lists (`children: [...]`), when mapping over a dynamic list using the spread operator (e.g., `...list.map()`), an empty state widget can be conditionally added using an `if (list.isEmpty)` statement directly inside the list without an `else` block, because the spread operator naturally yields an empty iterable when the underlying list is empty.
**Action:** When working with streams or dynamic lists (like Bluetooth scanning results), always use inline `if` statements to provide an empty state fallback before spreading the dynamic content.
