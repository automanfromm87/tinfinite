# Tinfinite Canvas

An infinite canvas app for iOS: pan/zoom anywhere, draw with pencil or finger,
and place rich content nodes (shapes, text, notes, images) at any world position.

Core ideas:

- **Canvas + Viewport**: the view hierarchy carries one transform (`O(1)` pan/zoom
  regardless of content size); camera-relative rendering keeps deep zoom stable.
- **Strokes**: PencilKit-style pipeline — 240 Hz coalesced sampling, ribbon
  tessellation, one shared append-only Metal buffer with hole compaction, MSAA,
  per-stroke frustum culling, and zoom-adaptive LOD.
- **Content nodes**: shape / text / sticky-note / image nodes as world-space views
  with tap-select, drag-move, in-place text editing, and offscreen virtualization.
- **Documents**: multi-canvas library with atomic + backup-rotation saves,
  vector thumbnails, title/text search, and mesh-accurate PNG export.
- **Input**: finger drag, pinch zoom, double-tap zoom, keyboard shortcuts,
  and a unified undo journal across strokes and nodes.

## Build & test

Requires Xcode with the iOS SDK:

```bash
# Build the app
xcodebuild -project Canvas.xcodeproj -scheme Canvas \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# Pure-logic unit suites (no Xcode project changes needed)
bash Tests/run_tests.sh

# UI gesture regression (pan, zoom, draw, nodes) on simulator
xcodebuild test -project Canvas.xcodeproj -scheme Canvas \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Debug launch arguments (DEBUG builds only):

| Flag | Effect |
| --- | --- |
| `-CanvasOpenFirst` | Auto-open the first document |
| `-CanvasSelfTest` | Scripted self-check (strokes, selection, nodes, LOD) via unified log |
| `-CanvasStressTest` | Seed 2000 strokes + 200 nodes, report timings and culling |
| `-CanvasDemoNodes` | Leave demo nodes on screen for screenshots |
| `-CanvasShowTools` | Launch with the toolbar panel expanded |

## Layout

- `Canvas/` — app sources (filesystem-synced Xcode group, no per-file registration)
  - `CanvasCore/` — camera, viewport, canvas view, item placement
  - `Drawing/` — controller, strokes (model/store/geometry/sampler), Metal rendering
  - `Content/` — content-node model, store, and views
  - `Library/` — document library and persistence
  - `UI/` — sidebar, detail, toolbar, minimap, thumbnails
  - `Export/` — PNG document exporter
  - `Demo/` — DEBUG-only self-test harness
- `CanvasUITests/` — XCUITest gesture regression suite
- `Tests/` — `swiftc`-compiled logic suites (`run_tests.sh`)
