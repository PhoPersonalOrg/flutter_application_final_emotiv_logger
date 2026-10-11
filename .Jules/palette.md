
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.

## 2024-05-24 - Empty States in Dynamic Flutter Lists
**Learning:** In Flutter, when dynamically mapping streams to lists (e.g., `...foundDevices.map`), providing a clear empty state improves feedback when lists are naturally empty (e.g., during Bluetooth scanning). The `if (condition)` can be used directly inside `children` arrays before the spread operator.
**Action:** Always provide empty fallback text (like "Searching..." or "No devices found") for dynamic lists to improve UX clarity.
