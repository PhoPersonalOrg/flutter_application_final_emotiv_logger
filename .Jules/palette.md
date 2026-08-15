
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.
## 2026-07-08 - Add empty state to ScannerWidget list
**Learning:** When dealing with dynamic lists populated by streams or scans (like a Bluetooth device list), leaving the list empty when there are no results gives the user no feedback on whether the scan is still running or finished with no results. Providing a fallback empty state that distinguishes between 'searching' and 'no results' states improves UX visibility.
**Action:** Always provide an empty state widget for dynamic lists (e.g., using `if (list.isEmpty)` before spread operators in Flutter).
