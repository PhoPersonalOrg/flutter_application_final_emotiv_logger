
## 2026-07-07 - Add tooltip to Settings IconButton
**Learning:** In Flutter, the `tooltip` property natively serves dual purposes on widgets like `IconButton`: providing visual hover context and supplying the semantic label for screen readers. This provides ARIA-equivalent accessibility for icon-only buttons.
**Action:** When adding icon-only buttons, always supply the `tooltip` property instead of relying on `Semantics` wrapper if hovering behavior is also desired.
## 2026-07-07 - Add empty state for ScannerWidget list
**Learning:** Flutter's collection-if (`if (condition) Widget`) can be used cleanly directly inside a `children: [...]` list right next to a spread map operation to inject an empty state without wrapping the entire list logic in a ternary or extracting a method, which is a great pattern for stream-fed device lists.
**Action:** Always provide empty/fallback states for dynamic lists using this pattern to ensure users aren't left staring at an empty UI void when lists (like Bluetooth scanners) return no results.
