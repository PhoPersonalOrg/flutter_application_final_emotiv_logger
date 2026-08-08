
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-08-08 - Add empty state message to dynamic streams
**Learning:** For dynamic lists populated by streams (e.g., `ScannerWidget`'s device list), failing to provide feedback when the result set is empty creates a confusing UX. Adapting the fallback conditionally based on the active processing state (e.g., `isScanning`) distinguishes between 'searching' and true 'no results' states.
**Action:** Always provide adaptive fallback UI or helpful empty state messages for dynamic lists populated by streams to improve feedback visibility.
