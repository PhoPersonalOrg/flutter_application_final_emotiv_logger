## Context
We need a small UI refactor to separate connection controls/status from data views, enabling a consistent shell and easier future additions.

## Goals / Non-Goals
- Goals: Persistent connection bar; tabbed content; clear empty states when disconnected.
- Non-Goals: Full routing overhaul or theming redesign.

## Decisions
- Extract `ConnectionBar` observing `connectionStream`, `statusStream`, and device name; expose connect/disconnect actions via BLE manager.
- Use Flutter `TabBar/TabBarView` or `NavigationBar` within the content area; prefer minimal dependencies.
- Keep existing plots implementation intact; only move into a tab.

## Risks / Trade-offs
- Risk: Coupling between shell and manager → Mitigate via narrow interface usage.
- Risk: Layout churn → Keep refactor minimal and incremental.


