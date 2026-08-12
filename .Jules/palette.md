
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2024-05-18 - Empty States for Scanned Device Lists
**Learning:** When dealing with asynchronous bluetooth scanning, providing clear empty states based on `isScanning` greatly improves UX, distinguishing between a system actively searching versus one that has finished searching with zero results.
**Action:** When working on lists populated by streams or scans (like `ScannerWidget`), always inject a conditional text widget to explain the current scanning state if the list is empty.
