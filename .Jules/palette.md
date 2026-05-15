## 2025-02-14 - Added Tooltip to Settings IconButton
**Learning:** Found a missing tooltip on an icon-only button (Settings icon) in the Flutter app app bar. This is a common accessibility issue that affects screen reader users and users navigating by keyboard/hover.
**Action:** Always check icon-only `IconButton` widgets in Flutter to ensure they have a `tooltip` property defined for accessibility.
