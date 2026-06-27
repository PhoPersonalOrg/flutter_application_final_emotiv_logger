## 2024-05-18 - Tooltip for Icon-only buttons
**Learning:** Icon-only buttons in Flutter require a tooltip for dual purpose: visual context on hover and accessibility label for screen readers. This prevents users relying on screen readers from hearing "button" without context.
**Action:** When adding or auditing icon-only `IconButton` widgets, always ensure the `tooltip` parameter is explicitly set to provide an accessible description.
