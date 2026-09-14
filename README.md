# Tinfinite Canvas

An infinite canvas app for iOS: pan/zoom anywhere, draw with pencil or finger,
and place rich content nodes (shapes, text, notes, images) at any world position.

Core ideas:

- **Canvas + Viewport**: the view hierarchy carries one transform (`O(1)` pan/zoom
  regardless of content size); camera-relative rendering keeps deep zoom stable.
- **Strokes**: PencilKit-style pipeline — 240 Hz coalesced sampling, ribbon
  tessellation, one shared append-only Metal buffer with hole compaction, MSAA,
  per-stroke frustum culling, and zoom-adaptive LOD.
- **Live ink is incremental**: the confirmed spine is append-only, so
  `LiveStrokeMesh` re-tessellates only the last two Catmull-Rom segments plus the
  predicted tail and the two caps, and uploads only the changed byte range —
  O(1) per input event instead of O(stroke length). Its output is pinned
  byte-for-byte to `StrokeGeometry.tessellate` by a differential test.
- **Nothing expensive on the touch→photon path**: the committed-stroke draw loop
  walks two dense arrays (no per-stroke dictionary lookups), the selection
  overlay hides itself when empty instead of invalidating a full-screen backing
  store every frame, and autosave defers while the pen is down.
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
- `Canvas-Info.plist` — merged with the generated plist (`GENERATE_INFOPLIST_FILE`
  stays on). Holds `CADisableMinimumFrameDuration`, which is what unlocks 120 Hz
  on ProMotion; the `INFOPLIST_KEY_…` build-setting form of that key is **not** in
  Xcode's allowlist and is silently dropped. Kept outside the `Canvas/` synchronized
  group so it is never picked up as a bundle resource. Verify after a build with:
  `plutil -p "$BUILT_PRODUCTS_DIR/Canvas.app/Info.plist" | grep CADisable` → `=> 1`.
