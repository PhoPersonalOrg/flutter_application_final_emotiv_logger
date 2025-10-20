## 1. Implementation
- [ ] 1.1 Create `ui-live-plots` capability spec with requirements and scenarios.
- [ ] 1.2 Add bottom navigation tab entry and route.
- [ ] 1.3 Implement ring buffers (10s capacity) for EEG (1280 samples/ch) and Motion (~160 samples/ch).
- [ ] 1.4 Implement lightweight scrolling line plot widget (batch draws, reuse painters).
- [ ] 1.5 Wire plots to live data streams (EEG, Motion) with backpressure control.
- [ ] 1.6 Auto-scale per-channel with clamped range; add channel labels and compact grid.
- [ ] 1.7 Pause/resume behavior on connect/disconnect and app lifecycle changes.
- [ ] 1.8 Performance pass on mobile (target <10% CPU on mid-range device while streaming).
- [ ] 1.9 Accessibility: ensure labels have sufficient contrast; respect text scale.
- [ ] 1.10 Add a simple enable/disable toggle to stop rendering without stopping acquisition.

## 2. Validation
- [ ] 2.1 Manual: stream from a headset; verify continuous plotting and correct channel count/order.
- [ ] 2.2 Manual: background/foreground app; verify plots pause/resume without leaks.
- [ ] 2.3 Manual: disconnect device; verify plots clear and stop consuming CPU.
- [ ] 2.4 Optional: profile in Flutter DevTools; confirm frame times and memory stable.

## 3. Documentation
- [ ] 3.1 Update README: add screenshots and usage notes for Live Plots tab.
- [ ] 3.2 Note limitations and future enhancements (filters, EQ, zoom/pan).


