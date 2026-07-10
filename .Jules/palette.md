
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-07-08 - Add empty state to Bluetooth Scanner
**Learning:** Dynamic lists populated by streams (like a Bluetooth scanner) often start empty or may yield no results. Without a fallback UI, the user is left wondering if the app is broken, still loading, or simply found nothing.
**Action:** Always provide fallback UI or helpful empty state messages for dynamic lists to improve feedback visibility.
