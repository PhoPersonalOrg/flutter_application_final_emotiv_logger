
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2024-07-18 - Add empty state to Bluetooth Scanner device list
**Learning:** For dynamic lists populated by streams (like `ScannerWidget`'s device list), it's crucial to provide fallback UI or empty states when results are empty. Otherwise, users might think the app is broken or not functioning properly.
**Action:** When working with dynamically populated lists, always consider and implement a user-friendly empty state to improve visibility and feedback.
