# Working in this repo

A note for the next Claude session that lands here. Read this first.

## What this is

MacVoxel — a native macOS voxel editor + path tracer. SwiftUI shell
over an Obj-C++ bridge over a C++20 core, with Metal for the renderer
and overlays. The README has the user-facing summary; this file is
for orienting on the code.

## Where development is

The SwiftUI port is settled: all seven panels native, the AppKit shell
(`AppDelegate`, `VoxelView`) and `third_party/imgui` are gone. Active
work is happening on feature branches off `main` (the port hasn't
landed there yet — see `git branch` for the current head).

Deferred polish, not yet implemented:

- Brush-size quick-keys (`[` / `]`). Tool / mode letter keys
  (V / L / B / F / M / T / R / G) are wired in `MetalScene` keyDown.
- Drag-drop a `.vox` onto the running window (cold-launch via Finder
  Open With works through `.onOpenURL`).
- Theme parity vs the old `ui/Theme.cpp` pro-app dark — SwiftUI defaults
  look fine, but the colors aren't exact.

## Where things live

```
src/
├── main.mm                Slim entry: argv `render` → CliRender;
│                          otherwise → MacVoxelRunApp (Swift @_cdecl)
│                          → SwiftUI App.main().
├── CliRender.mm           Headless `MacVoxel render` subcommand.
│                          Bypasses SwiftUI; drives PathTraceRenderer
│                          directly. Deterministic per `--seed`.
│
│   Document & geometry (unchanged through the port)
├── Document.h             { VoxelGrid, Palette, path, version }.
├── VoxelGrid.{h,cpp}      Sparse 16³-chunk hash-map grid. Tracks
│                          dirty chunks for incremental GPU upload.
├── Palette.{h,cpp}        256-entry color + Material array.
├── Material.h             { type, roughness, metallic, emission,
│                          emissionPower, transparency, ior }.
├── VoxFile.{h,cpp}        MagicaVoxel .vox load/save. Scene graph + MATL.
├── CellKey.h              21-bit-per-axis pack/unpack int64 cell keys.
├── Camera.{h,cpp}         Orbit camera, pure C++.
├── Raycast.{h,cpp}        CPU DDA for picking.
├── Shapes.{h,cpp}         Pure-C++ cell enumerators (Bresenham3D,
│                          planar disc / square / box, coplanar flood).
│
│   Editor state — the EditorContext bundle
├── EditorContext.{h,cpp}  Single-document editor context: Document,
│                          ToolSettings, Selection, RenderSettings,
│                          RenderProgress, GeneratorState, FloatingBuffer,
│                          PreviewOverlay, EditHistory, Clipboard,
│                          PanelState. EditorContextBridge owns one as
│                          a std::unique_ptr; every panel / controller
│                          reaches it through the bridge or the
│                          EditorContext& reference path.
├── ToolState.h            `ToolSettings`. (File still named ToolState
│                          for git-history reasons.)
├── GeneratorState.h       Active generator kind + Params.
├── PanelState.h           Drag-coalescing state still used by the
│                          SwiftUI panels — `palette_color_edit`
│                          (ColorPicker coalesce), `material_edit`
│                          (per-slot Material pre snapshot),
│                          `color_clipboard` (palette Copy/Paste color).
│                          The old ImGui-only fields (`palette_drag`,
│                          `palette_context_slot`, `save_render_clicked`,
│                          `show_imgui_demo`) are dormant.
├── RenderState.h          `RenderSettings` + `RenderProgress`.
├── EditHistory.{h,cpp}    Stroke-grained undo/redo, single-op
│                          transactions, per-cell / per-palette-slot
│                          dedup within an op.
├── Selection.{h,cpp}      Box / per-voxel selection set.
├── SelectionOps.{h,cpp}   RotateSelection, FlipSelection,
│                          LiftSelectionToFloating, etc.
├── FloatingBuffer.h       Lifted-selection grid + offset.
├── FloatingBufferOps.{h,cpp}  Lift / commit / paste / resample.
├── Clipboard.h            Cut / copy / paste of selected regions.
├── PreviewOverlay.h       Live tool-stamp staging buffer.
├── PreviewOps.{h,cpp}     `CommitPreviewOverlayThroughHistory(ctx)`.
│
│   Per-tool gesture controllers — see "Controllers" below
├── InteractionState.h     One struct of every gesture's per-tool slice.
├── Input.h                MouseEvent + ModifierFlags — AppKit-free.
├── ViewContext.{h,cpp}    Stateless picking + drag-projection. Camera
│                          by value, EditorContext* non-owning.
├── BrushOps.{h,cpp}       `StampBrushFootprint` + `ComputeNewCellValue`.
├── BrushController.{h,cpp}
├── ShapeController.{h,cpp}        Line / Circle / Square / Box bundled.
├── FaceController.{h,cpp}
├── MarqueeController.{h,cpp}
├── BoxSelectController.{h,cpp}
├── FloodSelectController.{h,cpp}
├── MoveSelectController.{h,cpp}
├── XformHandleController.{h,cpp}
├── GeneratorController.{h,cpp}
│
│   Generators (compute backend)
├── Generators.h           Pure-C++ types (`Bounds3i`, `Kind`, `Params`).
├── GeneratorEngine.{h,mm} GPU compute runner — one
│                          MTLComputePipelineState per Kind, atomic-
│                          append output buffer.
├── Generators.metal       MSL source for every generator kernel.
│
│   View shell + renderers
├── MetalScene.{h,mm}      MTKView subclass — *thin shell + dispatcher*.
│                          Owns: Metal queue, RaycastRenderer,
│                          PathTraceRenderer, SceneOverlayRenderer,
│                          GeneratorEngine, Camera, NSTrackingArea,
│                          InteractionState. NSEvent → MouseEvent
│                          translation, mouseDown/Dragged/Up tool-
│                          routing switches, right/middle/scroll/
│                          magnify camera input, hover bookkeeping,
│                          per-frame draw orchestration (renderer
│                          dispatch + native overlay pass). Init takes
│                          an EditorContextBridge — Swift's
│                          MetalSceneView (NSViewRepresentable)
│                          instantiates it. Never reaches NSApp.delegate.
├── RaycastRenderer.mm     Interactive GPU ray-cast renderer.
├── PathTraceRenderer.mm   Path tracer (render mode).
├── PathTrace.metal        MSL: pt_fragment + display_fragment.
├── SceneOverlayRenderer.{h,mm}  Tiny Metal pipeline that drains an
│                          OverlayDraw's vertex list as a triangle
│                          list. Premultiplied-alpha blend. Replaces
│                          ImGui's GetBackgroundDrawList / Foreground
│                          calls the controllers used to make.
├── Overlay.metal          MSL vertex/fragment for the overlay pass.
├── OverlayDraw.{h,cpp}    Immediate-mode 2D primitives (AddLine /
│                          AddRect / AddRectFilled / AddTriangleFilled,
│                          packed RGBA via `Rgba8`). Filled per frame
│                          by controllers (DrawOverlay) + the
│                          SelectionOverlay free functions; drained by
│                          SceneOverlayRenderer.
├── SelectionOverlay.{h,cpp}    `DrawSelection` + `DrawHover` free
│                          functions extracted out of the old
│                          VoxelView. Take an OverlayDraw &.
│
│   SwiftUI shell — see "SwiftUI shell" section below
└── swift/
    ├── MacVoxel-Bridging-Header.h   Imports the Obj-C side for Swift.
    ├── MainEntry.swift              @_cdecl entry from main.mm.
    ├── MacVoxelApp.swift            App + WindowGroup + .commands +
    │                                .onOpenURL.
    ├── MacVoxelCommands.swift       File / Edit / Undo+Redo command
    │                                groups; replaces buildMainMenu.
    ├── ContentView.swift            Three-column HSplitView.
    ├── MetalSceneView.swift         NSViewRepresentable around
    │                                MetalScene. Sets state.scene back-
    │                                ref so menu actions can call
    │                                invalidateRenderers /
    │                                frameCameraToDocument.
    ├── EditorState.swift            @Observable façade over the
    │                                bridge. 10 Hz tick Timer.
    ├── EditorContextBridge.h        Pure Obj-C interface — what Swift
    │                                sees.
    ├── EditorContextBridge_Internal.h  C++ accessor for Obj-C++ only.
    ├── EditorContextBridge.mm       Obj-C++ wrapper around
    │                                std::unique_ptr<EditorContext>;
    │                                all action methods live here.
    └── panels/
        ├── ModelPanel.swift         Stats display.
        ├── ToolPanel.swift          Tool grid + brush + per-tool params.
        ├── PalettePanel.swift       16×16 swatch grid + ColorPicker.
        ├── RenderPanel.swift        Path-trace settings + Save render
        │                            + Material editor.
        ├── LightPanel.swift         Sky + sun sliders.
        ├── SelectionPanel.swift     Rotate / flip buttons.
        └── GeneratorPanel.swift     Kind picker + per-kind params.
```

## SwiftUI shell

The shell is three layers thick: Swift `@Observable` → Obj-C bridge →
C++ `EditorContext`. Pure C++ types never cross into Swift; everything
Swift sees has an Obj-C interface in `EditorContextBridge.h`.

- **`EditorContextBridge`** (NSObject) owns `std::unique_ptr<EditorContext>`.
  Public Obj-C properties + action methods are the only API Swift uses;
  `EditorContextBridge_Internal.h` declares a `- (EditorContext *)context;`
  category that only Obj-C++ files include (used by `MetalScene`).
- **`EditorState`** (@Observable Swift class) wraps the bridge plus a
  weak `MetalScene?` back-reference. The bridge isn't @Observable, so
  EditorState republishes everything panels need via computed properties
  that read a stored `tick: UInt64` first — see "Observation cadence"
  below.
- **`MetalScene`** (Obj-C++ MTKView) does all of `VoxelView`'s old work
  except ImGui — see the file tree. Owns the renderers; takes the
  EditorContext through the bridge at init.
- **`MacVoxelCommands`** (`Commands` struct) maps SwiftUI menu items to
  bridge actions. `CommandGroup(replacing: .newItem)` provides
  New / Open / Close; `.saveItem` for Save / Save As; `.undoRedo` for
  Undo / Redo; `.pasteboard` for Cut / Copy / Paste / Delete / Deselect.
- **Panels** are pure layout. Every panel takes `state: EditorState`
  (most are `@Bindable`) and binds controls directly to state properties.
  Material editor and ColorPicker use `begin* / apply* / commit*`
  patterns with a Timer-based "no change for 400 ms → CommitOp"
  coalesce.

### Observation cadence

Controllers (brush stroke, marquee drag, etc.) mutate the EditorContext
directly — they don't go through the bridge. SwiftUI views that depend
on those mutations need a way to re-render at gesture cadence without
the controllers explicitly poking SwiftUI.

`EditorState.tick: UInt64` is bumped by a 10 Hz `Timer`. Computed
properties on `EditorState` that proxy bridge state read `_ = tick`
first so the Observation framework records the dependency. A brush
stroke that flips voxel counts shows up in `ModelPanel` within ~100 ms
without each callsite wiring its own version counter.

Properties that *don't* need tick observation (Settings the user sets
themselves — `state.maxBounces`, `state.toolKind`, etc.) still go
through `tick` for simplicity. The cost is negligible (a re-evaluation
costs nothing if nothing changed; SwiftUI diffs the result).

Action methods (`newDocument`, `openDocument`, `undo`, etc.) bump
`documentVersion` and `documentTitle` directly so menu enable-state +
window title update synchronously.

## Controllers

(Largely unchanged from the pre-port architecture. Re-read this anyway
if it's been a while — these are the modeling-side state machines.)

Every per-tool gesture is a pure-C++ namespace of free functions in the
FloatingBufferOps / SelectionOps style — no AppKit, no Obj-C, no view
references. Nine of them: `marquee_controller`, `box_select_controller`,
`flood_select_controller`, `move_select_controller`, `brush_controller`,
`shape_controller` (Line/Circle/Square/Box bundled), `face_controller`,
`xform_handle_controller`, `generator_controller`. All take some subset of:

```
(EditorContext& ctx, InteractionState& state,
 const ViewContext& vc, const MouseEvent& e)
```

`MetalScene`'s `mouseDown:`/`mouseDragged:`/`mouseUp:` translate
`NSEvent → MouseEvent` via `mouseEventFromNSEvent:` and route by
`ToolKind` (mouseDown) or `DragMode` (mouseDragged / mouseUp). Each
controller owns its slice of `InteractionState` (the slices were
carved out specifically to align with this dispatch — `BrushStream`,
`MarqueeDrag`, `XformHandle`, etc.).

`ViewContext` is the picking + drag-projection substrate. Stateless,
built fresh per call: holds Camera by value, viewport size as floats,
EditorContext* non-owning. Methods like `PickCell`, `PickFace`,
`PickXformHandle`, `XformHandleDragVoxels`, `FaceDragVoxels` are all
pure functions of `(camera, viewport, doc, cursor, …)`.

All cursor pixel coordinates inside controllers are *view-local* —
origin at the view's bottom-left. `MetalScene` converts NSWindow → local
once at the NSEvent boundary in `localFromWindow:` and again in
`mouseEventFromNSEvent:`. Controllers never see `NSPoint` or
`convertPoint:fromView:`. The `*_local` field naming on InteractionState
slices is the convention.

GeneratorController is the one that needs the Obj-C++ `GeneratorEngine`.
It takes a `std::function` closure (`generator_controller::GenerateFn`)
that the dispatcher builds via `[self generateFn]`; the controller calls
it like a black-box `(kind, bounds, params, &out_cells) → void`. Keeps
the .cpp platform-portable.

### Controllers and ImGui — fully decoupled

Before the port, the controllers' `DrawOverlay` functions called
`ImGui::GetBackgroundDrawList()` directly and read
`ImGui::GetIO().WantCaptureMouse` for hover gating. Now:

- `DrawOverlay` takes `OverlayDraw& od` and (where it matters) a
  `bool mouse_captured_by_ui`. Controllers emit lines / triangles /
  rects into `od`; `MetalScene`'s draw loop drains it into Metal via
  `SceneOverlayRenderer`.
- `generator_controller::Tick`'s Escape-handling param `escape_pressed`
  is set from `MetalScene`'s key state, not ImGui.
- Color literal helper `macvoxel::Rgba8(r,g,b,a)` replaces `IM_COL32`.

The `mouse_captured_by_ui` parameter is currently hardcoded `false`
in `MetalScene`: the SwiftUI panels live outside the MetalSceneView in
the SplitView, so they never intercept events that would reach the
scene. If a future overlay panel sits *on top of* the scene, that flag
needs real plumbing.

## Build / run loop

```sh
cmake --build build
pkill -f MacVoxel.app/Contents/MacOS/MacVoxel; sleep 0.5; open build/MacVoxel.app
```

The kill-and-relaunch is the right rhythm: AppKit treats `open` on an
already-running bundle as a no-op, so you have to actually exit the
previous process to see your changes. Ninja rebuilds are fast (~1–2 s
for a single .mm / .swift file change).

`-Wall -Wextra -Wpedantic -Werror` is on for project sources. There is
no longer any third-party code in the build that needs warning
suppression.

If a Swift-import method name doesn't match what Swift expects, add
`NS_SWIFT_NAME(swift(case:names:))` to the Obj-C declaration in
`EditorContextBridge.h` rather than rewriting the call sites. The
existing methods have plenty of examples.

## Headless rendering (use this!)

The same binary has a `render` subcommand that runs the path tracer
without spawning a GUI — write a PNG, exit. Use it for any "did the
renderer change behave the way I think" question, instead of asking
Paul to eyeball the running app.

```sh
build/MacVoxel.app/Contents/MacOS/MacVoxel render \
  --input  test/vox/teapot.vox \
  --output /tmp/check.png \
  --width 512 --height 512 \
  --samples 256 --bounces 5 --seed 1
```

Then `Read /tmp/check.png` to actually see the result.

- `--samples` is per-pixel; 64–256 is usually enough to read shape and
  shading, 1024+ if you need to evaluate noise.
- `--seed` makes the output byte-deterministic for fixed inputs — diff
  two renders with `md5` to confirm a change is/isn't a no-op. Baseline
  digest for sanity checks: teapot.vox @ 256×256, 32 spp, seed=1 →
  `9b695a3917fb04dfa65e0d3903372b37`.
- `--no-aces` swaps the ACES tonemap for a plain gamma-2.2 curve.
- The camera is fit-to-bounds; there are no yaw/pitch/distance flags.

Sample `.vox` files live in `test/vox/`. Useful ones:
`teapot.vox` (clean diffuse), `_metal mat test.vox` (metal + emissive),
`_light test.vox` (mixed diffuse/metal/glass surfaces with small
emitters — good for spotting NEE / MIS issues).

Headless can't exercise gesture state machines — for tool / controller
work, eyeball in the running app. Screenshot the window with
`screencapture -R x,y,w,h /tmp/foo.png` and `Read` it; the window
position + size come from `CGWindowListCopyWindowInfo`.

## Conventions Paul has set

These came up repeatedly during development and are worth not
relitigating:

- **Commits are per-step.** A logical fix or feature is one commit;
  don't bundle unrelated changes. Style: `refactor: short title` /
  `fix: …` / `feat: …` / `chore: …`. Coauthor trailer is
  `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.
- **No unsolicited refactors.** If you're fixing a bug, fix the bug.
  Don't reformat surrounding code, rename variables, or tidy adjacent
  functions unless the user asked.
- **Comments explain *why*, never *what*.** The code says what. A
  comment exists when there's a hidden constraint, a workaround for a
  specific bug, or a non-obvious invariant. Single-line is the default;
  multi-paragraph is almost always wrong. No "added in P8.3" or
  "fixes the X case" — those rot.
- **Single-pass writing.** When something is right, write it cleanly
  the first time. No half-finished alternate paths, no commented-out
  attempts.
- **No half-finished implementations.** Either it works or it isn't
  there.
- **Test the change in the running app before reporting done.** For
  renderer / UI work, eyeballing the result matters more than the
  type-check passing.

## Work rhythm

- The user prefers terse updates. State what you found, what you're
  changing, and move on. Skip "Let me look at...", "I'll now...", and
  end-of-turn recaps.
- For exploratory questions ("why does X happen?" / "what would Y look
  like?"), give a 2–3 sentence answer with a recommendation and ask
  whether to proceed. Don't dump implementation in response to a
  curiosity question.
- For concrete asks, just do it. The "explain then propose" formality
  is unwelcome when the user already knows what they want.
- Auto mode is often on. Don't stop for permission on local, reversible
  work. Still ask before destructive ops or anything that affects shared
  state.

## Path tracer specifics

`src/PathTrace.metal` is the path-tracer shader (vertex, path-trace
fragment, display fragment); `src/PathTraceRenderer.mm` is the Obj-C++
resource management around it. The shader has grown enough that edits
are touchy — read the whole bounce loop before changing the medium /
glass paths.

Key invariants in the shader:

- **Coordinate space:** the shader works in *grid space*, not world
  space. `ray_origin_world` is rotated to `ray_origin = (x, -z, y)`
  to match the rasterizer's convention. All distances inside the
  bounce loop are in voxel units.
- **`medium_mat` skips same-material cells in the DDA.** A connected
  run of glass voxels reads as one medium — refraction fires only at
  true air↔glass boundaries, not at every internal cell face.
- **`medium_entry` + `medium_albedo` carry Beer-Lambert state.**
  Distance through the medium is `length(h.point - medium_entry)`;
  tint is `pow(medium_albedo, distance)` — a 1-voxel reference depth
  in Absorption mode (matches MagicaVoxel: saturated colored glass
  darkens to its albedo across a single voxel). Probabilistic mode
  uses `medium_albedo = surface_albedo` so the same Beer-Lambert math
  yields the softer pre-P14 look without a separate scale constant.
- **The DDA reports medium-exit boundaries.** Three transitions:
  skip-mat→empty cell, skip-mat→empty chunk, skip-mat→AABB-out. All
  return `h.hit = true, h.cell_val = 0` so the bounce loop's exit
  handler fires and applies BL.
- **`t_hit` is parametric distance from the *clipped* origin** (after
  AABB intersection), not from the world ray origin. Compute `h.point`
  against the clipped origin or you'll be off by `t_start` along the
  ray.
- **Color space.** Palette is sRGB on disk; the renderer decodes to
  linear on upload (`std::pow(c, 2.2f)` in
  `rebuildResourcesFromDocument:`) and the display fragment re-encodes
  (`pow(c, 1/2.2)`). Don't multiply linear and sRGB values together.
- **VNDF GGX, not naive GGX.** The microfacet sampler in
  `ggx_sample_vndf` is Heitz 2018 visible-normal sampling. Every
  sample is guaranteed to produce an above-surface reflection — no
  fallback-to-mirror clamp, no spike artifact.

## Generators (P12.5)

Parameterized shape primitives that the user lays out via a gizmoized
AABB rather than drawing one cell at a time. The architecture is
GPU-first: each generator is a Metal compute kernel that scans its
AABB at one thread per cell, evaluates the primitive's inside-test,
and atomically appends the qualifying cell coords to an output
buffer. The CPU reads the count, copies `count × 12 bytes` directly
into a `std::vector<shapes::Vec3i>` (PackedCell in MSL = 3×int32,
identical layout), and stamps the cells through the PreviewOverlay so
the live preview / single-undo-step commit path is shared with the
shape tools.

Six built-in kinds shipped: Ellipsoid, Cylinder, Cone, Pyramid, Perlin,
Torus. Cylinder / Cone / Pyramid share an `AxisView` helper in
`Generators.metal` that materialises the int3 lo / dims / cell as
float[3] arrays so the axis-parameterized kernels can index by
`int axis` cleanly (MSL's vec3 `[]` indexing across address spaces is
the wobbly form). Perlin colors the AABB across a palette range
(`perlin_palette_lo..hi`) by noise threshold rather than a single
slot — gradient-map territory.

Lives in:
- `src/Generators.h` — pure-C++ types (`Bounds3i`, `Kind`, `Params`).
- `src/GeneratorEngine.{h,mm}` — Obj-C++ engine. Holds one
  `MTLComputePipelineState` per `Kind`, a grow-only output buffer, an
  atomic counter buffer.
- `src/GeneratorState.h` — active kind + Params (lives on EditorContext).
- `src/swift/panels/GeneratorPanel.swift` — kind picker + parameter UI.
- `src/GeneratorController.{h,cpp}` — gizmo state machine.

Adding a new built-in is small: write the kernel function in
`src/Generators.metal` (output protocol = thread-per-cell, atomic
append on match), add the `Kind` enum entry, add the kernel function
name in `KernelNameForKind` in `GeneratorEngine.mm`, add a panel
button in `GeneratorPanel.swift`, and any per-kind parameters go on
`Params` (plus `BridgeGenerator*` accessors in
`EditorContextBridge.h/.mm` and pass-throughs on `EditorState`).

Invariants:
- Generators don't touch the document, AppKit, or SwiftUI. They take
  `(Bounds3i, Params)` and emit cells.
- The engine's output buffer grows 2× whenever a request exceeds
  capacity (4096-cell floor on first allocation).
- The controller's per-frame `Tick` change detector (active kind /
  bounds / palette index / axis / apex_at_max) is what re-runs the
  engine when the user tweaks the panel — no SwiftUI callback wiring;
  just compare-and-refresh in the per-frame draw.

## Things that look weird but are intentional

- `transparency` controls a probabilistic split between glass-refract
  and diffuse-fallback, *not* an absorption modulator. At transparency=1
  a colored glass still tints (Beer-Lambert with the actual albedo);
  MagicaVoxel does the opposite (transparency=1 = clear regardless of
  color). Paul prefers the current behavior on aesthetic grounds.
- `_ior` from MATL is stored as the offset above 1.0 (so `_ior=0.3` in
  the file is IOR 1.3 to us). That's the MagicaVoxel convention.
- The grid's "loose" bounds aren't retightened on `Set(0)`. In practice
  we only erase via stroke-undo, which restores prior cells, so it
  doesn't matter — but it's a correctness gotcha if you ever grow a
  tool that permanently shrinks the model.
- `ToolState.h` defines `ToolSettings` (not `ToolState`); `RenderState.h`
  defines `RenderSettings` + `RenderProgress`. The file names date from
  before a rename pass kept git history attached to the original files.
- `PanelState.h` still defines a couple of drag-coalescing structs the
  SwiftUI panels never touch (`palette_drag`, `palette_context_slot`,
  `save_render_clicked`, `show_imgui_demo`) — relics from the ImGui
  panels, dormant but cheap to keep. Drag-rect state lives in the
  PalettePanel's SwiftUI `@State` and the right-click anchor is passed
  per-action, so the C++ side doesn't need to hold either.
- `main.mm` is intentionally tiny — argv check + Swift entry call. The
  Swift `App` runs `App.main()` from `MainEntry.swift`'s
  `@_cdecl("MacVoxelRunApp")` rather than via `@main`. Keeps `main.mm`'s
  early `render` subcommand dispatch — the headless path never touches
  SwiftUI.
- Bridge enums use `NS_ENUM(NSInteger, …)` with `NS_SWIFT_NAME(case)`
  on each entry so Swift gets idiomatic `.x` / `.brush` cases. Bridge
  methods use `NS_SWIFT_NAME` whenever the auto-import would produce a
  collision or a clunky name. There are quite a few of these — the
  pattern is mechanical, not magic.
