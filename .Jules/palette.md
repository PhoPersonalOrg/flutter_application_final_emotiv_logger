## 2024-03-24 - Accessibility improvements for icon-only buttons
**Learning:** Found instances of icon-only buttons lacking `tooltip` attributes in `lib/main.dart`, which degrades keyboard navigation and screen reader accessibility for users. Adding the `tooltip` property to `IconButton` widgets provides an easy fix for hover/focus actions and semantic labeling.
**Action:** Applied `tooltip` attributes to settings icon in the app bar to improve overall accessibility.
