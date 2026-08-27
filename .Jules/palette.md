
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-07-08 - Dynamic Empty States for Asynchronous Lists
**Learning:** When implementing empty states for asynchronous or scanning lists (like `ScannerWidget`'s device list), a static "No results" message is misleading if the system is still searching.
**Action:** Adapt the empty state message conditionally based on the active processing state (e.g., `isScanning`) to distinguish between 'searching' and true 'no results' states, providing clearer feedback.
