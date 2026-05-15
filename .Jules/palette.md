
## 2024-05-18 - Added Tooltip to Settings IconButton
**Learning:** Added semantic label `tooltip: 'Settings'` to the primary navigation `IconButton`. This serves the dual purpose of displaying a visual tooltip on hover and providing a semantic label for screen readers, which is the idiomatic way to handle accessibility for icon-only buttons in Flutter.
**Action:** Always check `IconButton` usages across Flutter projects to ensure they have the `tooltip` property set for accessibility.
