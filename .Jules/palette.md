## 2024-06-03 - Flutter IconButton Tooltips
**Learning:** In Flutter, the `tooltip` property on widgets like `IconButton` serves dual purposes. It natively provides both visual hover context (for mouse/pointer users) and semantic label equivalence (like ARIA labels) for screen readers. There is no need for a separate semantic label if a tooltip is provided for simple interactive components.
**Action:** When auditing Flutter apps for accessibility, ensure every icon-only `IconButton` has a `tooltip` string defined to instantly hit both usability and accessibility goals without extra markup.
