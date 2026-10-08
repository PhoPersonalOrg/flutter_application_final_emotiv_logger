
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2024-10-08 - Add Empty State for Dynamic Streams
**Learning:** In Flutter widget lists (`children: [...]`), when mapping over a dynamic list using the spread operator (e.g., `...list.map()`), an empty state widget can be conditionally added using an `if (list.isEmpty)` statement directly inside the list without an `else` block. The spread operator naturally yields an empty iterable when the underlying list is empty. Adding a context-aware empty state (e.g., "Searching..." vs "No devices found") significantly improves UX visibility when lists are powered by asynchronous stream operations.
**Action:** When implementing lists populated by streams or searches, always insert a conditional empty state to provide clear feedback when results are pending or empty.
