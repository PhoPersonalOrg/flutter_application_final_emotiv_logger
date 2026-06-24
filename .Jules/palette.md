## 2024-05-18 - Added Accessibility Tooltips to IconButtons

**Learning:** When adding accessibility to icon-only buttons in Flutter apps (similar to ARIA labels in web dev), the `IconButton` natively supports the `tooltip` property. This elegantly provides both a visual hover tooltip for desktop/web users and acts as the semantic label for screen readers.

**Action:** Always check `IconButton`s in the codebase to ensure they have the `tooltip` property populated. When working on any Flutter UX/A11y pass, this is a quick and high-impact improvement.