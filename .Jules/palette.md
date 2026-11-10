
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2026-07-08 - Add helpful empty state to dynamic lists based on active scanning
**Learning:** UX Pattern: Always provide fallback UI or helpful empty state messages for dynamic lists populated by streams (e.g., `ScannerWidget`'s device list) to improve feedback visibility when results are empty. Furthermore, adapting the fallback message conditionally based on the active processing state (e.g., `isScanning`) distinguishes between 'searching' and true 'no results' states, providing clearer context to the user.
**Action:** When implementing lists that scan or fetch data asynchronously, conditionally add an empty state widget (e.g., using `if (list.isEmpty)` directly in the list spread) and tailor the text to reflect whether the app is currently searching or if the search has finished with no results.
