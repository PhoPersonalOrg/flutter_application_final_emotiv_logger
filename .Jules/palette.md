## 2024-05-18 - Added Tooltip to Settings IconButton
**Learning:** In Flutter, an `IconButton` without text can be ambiguous for screen readers and users who rely on visual hints. Using the `tooltip` property natively serves dual purposes: providing a visual hover context and supplying the semantic label for screen readers. This makes the UI more accessible with minimal code change.
**Action:** Always add a `tooltip` property to `IconButton`s that only display an icon, unless context is exceedingly clear or an external semantic wrapper is used.
