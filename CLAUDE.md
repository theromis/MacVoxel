# Working in this repo

A note for the next Claude session that lands here. Read this first.

## What this is

MacVoxel — a native macOS voxel editor + path tracer. SwiftUI shell
over an Obj-C++ bridge over a C++20 core, with Metal for the renderer
and overlays. The README has the user-facing summary; this file is
for orienting on the code.

## Current architecture

The SwiftUI port is settled (all seven panels native; the old AppKit
shell and ImGui are gone). Editing is **GPU-authoritative**, modeled
on MagicaVoxel:

- Voxels live in a `texture3d<R8Uint, 256³>` (`tex_a`), mirrored by a
  dense CPU shadow (`VoxelVolume`) and the sparse `VoxelGrid` (disk +
  path-tracer source). The rasterizer samples `tex_a` directly via a
  16³ chunk-occupancy oracle.
- Every volume-writing tool is a `Tool` subclass that writes a preview
  texture — `tex_t` (Add/Paint) or `preview_rem` (Remove mask) — which
  the rasterizer composites over `tex_a` live. At mouseUp the unified
  `commit_generic` kernel promotes the preview into `tex_a`, then an
  end-of-stroke bbox readback diffs against the shadow to build undo
  history. See "Voxel storage architecture" and "Tool abstraction".
- Tool categories: **Brush** (cursor stamp), **Shape** (Line/Circle/
  Square/Box), **Face** (flood), **Generator** (gizmo-bounded
  primitives), **Mutator** (cursor-AOE that reads existing state and
  emits a delta — Foliage v1).

The full design lives in the plan at `/Users/pstarr/.claude/plans/
okay-despite-some-reasonable-sequential-torvalds.md`.

Deferred polish, not yet implemented:

- Brush-size quick-keys (`[` / `]`). Tool/mode letter keys
  (V / L / B / F / U / M / T / R / G) are wired in `MetalScene` keyDown
  (U = Mutator).
- Drag-drop a `.vox` onto the running window (cold-launch via Finder
  Open With works through `.onOpenURL`).
- Theme parity vs the old `ui/Theme.cpp` pro-app dark.
- 2D-brush variants of the shape kernels (`brush_3d == 0`) render
  nothing in `shape_main` — would need an in-plane mask or CPU fallback.

## Where things live

Only the non-obvious notes are called out — most files do what their
name says. Read the file for the rest.

```
src/
├── main.mm                Tiny entry: argv `render` → CliRender, else
│                          → Swift App.main().
├── CliRender.mm           Headless `MacVoxel render`. Device-create
│                          precedes LoadVox so VoxelVolume can attach
│                          the Metal texture.
│
│   Document & geometry
├── Document.h             Bundles grid + palette + volume +
│                          volume_shadow; SetCell / ApplyChanges /
│                          ClearCells / ReseedVolumeShadow.
├── VoxelGrid.{h,cpp}      Sparse 16³-chunk grid; disk + .vox format.
│                          `CellChange` lives here (ABI-compatible with
│                          BrushChange).
├── VoxelVolume.{h,cpp}    Dense 256³ uchar shadow + 16³ dirty bitset.
│                          Pre-stroke occupancy oracle. Reads outside
│                          the EditVolume return 0; writes are dropped.
├── EditVolume.h           Fixed 256³ canonical edit region.
├── Palette.{h,cpp}        256-entry color + Material array.
├── Raycast.{h,cpp}        CPU DDA for picking (on VoxelGrid; kept
│                          current by end-of-stroke sync).
├── Shapes.{h,cpp}         Cell enumerators: Bresenham3D, planar
│                          disc/square/box, coplanar floods (color-match
│                          for voxel-face Face, empty-match for wall).
│   …Material.h, VoxFile, CellKey, Camera as named.
│
│   GPU resources & kernels
├── VolumeTexture.{h,mm}   Per-doc Metal container: tex_a + its oracle,
│                          previewTex (tex_t) + its oracle, preview_rem
│                          + its oracle. syncFromVolume drains
│                          TakeDirtyChunks → replaceRegion.
├── BrushEngine.{h,mm}     Brush dispatcher. Dedicated MTLCommandQueue
│                          (off the frame queue); async; readback path.
├── ShapeEngine.{h,mm}     Shape/face/generator-commit dispatcher.
│                          Shares brush's queue. dispatchPreview /
│                          dispatchLineProjectPreview / dispatchStampCells
│                          / clearPreviewBbox / commitShape.
├── ShapeKernel.metal      shape_main, shape_line_project_main (project
│                          mode), shape_stamp_cells (Face scatter),
│                          shape_clear, and **commit_generic** — the
│                          Magica `shader_0018.glsl` blend
│                          (bm 1/Add 2/Erase 3/Replace 4/Intersect;
│                          source = tex_t or constant fill). Every
│                          tool's commit routes through it.
├── GeneratorEngine.{h,mm} One PSO per Kind. dispatchInto writes tex_t;
│                          unions current+last bounds so shrinking
│                          bounds clear in-place.
├── Generators.metal       generate_ellipsoid/cylinder/cone/pyramid/
│                          torus/perlin/tree/helix — thread-per-cell,
│                          writes palette to tex_t when inside.
├── MutatorEngine.{h,mm}   One PSO per Kind (v1: Foliage). dispatchInto
│                          writes a delta into tex_t from a live-
│                          composited read of tex_a+tex_t+preview_rem.
├── Mutators.metal         foliage_main; mutator_effective helper does
│                          the live-composited read.
├── BrushKernel.metal      brush_main: square/circle × 2D/3D ×
│                          Add/Remove/Paint, writes tex_a + oracle.
│
│   Editor state
├── EditorContext.{h,cpp}  Single-document editor context.
├── ToolState.h            Defines `ToolSettings` (name predates a rename).
├── RenderState.h          Defines `RenderSettings` + `RenderProgress`.
├── GeneratorState.h / Mutators.h / MutatorState.h   Kind + Params.
├── EditHistory.{h,cpp}    Stroke-grained undo; RecordBatch takes a
│                          CellChange[] and reserves capacity up front.
├── Selection / SelectionOps / FloatingBuffer / FloatingBufferOps /
│   Clipboard            Selection set, transforms, lift/paste.
├── PreviewOverlay.h       LARGELY DORMANT — only the `active` flag
│                          still matters (fires the rasterizer's
│                          `preview_active`). VoxelGrids inside unused.
├── PreviewOps.{h,cpp}     Legacy commit path; current tools don't use it.
│
│   Tools & dispatch (see "Tool abstraction")
├── Tool.h                 Abstract base for volume-writing tools.
├── ToolRegistry.{h,cpp}   Owns one of each; ToolFor(ToolKind).
├── EditEngine.{h,mm}      Pure-C++ façade over BrushEngine/ShapeEngine/
│                          GeneratorEngine/VolumeTexture; world↔texture-
│                          local translation.
├── InteractionState.h     Shared gesture state only (drag_mode, hover,
│                          two-click anchor, gen_gizmo_active mirror).
│                          Per-tool gesture state lives in each subclass.
├── Input.h                MouseEvent + ModifierFlags, AppKit-free.
├── ViewContext.{h,cpp}    Stateless picking + drag-projection. PickFace
│                          falls back to IntersectVolumeWall (Face fills
│                          wall/floor); near-wall skip checks the camera
│                          is actually outside the wall.
├── BrushTool / ShapeTool / FaceTool / GeneratorTool / MutatorTool
│                          One file each; see the table below.
│                          BeginShapeAnchor (in ShapeTool) is reused by
│                          Generator.
├── Marquee / BoxSelect / FloodSelect / MoveSelect / XformHandle
│                          Selection controllers (don't write the volume).
│
│   View shell + renderers
├── MetalScene.{h,mm}      MTKView — thin shell + dispatcher. Owns the
│                          queues, renderers, engines, VolumeTexture,
│                          Camera, ToolRegistry, EditEngine. mouse* events
│                          forward to _activeTool (set on mouseDown);
│                          selection tools + gen-gizmo have own branches.
├── RaycastRenderer.{h,mm} Rasterizer fragment. DDA samples tex_a (+ its
│                          oracle), preview_tex when active, buf
│                          coarse+pool for the FloatingBuffer.
├── PathTraceRenderer.mm   Path tracer. STILL reads VoxelGrid via the
│                          legacy coarse+pool path (rewriting its 1760-
│                          line DDA was out of scope); grid is kept
│                          current by end-of-stroke diff application.
├── PathTrace.metal        pt_fragment + display_fragment.
├── SceneOverlayRenderer / Overlay.metal / OverlayDraw / SelectionOverlay
│                          Immediate-mode 2D overlay pass.
│
└── swift/                 SwiftUI shell (see "SwiftUI shell").
```

## Voxel storage architecture (the B-phase model)

Three representations live in `Document` and stay in sync at known
points; **none is unconditionally authoritative** — which one is "the
truth" depends on the phase of the edit.

```
  VoxelVolume.shadow (CPU dense 256³)   end-of-stroke diff target;
        │                               pre-stroke occupancy oracle
        │  ApplyChanges(diff)
        ▼
  VoxelGrid (CPU sparse chunks)         disk/.vox format; undo records;
        │                               picking (frozen pre-stroke);
        │  syncFromVolume               path-tracer source; selection ops
        ▼
  VolumeTexture.tex_a (GPU R8Uint 256³) rasterizer samples this; frozen
        +                               at pre-stroke state during a
   tex_t + preview_rem (256³ each)      stroke; commit_generic writes it
                                        at mouseUp. tex_t = Add/Paint
                                        preview, preview_rem = Remove
                                        mask; rasterizer composites both
                                        over tex_a when preview_active.
                                        Each has its own 16³ oracle.
```

During a stroke:
1. Pre-stroke `VoxelGrid` and `VoxelVolume.shadow` are byte-equal inside
   the EditVolume (debug-asserted in `Document::SetCell`).
2. The GPU kernel writes `tex_t` or `preview_rem` — never `tex_a`. The
   rasterizer composites both over `tex_a`.
3. Picking uses `VoxelGrid`, frozen at pre-stroke state for the whole
   drag — picks always hit the original surface, no skip set needed.
4. On `OnMouseUp`, the tool: calls `commit_generic` over the stroke bbox
   with the right `bm`; `waitForPendingWork`; blits the bbox of `tex_a`
   back; diffs against `volume_shadow`; emits `CellChange[]`; calls
   `doc.ApplyChanges(diff)` + `history.RecordBatch(diff)`; drains
   `TakeDirtyChunks()` (a no-op since commit already wrote `tex_a`);
   `doc.BumpGeometry()`.

This is why all three reps stay in sync at every commit point. It also
means: **don't read `VoxelGrid` or `volume_shadow` for cells in the
active stroke's bbox** — they're stale until commit. Use the texture
(or the controller's local state).

## Tool abstraction

Every volume-writing tool is a `Tool` subclass (`src/Tool.h`) owned by
`ToolRegistry`. `MetalScene` looks up `ToolFor(_ctx->tool.tool)` at
mouseDown, stashes it in `_activeTool`, and routes subsequent events
there. Selection tools stay on their own per-controller branches.

`Tool` virtuals: `OnMouseDown` / `OnMouseDragged` / `OnMouseUp` (each
takes `EditorContext`, `InteractionState`, `ViewContext`, `MouseEvent`,
`EditEngine&`); `Tick` (per-frame, takes a `ViewContext` so hover-
preview tools can pick the cursor cell); `DrawOverlay`; `IsDragging` /
`Cancel`; `DispatchParamsHash` + `ShouldDispatch` (see "Tool perf rule").

| Tool | File | Notes |
| --- | --- | --- |
| Brush | `BrushTool` | tex_t (Add/Paint) or preview_rem (Remove); commits via commit_generic. Tick does the hover ghost. |
| Shape | `ShapeTool` | Line/Circle/Square/Box. `BeginShapeAnchor` free fn reused by Generator. |
| Face | `FaceTool` | CPU flood + shape_stamp_cells (palette != 0 → tex_t, == 0 → preview_rem). Wall flood via FloodCoplanarEmpty. |
| Generator | `GeneratorTool` | Persistent gizmo (drag-out → idle → commit). Public `Commit` for Enter-key. `HasActiveGizmo` intercept. |
| Mutator | `MutatorTool` | Cursor-AOE; Tick dispatches the hover ghost; OnMouseDown adopts the hover stroke_id. DrawOverlay = AOE-contact contour. |

`EditEngine` (`src/EditEngine.{h,mm}`) is the pure-C++ façade tools call
instead of the old `std::function` closures. The unified
`commit_generic` kernel (in `ShapeKernel.metal`) is bm-parameterized
(Add/Erase/Replace/Intersect) with a brush-source selector (tex_t /
preview_rem / constant fill).

## Mutator architecture (Foliage v1)

A Mutator is a hybrid of Brush and Generator: cursor-centered AOE like a
brush, parameter-driven like a generator, but the kernel **reads
existing voxel state in its AOE** and emits a delta — the "look at the
neighborhood, then decide" class (foliage, erosion, weathering, greebles).

Three load-bearing details:

1. **Live-composited read.** The kernel samples `effective(c) =
   preview_rem ? 0 : (tex_t != 0 ? tex_t : tex_a)`, not `tex_a` directly.
   Freshly-stamped cells seed the next stamp, so a bush *grows* under the
   cursor. (`mutator_effective` in `Mutators.metal`.)
2. **Hover stroke_id handoff.** The hover Tick allocates one
   `hover_stroke_id_` per uninterrupted hover session as the RNG salt;
   `OnMouseDown` adopts it so the first stamp = exactly the ghost cells,
   alpha just snaps 0.55 → 1.0. New strokes get a fresh id (re-stroking
   the same area thickens the bush).
3. **Two-pass commit.** mouseUp fires `commit_generic bm=Add` then
   `bm=Erase` over the union bbox. Foliage's Erase pass is a no-op, but
   the path is in place for future delete-capable kinds (Erode, Weather).

`MutatorTool::DrawOverlay` draws an AOE-contact contour (not a floating
cube), distinguishing "outside AOE" from "rule said no": per plane
crossing the AOE, build a 2D bitmap of barrier cell-faces (occupied↔empty
or edit-volume wall) and XOR-walk the edges — interior shared edges
cancel, coplanar runs collapse to straight lines for free.

## Hover preview (ghost composite)

Brush and Mutator dispatch their preview kernel every frame the cursor
cell or params change, *before* a click; the rasterizer alpha-blends the
result over the backdrop at `ctx.preview_alpha = 0.55`. On `OnMouseDown`
the tool sets `preview_alpha = 1.0` and the same cells re-render opaque —
the ghost "settles" into place.

Invariants:
- **`Tick`** fires every frame from `drawInMTKView`; hover tools override
  it and use `vc.ComputeTargetCell`.
- **Per-frame bbox clear.** Each tool stores its last `hover_bbox_*_` and
  calls `EditEngine::ClearPreviewBbox` at the start of every dispatch (or
  when becoming ineligible), or previous-frame cells leak.
- **`ctx.preview_active` + `preview_alpha`** set on dispatch, cleared
  (false / 1.0) when ineligible. Brush/Mutator mutual exclusion comes
  from Tick's `active_tool` check.
- **Rasterizer ghost path.** The DDA captures the first preview hit, sets
  `skip_preview` to keep marching, and at the terminal hit returns
  `mix(backdrop, ghost, preview_alpha)` — see the `ghost_seen` block in
  `RaycastRenderer.mm`.

## Tree generator (recursive branching, GPU-only)

`gen::Kind::Tree` (`generate_tree` in `Generators.metal`) draws a tree
with no CPU work and no extra buffer bindings (Paul's hard constraint:
"don't touch the CPU"). It's a per-cell distance-field eval of an
explicit recursive tree: a trunk capsule, K=3 children per node,
recursion **unrolled to 5 nested levels** (Metal has no recursion). Each
cell takes the `min` capsule-SDF over every branch; `de <= 0` = voxel.
Each child's pose is computed **from scratch** from its parent's tip via
`tree_grow_child` (tilt by `base_tilt`, rotate by `(digit+0.5)·2π/K`,
both seed-perturbed; length/radius taper per generation). The deepest
level routes to a `de_leaf` accumulator and writes `perlin_palette_hi`
(everything shallower → `palette_idx`) — that bark/leaf split is what
lets the result pair with the Foliage Mutator.

**Param remapping** (reuses the Perlin slider plumbing, relabeled in
`GeneratorControls`): `noise_octaves` → Depth (1..5); `noise_threshold`
→ Wildness (hash jitter); `noise_seed` → re-roll; `torus_tube` → trunk
radius; `palette_idx` → bark, `perlin_palette_hi` → leaf; `noise_scale`
ignored. The gizmo up-axis fits `TREE_MAX_HEIGHT`, so **use a roughly
cubical-or-wider gizmo** or the lateral branches clip the side walls.

**Don't reattempt KIFS for trees.** The elegant fold-based fractal was
tried and abandoned: a tree is a finite recursive structure where each
branch needs an *independent, non-accumulating* pose, not a fractal
attractor. Folds either binarize to near-zero volume, collapse every
level onto the trunk, or spiral from cumulative rotation. The unrolled
version costs ~3^depth capsule evals (a few hundred ms at depth 5) but
has no drift. If it ever needs to be faster: a 16³ branch-bucket oracle
or per-subtree bounding-sphere reject — not a return to folds.

## Tool perf rule: dispatch only on state change

The biggest perf lesson from the B3 phase: **don't dispatch every
`mouseDragged` when the target state hasn't changed.** Enforced via
`Tool::ShouldDispatch(uint64_t)` + per-Tool `DispatchParamsHash`. Each
tool hashes its full input set (endpoint/cursor + kind + brush params +
mode + per-kind params); Generator and the hover-time Mutator/Brush
paths hash from `Tick`, with a separate `hover_last_hash_` so hover and
drag dispatches don't interfere. BrushTool skips during drag (its
per-cell `last_drag_edit_cell` check already covers it).

If you add a tool: override `DispatchParamsHash`, call
`ResetDispatchHash()` from `OnMouseDown`, gate the dispatch behind
`ShouldDispatch(DispatchParamsHash(...))`.

Other perf rules:
- Keep the dispatch bbox **tight**; union with the previous frame's bbox
  only when you need to clear stale cells.
- For CPU-enumerated cell lists (project-mode Line, Face), prefer one
  thread per *cell* (scatter) over per-bbox-cell (gather).
- Use `volume_shadow.Get` (dense O(1)) over `grid.Get` (hashmap) for
  pre-stroke occupancy in hot paths.

## SwiftUI shell

Three layers: Swift `@Observable` → Obj-C bridge → C++ `EditorContext`.
Pure C++ types never cross into Swift; everything Swift sees has an
Obj-C interface in `EditorContextBridge.h`.

- **`EditorContextBridge`** (NSObject) owns the `EditorContext`.
- **`EditorState`** (@Observable) wraps the bridge + a weak `MetalScene?`.
  `tick: UInt64` is bumped by a 10 Hz Timer; computed props read
  `_ = tick` so panels re-render at gesture cadence.
- **`MetalScene`** (Obj-C++ MTKView) — all of `VoxelView`'s old work minus
  ImGui; owns every Metal resource the GPU-authoritative path needs.

Two traps worth knowing (both in memory): bridge-proxy *setters* must do
`tick &+= 1` (not just `_ = tick` in the getter) or input lags ~100 ms;
and never use `Slider(step:)` over a range with > ~100 ticks (AppKit lays
out one NSSlider tick-mark per step and freezes the main thread).

## Build / run loop

```sh
cmake --build build
pkill -f MacVoxel.app/Contents/MacOS/MacVoxel; sleep 0.5; open build/MacVoxel.app
```

The kill-and-relaunch is the right rhythm: AppKit treats `open` on an
already-running bundle as a no-op. Ninja rebuilds are fast (~1–2 s for a
single .mm / .swift change). `-Wall -Wextra -Wpedantic -Werror` is on for
project sources.

## Headless rendering (use this!)

The same binary has a `render` subcommand that runs the path tracer
without a GUI — write a PNG, exit. Use it for any "did the renderer
change behave the way I think" question.

```sh
build/MacVoxel.app/Contents/MacOS/MacVoxel render \
  --input test/vox/teapot.vox --output /tmp/check.png \
  --width 512 --height 512 --samples 256 --bounces 5 --seed 1
```

Then `Read /tmp/check.png` to see the result.

- `--samples` is per-pixel; 64–256 reads shape/shading, 1024+ for noise.
- `--seed` makes output byte-deterministic. **Sanity digest:** teapot.vox
  @ 256×256, 32 spp, seed=1 → `9b695a3917fb04dfa65e0d3903372b37`. Exercise
  it after any renderer change.
- `--no-aces` swaps the ACES tonemap for plain gamma-2.2.

**UI / gesture testing: Paul does it, not you.** Anything that needs
moving the mouse, clicking, dragging, or watching frames is Paul's job.
Your job: (1) build cleanly, (2) run the headless md5 check if the
renderer could be affected, (3) launch the app and optionally take a
static screenshot (`screencapture -R x,y,w,h`; window rect from
`CGWindowListCopyWindowInfo`), (4) hand off and ask for results.

Do **not** install `cliclick`, drive `osascript`/CGEvent mouse events, or
otherwise puppet the cursor — it's flaky on Paul's machine and slower
than just asking.

## Conventions Paul has set

- **Commits are per-step.** One logical fix/feature per commit; don't
  bundle. Style: `feat:` / `fix:` / `refactor:` / `chore: short title`.
  Coauthor trailer: `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.
- **No unsolicited refactors.** Fix the bug; don't reformat surroundings.
- **Comments explain *why*, never *what*.** Single-line by default. No
  "added in P8.3" / "fixes the X case" — those rot.
- **Single-pass writing.** Write it right the first time; no half-finished
  alternate paths, no half-finished implementations — either it works or
  it isn't there.
- **Test in the running app before reporting done.** For renderer/UI work,
  eyeballing the result matters more than the type-check passing.

## Work rhythm

- Terse updates. State what you found, what you're changing, move on. Skip
  "Let me look at...", "I'll now...", and end-of-turn recaps.
- Exploratory questions: 2–3 sentences + a recommendation, then ask.
- Concrete asks: just do it.
- Auto mode is often on. Don't stop for permission on local, reversible
  work. Still ask before destructive ops.

## Path tracer specifics

`src/PathTrace.metal` is the shader (vertex, path-trace fragment, display
fragment); `src/PathTraceRenderer.mm` is the Obj-C++ resource management.
The shader has grown touchy — read the whole bounce loop before changing
the medium / glass paths.

Key invariants:
- **Coordinate space:** the shader works in *grid space*. `ray_origin_world`
  is rotated to `ray_origin = (x, -z, y)` to match the rasterizer; all
  bounce-loop distances are in voxel units.
- **`medium_mat` skips same-material cells in the DDA** — a connected run
  of glass reads as one medium; refraction fires only at true air↔glass
  boundaries.
- **`medium_entry` + `medium_albedo` carry Beer-Lambert state.** Tint is
  `pow(medium_albedo, distance)`, 1-voxel reference depth in Absorption
  mode (matches Magica); probabilistic mode uses surface_albedo.
- **The DDA reports medium-exit boundaries** (skip-mat → empty cell /
  empty chunk / AABB-out), all returning `hit=true, cell_val=0`.
- **`t_hit` is parametric distance from the *clipped* origin** (post-AABB),
  not the world ray origin.
- **Color space.** Palette is sRGB on disk; decoded to linear on upload,
  re-encoded in the display fragment.
- **VNDF GGX, not naive GGX** — `ggx_sample_vndf` is Heitz 2018.

## Things that look weird but are intentional

- `transparency` is a probabilistic split between glass-refract and
  diffuse-fallback, *not* an absorption modulator. Paul prefers it over
  Magica's on aesthetic grounds.
- `_ior` from MATL is stored as the offset above 1.0 (`_ior=0.3` → IOR 1.3).
  MagicaVoxel convention.
- The grid's "loose" bounds aren't retightened on `Set(0)` — fine in
  practice (we only erase via stroke-undo, which restores prior cells) but
  a gotcha if a tool ever permanently shrinks the model.
- `PreviewOverlay`, `PreviewOps`, and `PanelState`'s ImGui-era structs are
  dormant relics — kept cheap, only `PreviewOverlay::active` is live.
- The `skip` param on `ViewContext::ComputeTargetCell` / `RaycastIgnoring`
  has no live callers (Brush stopped populating `drag_skip_`); plumbing +
  `CellBitmap` kept for a future tool.
- Bridge enums use `NS_ENUM(NSInteger, …)` + `NS_SWIFT_NAME(case)` for
  idiomatic Swift `.brush` cases.
- `_brushEngine` and `_shapeEngine` share one `MTLCommandQueue` — they're
  mutually exclusive at the gesture level, and serializing them off the
  frame queue is what keeps mid-stroke latency low.
```
