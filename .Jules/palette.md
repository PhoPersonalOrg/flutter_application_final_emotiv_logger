
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2024-05-18 - Add Empty State for Dynamic Scanner List
**Learning:** When using a dynamic list populated by streams (like a Bluetooth scanner device list), implementing an empty state provides essential user feedback. Adapting the empty message conditionally based on the active state (e.g., `isScanning`) distinguishes between an active "searching" phase and a true "no results" state, significantly improving clarity. In Flutter, when mapping over lists using the spread operator (`...list.map()`), you can cleanly insert an empty state by placing an `if (list.isEmpty)` widget directly before or inline with the mapping.
**Action:** Always provide conditional fallback UI or empty state messages for dynamic/stream-based lists to enhance visibility of the current process state.
