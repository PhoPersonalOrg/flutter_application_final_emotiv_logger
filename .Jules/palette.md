## 2024-11-09 - Added Tooltip to Settings IconButton
**Learning:** In Flutter, using `IconButton` without a semantic label can present accessibility barriers to screen readers, and lack of visual hover context for pointer users. Utilizing the `tooltip` property natively addresses both issues without needing deeper semantic restructuring.
**Action:** Always verify if `IconButton` widgets have a configured `tooltip` attribute during routine UX checks in Flutter.
