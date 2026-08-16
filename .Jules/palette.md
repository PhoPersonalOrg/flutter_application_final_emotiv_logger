
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.
## 2026-07-07 - Add dynamic empty state to dynamic stream-based UI lists
**Learning:** Dynamic lists in Flutter (like a BLE device scanner using `...list.map(...)`) need explicit empty state fallbacks to prevent a blank UX. Furthermore, the empty state phrasing should dynamically reflect the underlying process (e.g., distinguishing between "Searching..." and "No results found"). Using conditional Dart syntax (`if (list.isEmpty) Widget`) directly in the `children` array is the cleanest way to insert this state.
**Action:** Always provide a conditional empty state with contextual phrasing for lists populated by asynchronous streams or scanning processes.
