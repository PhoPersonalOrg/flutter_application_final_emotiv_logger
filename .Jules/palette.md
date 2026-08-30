
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-07-08 - Add empty state for Bluetooth scanner list
**Learning:** In Flutter widget lists (`children: [...]`), when mapping over a dynamic list using the spread operator, an empty state widget can be conditionally added using an `if (list.isEmpty)` statement directly inside the list without an `else` block. The fallback message can also be conditionally adapted based on the active processing state (e.g., `isScanning`) to distinguish between 'searching' and true 'no results' states.
**Action:** Always provide fallback UI or helpful empty state messages for dynamic lists populated by streams to improve feedback visibility when results are empty, and tailor the message based on loading/scanning states.
