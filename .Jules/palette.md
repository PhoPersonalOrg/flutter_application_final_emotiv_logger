## 2024-05-11 - Add tooltip to settings IconButton
**Learning:** Found that the app bar's settings `IconButton` lacked a tooltip. In Flutter, adding a `tooltip` property to an `IconButton` serves a dual purpose: it provides a visual hint on hover/long-press and acts as an accessible semantic label for screen readers.
**Action:** When adding or reviewing `IconButton`s in Flutter apps, always check for the presence of a `tooltip` property to ensure both visual and semantic accessibility are maintained.
