
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-07-28 - Add helpful empty state to dynamic lists
**Learning:** Dynamic lists populated by streams (like a Bluetooth scanner device list) should always provide an empty state fallback. Without it, users may think the app is broken or frozen if no items appear immediately.
**Action:** When working with dynamic lists in Flutter, use conditionals like `if (items.isEmpty)` to display a helpful placeholder message or loading indicator instead of leaving the UI blank.
