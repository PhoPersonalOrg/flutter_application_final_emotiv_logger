## 2024-05-01 - Tooltips natively serve dual accessibility purposes in Flutter
**Learning:** Adding a `tooltip` property to a Flutter `IconButton` (and similar widgets) provides native dual accessibility support: it displays hover context for mouse users and automatically serves as the semantic label (ARIA equivalent) for screen readers, effectively acting as an ARIA label without requiring manual semantics adjustments.
**Action:** Always prefer setting the `tooltip` property on icon-only buttons as the primary way to enforce accessibility.
