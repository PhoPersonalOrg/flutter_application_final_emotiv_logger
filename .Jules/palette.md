
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-07-08 - Add empty state to dynamic lists
**Learning:** Dynamic lists populated by streams (like a Bluetooth scanner) often start empty, leaving the user wondering if the app is working or broken. Providing a clear empty state with helpful guidance (or indicating an ongoing async state like scanning) significantly reduces user confusion.
**Action:** Always provide a fallback UI or helpful empty state message for dynamic lists that might initially be empty or become empty, improving feedback visibility.
