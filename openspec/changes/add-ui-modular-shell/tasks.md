## 1. Implementation
- [ ] 1.1 Create `ui-modular-shell` capability spec (this file) and link to `ui-live-plots`.
- [ ] 1.2 Extract `ConnectionBar` widget showing status and connect/disconnect.
- [ ] 1.3 Refactor main layout to fixed connection bar + tabbed content.
- [ ] 1.4 Add `LiveTableTab` for EEG records preview; reuse existing table logic.
- [ ] 1.5 Integrate existing `LivePlotsContent` under one of the tabs.
- [ ] 1.6 Add empty states when disconnected; avoid data rendering.
- [ ] 1.7 Ensure lifecycle: bar remains visible; tabs respond to connection changes.

## 2. Validation
- [ ] 2.1 Manual: connect/disconnect via bar; verify status and actions.
- [ ] 2.2 Manual: switch tabs while streaming; verify plots/tables behave.
- [ ] 2.3 Manual: disconnected state shows guidance without errors.

## 3. Documentation
- [ ] 3.1 Update README with new screenshots and usage for top bar + tabs.


