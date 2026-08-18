
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2024-11-20 - Add Empty State to ScannerWidget
**Learning:** For dynamic lists populated by streams (like a Bluetooth device list in `ScannerWidget`), always provide an empty state widget to improve visual feedback when the list is empty. Conditionally adapting the text based on the scanning state (e.g., 'Searching for devices...' vs 'No devices found') provides better context.
**Action:** When mapping over dynamic lists using the spread operator (`...list.map()`), use `if (list.isEmpty)` directly before the spread to render a conditional empty state widget without breaking the list layout.
