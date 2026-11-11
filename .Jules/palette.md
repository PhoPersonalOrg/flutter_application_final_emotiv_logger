
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2023-11-12 - Add helpful empty states for dynamic lists
**Learning:** Empty lists that are populated by asynchronous processes (like scanning for devices) can look broken or leave the user unsure if an action is happening. Empty states are crucial for improving feedback visibility, and we can adapt the message conditionally based on the processing state (e.g. `isScanning`) to clarify the exact system status. In flutter, adding `if (list.isEmpty) EmptyWidget()` within a `children: [...]` array next to a `...list.map()` spread operator natively handles this conditionally without requiring an else block.
**Action:** Always provide fallback UI or informative empty state messages for dynamic lists populated by streams or user action.
