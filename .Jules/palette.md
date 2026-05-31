## 2024-05-31 - [Tooltip on settings button]
**Learning:** Adding a tooltip to icon-only buttons improves accessibility by providing semantic labels for screen readers and visual hover context without changing existing designs. This was missing on the settings IconButton in the AppBar.
**Action:** Always verify if `IconButton` usages contain a `tooltip` property to ensure dual-purpose accessibility compliance.
