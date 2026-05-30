## 2024-05-30 - Added tooltip to AppBar Settings Icon
**Learning:** IconButton natively serves dual purposes: providing visual hover context and supplying the semantic label for screen readers. Using the tooltip property is a robust way to achieve this accessibility improvement without explicit Semantics widgets.
**Action:** Always add a `tooltip` property to `IconButton` widgets when the icon itself is not accompanied by a textual label.
