## Context
We add an in‑app live visualization for EEG and Motion. Rendering must be efficient on mobile while consuming live streams that already exist for BLE decode and LSL publishing.

## Goals / Non-Goals
- Goals: Simple, low‑overhead plots for verification and monitoring; 10s window; two banks.
- Non-Goals: Advanced DSP, filtering, zooming, persistence, or external share/export.

## Decisions
- Use lightweight custom painter over heavy chart packages to minimize allocations and gain control over buffering and draw cadence.
- Maintain per‑channel ring buffers sized for 10 seconds of data; push samples from existing streams on the UI isolate via a throttled notifier.
- Separate data buffering from rendering; renderer pulls snapshots at animation ticks (e.g., 30–60 FPS capped).

## Risks / Trade-offs
- Risk: Excessive rebuilds causing jank → Mitigation: isolate drawing in `CustomPainter`, cache paths, batch draw.
- Risk: Memory pressure on older devices → Mitigation: reuse buffers; avoid large object churn.
- Risk: Backpressure from high‑rate EEG → Mitigation: coalesce updates; drop frames for plotting without dropping data in buffers.

## Migration Plan
1) Land UI scaffolding with stub data providers behind feature flag.
2) Integrate real EEG/Motion streams; verify correctness with known patterns.
3) Tune performance and finalize defaults; enable flag by default.

## Open Questions
- Desired color palette and label format for channels? (Default to compact grayscale + accent.)
- Should plots be toggleable between banks or show both simultaneously via tabs inside the page?


