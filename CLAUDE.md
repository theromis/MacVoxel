# Working in this repo

A note for the next Claude session that lands here. Read this first.

## What this is

MacVoxel — a native macOS voxel editor + path tracer. SwiftUI shell
over an Obj-C++ bridge over a C++20 core, with Metal for the renderer
and overlays. The README has the user-facing summary; this file is
for orienting on the code.

## Where development is

The SwiftUI port is settled: all seven panels native, the AppKit shell
(`AppDelegate`, `VoxelView`) and `third_party/imgui` are gone. The
big in-flight work is the **Magica-inspired GPU-authoritative
editing refactor** (`/Users/pstarr/.claude/plans/okay-despite-some-
reasonable-sequential-torvalds.md`), shipped as the A / B series of
commits on `main`. As of 2026-05-16:

- **A0-A2**: voxels as a `texture3d<R8Uint, 256³>` (`VolumeTexture`)
  mirrored by a CPU shadow (`VoxelVolume`); rasterizer reads the
  doc texture directly via a 16³ chunk-occupancy oracle.
- **B1-B2**: brush is a Metal compute kernel writing the doc texture
  directly. Async dispatch (no `waitUntilCompleted` mid-stroke),
  CPU `VoxelGrid` + `VoxelVolume` stay frozen at pre-stroke state,
  end-of-stroke bbox readback diffs against the shadow to build the
  per-cell history.
- **B3a-B3c**: shape tools, generator, and face tool all use a
  preview texture (`tex_t`) the rasterizer composites over the doc.
  Each tool's kernel writes `tex_t`; commit kernel promotes it into
  the doc + clears `tex_t`.
- **Tool/EditEngine refactor (2026-05-17)**: closure-bag controllers
  replaced by a `Tool` base class + `ToolRegistry` + a pure-C++
  `EditEngine` façade. Unified `commit_generic` MSL kernel covers
  every volume-writing tool's commit. Dispatch-on-state-change
  enforced via `Tool::ShouldDispatch`. See "Tool abstraction" below.
- **preview_rem mask (2026-05-19)**: companion R8Uint 256³ + 16³
  oracle alongside `tex_t`. Tools' Remove-mode strokes write a
  non-zero mask into `preview_rem`; the rasterizer reads it as a
  cell-skip so doc cells "disappear" live during the drag.
  `commit_generic bm=Erase` consumes the mask. Unblocked the Face
  and Brush migrations onto `commit_generic`.
- **Mutators + hover preview (2026-05-21)**: third tool category —
  cursor-AOE like a Brush, parameterized like a Generator, but reads
  existing voxel state in its AOE and emits a heterogeneous edit.
  Foliage v1 (grow new voxels adjacent to seed-color cells) is the
  first kind. Same change introduced the hover-preview architecture:
  rasterizer `preview_alpha` uniform alpha-blends preview cells over
  whatever's behind them; `Tool::Tick` now takes a `ViewContext` so
  per-frame hover dispatches can pick the cursor cell; Brush + Mutator
  both dispatch their kernel into `tex_t` on cursor-cell change at
  alpha 0.55, clearing the previous frame's bbox via
  `clearPreviewBbox`. See "Mutator architecture" + "Hover preview"
  below.
- **Tree generator (2026-05-29)**: a new `gen::Kind::Tree` that draws
  a recursive-branching tree entirely on the GPU — no CPU skeleton,
  no segment buffer. The kernel evaluates a fixed-depth K=3 branching
  tree per cell (capsule-SDF union, 5 nested levels unrolled), each
  child's pose derived from its parent's tip. Deepest-level branches
  stamp a separate palette index so the result pairs with the Foliage
  Mutator. Reuses the shared `Params` / Perlin-slider plumbing rather
  than adding new fields. We first tried a KIFS (fold-based fractal)
  approach and abandoned it — see "Tree generator" below for the
  algorithm and the KIFS post-mortem.

The CPU `PreviewOverlay` is dormant — every active-development tool
now writes `tex_t` instead. The rasterizer still binds the legacy
`buf_coarse_grid` + `buf_chunk_pool` slot for the FloatingBuffer
(selection lift/paste/move-drag), which stays sparse because the FB
can wander outside the EditVolume during drag.

Deferred polish, not yet implemented:

- Brush-size quick-keys (`[` / `]`). Tool / mode letter keys
  (V / L / B / F / U / M / T / R / G) are wired in `MetalScene` keyDown
  (U = Mutator).
- Drag-drop a `.vox` onto the running window (cold-launch via Finder
  Open With works through `.onOpenURL`).
- Theme parity vs the old `ui/Theme.cpp` pro-app dark.
- 2D-brush variants of the shape kernels (`brush_3d == 0`) render
  nothing in `shape_main` — would need either an in-plane mask or a
  CPU fallback.

## Where things live

```
src/
├── main.mm                Slim entry: argv `render` → CliRender;
│                          otherwise → MacVoxelRunApp (Swift @_cdecl)
│                          → SwiftUI App.main().
├── CliRender.mm           Headless `MacVoxel render` subcommand.
│                          Device-create precedes LoadVox so
│                          VoxelVolume can attach the Metal texture.
│
│   Document & geometry
├── Document.h             { VoxelGrid grid, Palette palette,
│                          EditVolume volume, VoxelVolume
│                          volume_shadow, path, versions, SetCell(),
│                          ApplyChanges(), ClearCells(),
│                          ReseedVolumeShadow() }.
├── VoxelGrid.{h,cpp}      Sparse 16³-chunk hash-map grid. ApplyChanges
│                          batches diffs by chunk to amortize the
│                          hashmap lookup across all cells in that
│                          chunk. `CellChange` struct lives here
│                          (ABI-compatible with BrushChange).
├── VoxelVolume.{h,cpp}    Dense 256³ uchar shadow of the in-volume
│                          cells; 16³-chunk dirty bitset. Phase A1's
│                          write-through cache, now a pre-stroke
│                          oracle for the GPU-authoritative brush
│                          path. Reads outside the EditVolume return
│                          0; writes outside are silently dropped.
├── EditVolume.h           Fixed 256³ canonical edit region.
├── Palette.{h,cpp}        256-entry color + Material array.
├── Material.h             Material PBR params.
├── VoxFile.{h,cpp}        MagicaVoxel .vox load/save.
├── CellKey.h              21-bit-per-axis pack/unpack int64 cell keys.
├── Camera.{h,cpp}         Orbit camera.
├── Raycast.{h,cpp}        CPU DDA for picking (still on VoxelGrid
│                          since the GPU-authoritative brush keeps
│                          grid current via end-of-stroke sync).
├── Shapes.{h,cpp}         Cell enumerators: Bresenham3D, planar
│                          disc/square/box, coplanar floods (the
│                          color-matching one for voxel-face Face
│                          and the empty-matching one for wall Face).
│
│   GPU resources & kernels
├── VolumeTexture.{h,mm}   Per-doc Metal resource container:
│                          tex_a (R8Uint 256³, read_write) for the
│                          doc; oracle (R8Uint 16³) for chunk-skip;
│                          previewTex (R8Uint 256³) — tex_t for shape
│                          / face / generator live previews;
│                          previewOracleTexture (R8Uint 16³).
│                          syncFromVolume drains
│                          VoxelVolume::TakeDirtyChunks and
│                          replaceRegion-uploads to tex_a + oracle.
├── BrushEngine.{h,mm}     Brush kernel dispatcher. Dedicated
│                          MTLCommandQueue (off the rasterizer's
│                          frame queue). Async dispatch; readback
│                          path for end-of-stroke bbox blit.
├── BrushKernel.metal      brush_main: square/circle × 2D/3D
│                          footprints, Add/Remove/Paint. Writes
│                          tex_a directly + marks doc oracle on
│                          non-empty cells.
├── ShapeEngine.{h,mm}     Shape / face / generator-commit kernel
│                          dispatcher. Also shares brush's queue.
│                          dispatchPreview / dispatchLineProjectPreview
│                          / dispatchStampCells / dispatchCommitCells
│                          / clearPreviewBbox / commitShape.
├── ShapeKernel.metal      shape_main (Line/Circle/Square/Box,
│                          filled + shell, square + circle brush
│                          footprints, Add/Paint with proper
│                          mode-on-tex_a checks), shape_line_project_main
│                          (Line's project mode — iterates CPU-
│                          enumerated cell list per thread),
│                          shape_stamp_cells + shape_commit_cells
│                          (per-cell scatter, used by Face),
│                          shape_clear, and commit_generic — the
│                          Magica `shader_0018.glsl` blend
│                          (bm = 1/Add, 2/Erase, 3/Replace, 4/Intersect;
│                          source = tex_t or constant fill). Shape and
│                          Generator route through commit_generic.
├── GeneratorEngine.{h,mm} Generator kernel dispatcher. One PSO per
│                          Kind. dispatchInto writes tex_t directly;
│                          the union of (current_bounds,
│                          last_bounds_dispatched) means shrinking
│                          bounds naturally clear in-place.
├── Generators.metal       generate_ellipsoid / cylinder / cone /
│                          pyramid / torus / perlin / tree / helix —
│                          thread-per-
│                          cell-of-dispatch-bbox, writes palette to
│                          tex_t when inside shape and in bounds,
│                          else 0.
├── MutatorEngine.{h,mm}   Mutator kernel dispatcher. One PSO per
│                          Kind (v1: Foliage). dispatchInto writes
│                          a delta into tex_t (+ later preview_rem
│                          for Erode-style kinds) based on the
│                          live-composited read of tex_a + tex_t +
│                          preview_rem.
├── Mutators.metal         foliage_main — thread-per-cell-of-AOE-bbox,
│                          live-composited read via mutator_effective
│                          helper, 6-neighbor seed-color predicate,
│                          PCG3D `hash3(cell, stroke_id)` density
│                          gate. Future kinds slot in next to it.
│
│   Editor state — the EditorContext bundle
├── EditorContext.{h,cpp}  Single-document editor context.
├── ToolState.h            `ToolSettings`. (File still named ToolState
│                          for git-history reasons.)
├── GeneratorState.h       Active generator kind + Params.
├── Mutators.h             `mutators::Kind` + `Params` (pure C++).
├── MutatorState.h         Active mutator kind + tuned params.
├── PanelState.h           Drag-coalescing state for SwiftUI panels.
├── RenderState.h          `RenderSettings` + `RenderProgress`.
├── EditHistory.{h,cpp}    Stroke-grained undo/redo. `RecordBatch`
│                          (B1.5) takes a `CellChange[]` and reserves
│                          capacity up front; per-cell dedupe via
│                          current_index_ stays for cross-stamp
│                          coalescing.
├── Selection.{h,cpp}      Box / per-voxel selection set.
├── SelectionOps.{h,cpp}   RotateSelection, FlipSelection,
│                          LiftSelectionToFloating, etc.
├── FloatingBuffer.h       Lifted-selection grid + offset (still
│                          sparse VoxelGrid; can wander out of vol).
├── FloatingBufferOps.{h,cpp}  Lift / commit / paste / resample.
├── Clipboard.h            Cut / copy / paste of selected regions.
├── PreviewOverlay.h       LARGELY DORMANT. The `active` flag is
│                          still set by tools so the rasterizer's
│                          `preview_active` uniform fires, but the
│                          additions/removals VoxelGrids inside are
│                          no longer populated by current-gen tools.
├── PreviewOps.{h,cpp}     `CommitPreviewOverlayThroughHistory` —
│                          only called by legacy paths; the new
│                          GPU-authoritative tools commit via
│                          ShapeEngine's kernels + diff readback.
│
│   Per-tool gesture state & dispatch — see "Tool abstraction" below
├── Tool.h                 Abstract base class for volume-writing tools.
├── ToolRegistry.{h,cpp}   Owns one of each Tool subclass; MetalScene
│                          dispatches via `ToolFor(ToolKind)`.
├── EditEngine.{h,mm}      Pure-C++ façade wrapping BrushEngine /
│                          ShapeEngine / GeneratorEngine / VolumeTexture.
├── InteractionState.h     Shared gesture state only: drag_mode,
│                          last_drag_location, hover, selection-tool
│                          sub-structs, the two-click anchor (shared
│                          between Shape and Generator), and a single
│                          bool gen_gizmo_active mirrored from
│                          GeneratorTool for SelectionOverlay's benefit.
│                          The per-tool gesture state lives privately
│                          inside each Tool subclass.
├── Input.h                MouseEvent + ModifierFlags — AppKit-free.
├── ViewContext.{h,cpp}    Stateless picking + drag-projection.
│                          PickFace falls back to IntersectVolumeWall
│                          so the Face tool can fill wall/floor
│                          empty space. IntersectVolumeWall's near-
│                          wall skip checks whether the camera is
│                          actually outside the wall (the midpoint
│                          heuristic broke when the camera sat
│                          inside the volume on an axis).
├── BrushTool.{h,cpp}              Brush — writes tex_t / preview_rem
│                                  per mode, commits via
│                                  commit_generic at mouseUp.
├── ShapeTool.{h,cpp}              Line / Circle / Square / Box.
│                                  Writes tex_t (Add/Paint) or
│                                  preview_rem (Remove); commits via
│                                  commit_generic. BeginShapeAnchor
│                                  free function exposed for Generator.
├── FaceTool.{h,cpp}               CPU flood + GPU shape_stamp_cells
│                                  per mouseDragged (palette splits
│                                  the stamp between tex_t and
│                                  preview_rem). Commits via
│                                  commit_generic. Wall flood via
│                                  FloodCoplanarEmpty.
├── GeneratorTool.{h,cpp}          Persistent gizmo (drag-out → idle →
│                                  commit). Tick-time dirty check via
│                                  ShouldDispatch. Commit() exposed
│                                  publicly for Enter-key handler.
├── MutatorTool.{h,cpp}            Cursor-AOE Mutator. Tick dispatches
│                                  Foliage kernel into tex_t on cursor-
│                                  cell change w/ hover stroke_id (ghost
│                                  preview at alpha 0.55); OnMouseDown
│                                  adopts the hover stroke_id so the
│                                  first stamp = ghost cells, just
│                                  promoted to opaque. DrawOverlay walks
│                                  AOE-plane bitmaps and XOR-emits
│                                  boundary edges where AOE contacts
│                                  doc surfaces / volume walls.
├── MarqueeController.{h,cpp}      Selection (unchanged).
├── BoxSelectController.{h,cpp}    Selection (unchanged).
├── FloodSelectController.{h,cpp}  Selection (unchanged).
├── MoveSelectController.{h,cpp}   Selection-drag (unchanged).
├── XformHandleController.{h,cpp}  Transform gizmo (unchanged).
│
│   View shell + renderers
├── MetalScene.{h,mm}      MTKView subclass — *thin shell + dispatcher*.
│                          Owns: Metal queues (main + dedicated brush
│                          queue), RaycastRenderer, PathTraceRenderer,
│                          SceneOverlayRenderer, GeneratorEngine,
│                          BrushEngine, ShapeEngine, VolumeTexture,
│                          Camera, InteractionState, ToolRegistry,
│                          EditEngine. mouseDown/Dragged/Up forward
│                          to _activeTool (set on mouseDown via
│                          _toolRegistry->ToolFor(_ctx->tool.tool));
│                          selection tools and the gen-gizmo intercept
│                          have their own branches.
├── RaycastRenderer.{h,mm} Rasterizer fragment shader. DDA samples
│                          tex_a directly (with chunk-skip via
│                          oracle), preview_tex when active (with
│                          its oracle), buf coarse+pool for FB. No
│                          more doc coarse+pool path. Per-frame
│                          tex_a sync moved out to MetalScene.
├── PathTraceRenderer.mm   Path tracer (render mode). Still reads
│                          VoxelGrid — kept on the legacy coarse+pool
│                          path per the plan (rewriting its 1760-
│                          line DDA was out of scope). VoxelGrid is
│                          kept current via end-of-stroke diff
│                          application so the path tracer sees the
│                          right state in Render mode.
├── PathTrace.metal        MSL: pt_fragment + display_fragment.
├── SceneOverlayRenderer.{h,mm}  Drains an OverlayDraw's vertex list
│                                as a Metal triangle list.
├── Overlay.metal          MSL vertex/fragment for the overlay pass.
├── OverlayDraw.{h,cpp}    Immediate-mode 2D primitives.
├── SelectionOverlay.{h,cpp}    `DrawSelection` + `DrawHover`.
│
│   SwiftUI shell — see "SwiftUI shell" section below
└── swift/                 (Unchanged from the SwiftUI port.)
```

## Voxel storage architecture (the B-phase model)

Three representations live in `Document` and stay in sync at known
points; **none of them is unconditionally authoritative** — which
one is "the truth" depends on the phase of the edit.

```
                ┌──────────────────────────────────────────┐
                │  VoxelVolume.shadow  (CPU, dense 256³)   │
                │                                          │
                │  ─ end-of-stroke diff target             │
                │  ─ pre-stroke oracle for tools that      │
                │    need to read occupancy during a       │
                │    stroke (Face flood, Shape add filter) │
                └────────────────────┬─────────────────────┘
                                     │ end-of-stroke
                                     │ ApplyChanges(diff)
                                     ▼
                ┌──────────────────────────────────────────┐
                │  VoxelGrid          (CPU, sparse chunks) │
                │  ─ on-disk + .vox load/save format       │
                │  ─ EditHistory's per-cell records        │
                │  ─ Picking (Raycast.cpp DDA) — frozen at │
                │    pre-stroke state for the whole drag,  │
                │    so picks always hit the original      │
                │    surface without a skip set            │
                │  ─ Path tracer's chunk-pool source       │
                │  ─ Selection ops                         │
                └────────────────────┬─────────────────────┘
                                     │ syncFromVolume
                                     │ (per-chunk replaceRegion)
                                     ▼
                ┌──────────────────────────────────────────┐
                │  VolumeTexture.tex_a   (GPU, R8Uint 256³)│
                │                                          │
                │   ─ rasterizer fragment samples this     │
                │   ─ commit_generic at mouseUp writes it; │
                │     during a stroke tex_a is FROZEN at   │
                │     pre-stroke state                     │
                │   ─ oracle (16³ R8Uint) for empty-skip   │
                │                                          │
                │  Companions: tex_t + preview_rem (256³)  │
                │   ─ tex_t: Add / Paint preview (palette) │
                │   ─ preview_rem: Remove preview (mask)   │
                │   ─ rasterizer composites both over tex_a│
                │     when `preview_active`                │
                │   ─ each has its own 16³ oracle          │
                └──────────────────────────────────────────┘
```

During a stroke:
1. CPU: pre-stroke `VoxelGrid` and `VoxelVolume.shadow` are byte-equal
   inside the EditVolume (debug-build asserted in `Document::SetCell`).
2. GPU compute kernel writes `tex_t` (Add / Paint preview) or
   `preview_rem` (Remove mask) — never `tex_a`. The rasterizer
   composites both over `tex_a`.
3. Picking uses the CPU `VoxelGrid`, which is frozen at pre-stroke
   state for the whole drag — so picks always hit the original
   surface for free, no skip set needed.
4. On `OnMouseUp`, the tool:
   - calls `commit_generic` over the stroke bbox with the
     appropriate `bm` (1=Add, 2=Erase, 3=Replace, 4=Intersect),
     which promotes the preview surface into `tex_a` and clears
     the consumed surface,
   - `waitForPendingWork` on the engine's queue,
   - blits the stroke's bbox of `tex_a` back to CPU,
   - diffs against `volume_shadow` (still pre-stroke state),
   - emits a `CellChange[]` diff,
   - calls `doc.ApplyChanges(diff)` to bring `grid` + `shadow` up
     to date, and `history.RecordBatch(diff)` to log undo,
   - drains `volume_shadow.TakeDirtyChunks()` (commit_generic
     already wrote `tex_a` so the next `syncFromVolume` is a no-op),
   - `doc.BumpGeometry()`.

This is why all three reps stay in sync at every commit point. It
also means: don't read `VoxelGrid` or `volume_shadow` for cells in
the active stroke's bbox — they're stale until commit. Use the
texture (or the controller's local state).

## Tool abstraction

Every volume-writing tool is a `Tool` subclass (`src/Tool.h`) owned
by `ToolRegistry`. The dispatcher in `MetalScene` looks up
`_toolRegistry->ToolFor(_ctx->tool.tool)` at `mouseDown`, stashes
the result in `_activeTool`, and routes subsequent `mouseDragged` /
`mouseUp` events back to that pointer. Selection tools
(Marquee / BoxSelect / FloodSelect / MoveSelect / XformHandle) stay
on their per-controller branches — they don't write to the volume.

The `Tool` virtual interface:
  - `OnMouseDown` / `OnMouseDragged` / `OnMouseUp` (with
    `EditorContext`, `InteractionState`, `ViewContext`, `MouseEvent`,
    `EditEngine&`)
  - `Tick` (per-frame; takes a `ViewContext` so hover-preview tools
    can pick the cursor cell. Generator dirty-checks its gizmo;
    Brush + Mutator dispatch their hover preview kernels)
  - `DrawOverlay` (overlay rendering — Generator draws its gizmo,
    Mutator draws the AOE-contact contour)
  - `IsDragging` / `Cancel`
  - `DispatchParamsHash` + `ShouldDispatch` (the dispatch-on-state-change
    helper — see "Tool perf rule" below)

| Tool | File | Notes |
| --- | --- | --- |
| Brush | `BrushTool.{h,cpp}` | Writes `tex_t` (Add / Paint) or `preview_rem` (Remove); commits via `commit_generic` at mouseUp. `Tick` does the hover ghost dispatch. |
| Shape | `ShapeTool.{h,cpp}` | Line/Circle/Square/Box. Writes `tex_t` / `preview_rem` per mode; commits via `commit_generic`. `BeginShapeAnchor` is a free function here, also called by Generator. |
| Face | `FaceTool.{h,cpp}` | CPU flood + `shape_stamp_cells` (per-cell scatter into `tex_t` for palette != 0, `preview_rem` for palette == 0); commits via `commit_generic`. |
| Generator | `GeneratorTool.{h,cpp}` | Persistent gizmo (drag-out → idle-with-handles → commit). Public `Commit` so MetalScene's Enter-key handler can fire it. `HasActiveGizmo` for the dispatcher's special-case intercept. |
| Mutator | `MutatorTool.{h,cpp}` | Cursor-AOE. `Tick` dispatches Foliage kernel into `tex_t` on cursor-cell change (ghost preview); `OnMouseDown` adopts the hover `stroke_id` for seamless click → opaque handoff. `DrawOverlay` emits the AOE-contact contour. |

`EditEngine` (`src/EditEngine.{h,mm}`) is the pure-C++ façade tools
call into instead of the old `std::function` closures. The Obj-C++
impl wraps `BrushEngine` / `ShapeEngine` / `GeneratorEngine` /
`VolumeTexture` and handles world↔texture-local translation for the
bbox-shaped methods.

The unified commit kernel `commit_generic` (in `ShapeKernel.metal`)
implements the MagicaVoxel `shader_0018.glsl` shape — bm-parameterized
blend (Add / Erase / Replace / Intersect) + brush-source selector
(`tex_t` / `preview_rem` for the preview path, constant fill
otherwise). Every volume-writing tool's commit routes through it.

## Mutator architecture (Foliage v1)

A Mutator is a hybrid of Brush and Generator: cursor-centered AOE
like a brush, parameter-driven like a generator, but the kernel
**reads existing voxel state in its AOE** and emits a delta. This
unlocks the class of "look at the neighborhood, then decide" tools
(foliage growth, erosion, weathering, greebles) that pure-generative
or stateless-brush tools can't express.

Three things in particular are worth knowing:

1. **Live-composited read.** The kernel doesn't sample `tex_a`
   directly — it samples `effective(c) = preview_rem ? 0 :
   (tex_t != 0 ? tex_t : tex_a)`. Inside a single stroke,
   freshly-stamped cells become seeds for the next stamp, so a
   bush *grows* under the cursor instead of just stamping the
   same pattern. The `mutator_effective` helper in
   `Mutators.metal` implements this.

2. **Hover stroke_id handoff.** The hover Tick allocates a
   `hover_stroke_id_` once per uninterrupted hover session and
   uses it as the RNG salt; `OnMouseDown` adopts that same id as
   the drag's `stroke_id_` so the first stamp produces *exactly
   the cells the user was already seeing* — only the preview
   alpha snaps from 0.55 to 1.0. New strokes get a fresh id, so
   re-strokes produce new candidate cells (the path Paul uses to
   thicken a bush by clicking over the same area repeatedly).

3. **Two-pass commit.** mouseUp fires `commit_generic bm=Add`
   then `bm=Erase` over the union bbox. Foliage v1 only writes
   `tex_t` (the Erase pass is a no-op for it), but the
   infrastructure is in place so future kinds that need to
   delete cells (Erode, Weather) wire through the same
   commit-and-readback path.

The contour outline in `MutatorTool::DrawOverlay` is what
distinguishes "didn't fire because not in AOE" from "didn't fire
because the rule said no." For each plane crossing the AOE, build
a 2D bitmap of "barrier cell-faces" (faces between an occupied
doc cell and an empty one, or faces on an edit-volume wall) inside
the AOE footprint, then XOR-walk the 2D edges — emit each edge iff
exactly one of its adjacent cell-faces is a barrier. Interior
shared edges cancel; coplanar runs naturally collapse to single
straight lines without a separate dedup pass.

## Hover preview (ghost composite)

Brush and Mutator dispatch their preview kernel on every frame the
cursor cell or tool params change, *before* a click. The rasterizer
alpha-blends the resulting preview cells over whatever's behind
them at `ctx.preview_alpha = 0.55` (the "ghost"). On `OnMouseDown`
the tool sets `preview_alpha = 1.0` and the same cells re-render
opaque — the ghost feels like it "settled" into place.

Implementation invariants:

- **`Tool::Tick(EditorContext&, InteractionState&, ViewContext&,
  ToolKind active_tool, bool escape, EditEngine&)`** — fires every
  frame from `MetalScene drawInMTKView`. Tools dispatching hover
  previews override Tick and use `vc.ComputeTargetCell` to pick
  the cursor cell.

- **Per-frame bbox clear.** Each tool stores its
  `hover_bbox_{x,y,z}{0,1}_` from the last dispatch and calls
  `EditEngine::ClearPreviewBbox` at the start of every new
  dispatch (or when becoming ineligible — cursor leaves viewport,
  tool switches, Esc). Without this, previous-frame footprint
  cells leak across cursor moves.

- **`ctx.preview_active` + `ctx.preview_alpha`.** A tool that
  *owns* the hover preview sets both (`active = true`, `alpha =
  0.55`) when dispatching, and clears both back to `false` /
  `1.0` when becoming ineligible. The Mutator/Brush mutual-
  exclusion is handled by Tick's `active_tool` check — switching
  tools triggers the outgoing tool's Tick to clear, the incoming
  tool's Tick to set.

- **Rasterizer ghost path.** The DDA captures the first preview
  hit, sets `skip_preview = true` to keep marching, and at the
  terminal hit (doc cell, FB cell, or sky) returns
  `mix(backdrop_color, ghost_color, preview_alpha)`. See the
  `ghost_seen` / `skip_preview` block in `RaycastRenderer.mm`.

The wireframe AOE indicator we briefly tried during development was
redundant with the ghost cells for Brush (Brush ghost == exactly
what Brush will write). Mutator still gets a wireframe via
`DrawOverlay`, but it's the contour outline above, not a floating
cube — that distinguishes AOE reach from rule-filtered output.

## Tree generator (recursive branching, GPU-only)

`gen::Kind::Tree` (`generate_tree` in `Generators.metal`) makes a
tree shape with no CPU work and no extra buffer bindings — the hard
constraint Paul set was "do not touch the CPU." It's a per-cell
distance-field evaluation of an explicit recursive-branching tree:

- A trunk capsule, then K=3 children per node, recursion **unrolled
  to 5 nested levels** (Metal has no recursion, hence the literal
  nesting). Each cell takes the `min` capsule-SDF over every branch;
  `de <= 0` writes a voxel.
- Each child's pose is computed **from scratch** from its parent's
  tip + direction + segment length via `tree_grow_child`: tilt away
  from the parent axis by `base_tilt`, rotate around it by
  `(digit + 0.5) * 2π/K`, both perturbed by a per-branch hash of the
  seed. Length and radius taper by fixed falloffs per generation.
- The deepest level (`level == depth`) routes its capsules to a
  separate `de_leaf` accumulator; everything shallower goes to
  `de_bark`. The kernel writes `perlin_palette_hi` when leaf wins,
  `palette_idx` otherwise. That two-color split is what makes the
  tree pair cleanly with the Foliage Mutator — flood the leaf color
  to grow a canopy without the bark contaminating the seed check.

**Param remapping** (no new `Params` fields — reuses the Perlin
slider plumbing, relabeled in `GeneratorControls`):
  - `noise_octaves` → recursion **Depth** (1..5)
  - `noise_threshold` → **Wildness** (hash-jitter on tilt + rotation)
  - `noise_seed` → re-roll
  - `torus_tube` → trunk/base branch **radius**
  - `palette_idx` → bark color; `perlin_palette_hi` → leaf color
  - `noise_scale` is **ignored** by Tree (left in the struct for the
    shared plumbing).

The gizmo up-axis is fit to `TREE_MAX_HEIGHT` (the geometric series
sum of segment lengths) so the tree fills the bounds; **a roughly
cubical-or-wider gizmo is needed** or the laterally-spreading
branches clip against the side walls.

### Why not KIFS (the post-mortem)

The first instinct — and the genuinely elegant demoscene answer —
was a **KIFS** (Kaleidoscopic Iterated Function System): fold space
with `abs() + diagonal-sort` rotations each iteration, draw one
capsule, divide the SDF by accumulated scale. Two or three lines of
inner loop, fixed cost regardless of branch count. We tried several
variants and abandoned all of them. What broke, in order of
discovery:

1. **A terminal-sphere DE binarizes to nothing.** A proper KIFS
   distance estimator (`length(p)/scale - r`) is tuned for
   *raymarching*, where the surface shows up via SDF gradients. The
   `de <= 0` solid region is essentially the fractal skeleton —
   near-zero volume — so voxelizing it gives an empty or near-empty
   grid.
2. **Union-of-capsules-per-level collapses to the trunk.** Drawing a
   trunk capsule at every fold level *seems* to give volume, but the
   fold's `abs + sort` canonicalization maps every on-axis capsule
   back onto the same y-axis segment — so all levels draw the same
   trunk and no branches appear. A laterally-offset capsule unfolds
   to 8 copies, but a *vertical* offset capsule just makes parallel
   fence-pickets, not outward limbs.
3. **Cumulative rotation + lateral drift.** Chaining each level's
   capsule from the previous tip (forward-folding the endpoint to
   keep them connected) finally produced branches — but each
   iteration adds a fixed tilt+twist, so after ~6 levels the chain
   has spun >3 radians and is *spiraling*, not growing outward. Deep
   iterations either clip outside the gizmo or wrap back in at
   unrelated positions ("detached hovering voxels").

The through-line: KIFS gives you a *fractal attractor*, and a tree
is not its attractor — it's a finite recursive structure where each
branch needs an independent, non-accumulating pose. The explicit
unrolled version costs more per cell (≈3^depth capsule evals, a few
hundred ms at depth 5) but every branch's transform is computed
fresh from its path, so there's no drift and no sparseness. If this
ever needs to be faster, a 16³ branch-bucket oracle or a coarse
bounding-sphere reject per subtree is the move — not a return to
folds.

## Tool perf rule: dispatch only on state change

The single biggest perf lesson from the B3 phase: **don't dispatch
every `mouseDragged` event when the target state hasn't changed**.
Enforced uniformly via `Tool::ShouldDispatch(uint64_t)` + per-Tool
hash construction:
  - ShapeTool hashes endpoint + kind + brush size/shape/3d + mode +
    fill/even toggles (+ raw pixels for project-mode Line).
  - FaceTool hashes `d` + `face_with`.
  - GeneratorTool hashes `gs.active_kind` + bounds + palette + the
    per-kind params; called from `Tick`, not `OnMouseDragged`.
  - MutatorTool hashes cursor cell + kind + foliage params + brush
    size/shape/3d + `stroke_id_`; both the drag-time `OnMouseDragged`
    and the hover-time `Tick` route through the same hash, with a
    separate `hover_last_hash_` so hover and drag dispatches don't
    interfere.
  - BrushTool skips during drag — each stamp is at a new cursor cell,
    and `BrushTool::StampAtCursor`'s per-cell `last_drag_edit_cell`
    check already covers the case. Hover-time Tick uses its own hash
    over cursor cell + mode + brush params.

If you add a new tool, override `Tool::DispatchParamsHash`, call
`ResetDispatchHash()` from your `OnMouseDown`, and gate the kernel
dispatch behind `ShouldDispatch(DispatchParamsHash(...))`.

Other perf rules:
- Keep the kernel dispatch bbox **tight**. Union with previous
  frame's bbox only when needed (to clear stale cells); don't grow
  union across the whole stroke if you don't need to.
- For tools that need a CPU-enumerated cell list (project-mode Line,
  Face), prefer one thread per *cell* (scatter) over one thread per
  bbox cell iterating the list (gather). Scatter scales with cell
  count, not bbox volume.
- Use `volume_shadow.Get` (dense O(1) array) rather than
  `grid.Get` (hashmap) when checking pre-stroke occupancy in hot
  enumeration paths.

## SwiftUI shell

The shell is three layers thick: Swift `@Observable` → Obj-C bridge →
C++ `EditorContext`. Pure C++ types never cross into Swift; everything
Swift sees has an Obj-C interface in `EditorContextBridge.h`.

- **`EditorContextBridge`** (NSObject) owns `std::unique_ptr<EditorContext>`.
- **`EditorState`** (@Observable Swift class) wraps the bridge plus a
  weak `MetalScene?` back-reference. `tick: UInt64` is bumped by a
  10 Hz Timer; computed properties read `_ = tick` first so panels
  re-render at gesture cadence without controllers poking SwiftUI.
- **`MetalScene`** (Obj-C++ MTKView) — all of `VoxelView`'s old work
  minus ImGui. Owns every Metal resource the GPU-authoritative path
  needs and builds every controller closure.

## Build / run loop

```sh
cmake --build build
pkill -f MacVoxel.app/Contents/MacOS/MacVoxel; sleep 0.5; open build/MacVoxel.app
```

The kill-and-relaunch is the right rhythm: AppKit treats `open` on an
already-running bundle as a no-op. Ninja rebuilds are fast (~1–2 s
for a single .mm / .swift file change).

`-Wall -Wextra -Wpedantic -Werror` is on for project sources. There
is no longer any third-party code in the build that needs warning
suppression.

## Headless rendering (use this!)

The same binary has a `render` subcommand that runs the path tracer
without spawning a GUI — write a PNG, exit. Use it for any "did the
renderer change behave the way I think" question.

```sh
build/MacVoxel.app/Contents/MacOS/MacVoxel render \
  --input  test/vox/teapot.vox \
  --output /tmp/check.png \
  --width 512 --height 512 \
  --samples 256 --bounces 5 --seed 1
```

Then `Read /tmp/check.png` to actually see the result.

- `--samples` is per-pixel; 64–256 is usually enough to read shape
  and shading, 1024+ if you need to evaluate noise.
- `--seed` makes the output byte-deterministic. Baseline digest for
  sanity checks: teapot.vox @ 256×256, 32 spp, seed=1 →
  `9b695a3917fb04dfa65e0d3903372b37`. The B-phase commits all
  preserve this (it's exercised after every meaningful change).
- `--no-aces` swaps the ACES tonemap for a plain gamma-2.2 curve.

Headless can't exercise gesture state machines — for tool /
controller work, eyeball in the running app. Screenshot the window
with `screencapture -R x,y,w,h /tmp/foo.png` and `Read` it; the
window position + size come from
`CGWindowListCopyWindowInfo`.

**UI / gesture testing: Paul does it, not you.** Anything that
requires actually moving the mouse, clicking, dragging, or watching
a sequence of frames is Paul's job — he'll exercise the change in
the running app and report back what he sees. Your job is to:

1. Build cleanly (`cmake --build build`).
2. Run the headless md5 sanity check if the renderer / path tracer
   could be affected.
3. Launch the app and (optionally) take a static screenshot of the
   initial state to confirm the panels / chrome look right.
4. Hand off — describe what should happen and ask for results.

Do **not** install `cliclick`, drive `osascript` mouse events,
simulate drags via CGEvent, or otherwise try to puppet the cursor
to test interaction. Those scripts are flaky on the user's machine
(focus stealing, accessibility prompts, coordinate space drift) and
take longer than just asking. Wait for Paul's report.

## Conventions Paul has set

These came up repeatedly during development and are worth not
relitigating:

- **Commits are per-step.** A logical fix or feature is one commit;
  don't bundle unrelated changes. Style: `refactor: short title` /
  `fix: …` / `feat: …` / `chore: …`. Coauthor trailer is
  `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.
- **No unsolicited refactors.** If you're fixing a bug, fix the bug.
  Don't reformat surrounding code unless asked.
- **Comments explain *why*, never *what*.** Single-line is the
  default; multi-paragraph is almost always wrong. No "added in
  P8.3" or "fixes the X case" — those rot.
- **Single-pass writing.** When something is right, write it cleanly
  the first time. No half-finished alternate paths.
- **No half-finished implementations.** Either it works or it isn't
  there.
- **Test the change in the running app before reporting done.** For
  renderer / UI work, eyeballing the result matters more than the
  type-check passing.

## Work rhythm

- Terse updates. State what you found, what you're changing, move
  on. Skip "Let me look at...", "I'll now...", and end-of-turn
  recaps.
- For exploratory questions, give a 2–3 sentence answer with a
  recommendation and ask whether to proceed.
- For concrete asks, just do it.
- Auto mode is often on. Don't stop for permission on local,
  reversible work. Still ask before destructive ops.

## Path tracer specifics

`src/PathTrace.metal` is the path-tracer shader (vertex, path-trace
fragment, display fragment); `src/PathTraceRenderer.mm` is the
Obj-C++ resource management around it. The shader has grown enough
that edits are touchy — read the whole bounce loop before changing
the medium / glass paths.

Key invariants in the shader:

- **Coordinate space:** the shader works in *grid space*, not world
  space. `ray_origin_world` is rotated to `ray_origin = (x, -z, y)`
  to match the rasterizer's convention. All distances inside the
  bounce loop are in voxel units.
- **`medium_mat` skips same-material cells in the DDA.** A connected
  run of glass voxels reads as one medium — refraction fires only at
  true air↔glass boundaries.
- **`medium_entry` + `medium_albedo` carry Beer-Lambert state.**
  Tint is `pow(medium_albedo, distance)` — a 1-voxel reference depth
  in Absorption mode (matches MagicaVoxel). Probabilistic mode uses
  `medium_albedo = surface_albedo`.
- **The DDA reports medium-exit boundaries.** Three transitions:
  skip-mat→empty cell, skip-mat→empty chunk, skip-mat→AABB-out. All
  return `h.hit = true, h.cell_val = 0`.
- **`t_hit` is parametric distance from the *clipped* origin** (after
  AABB intersection), not from the world ray origin.
- **Color space.** Palette is sRGB on disk; the renderer decodes to
  linear on upload and the display fragment re-encodes.
- **VNDF GGX, not naive GGX.** The microfacet sampler in
  `ggx_sample_vndf` is Heitz 2018 visible-normal sampling.

## Things that look weird but are intentional

- `transparency` controls a probabilistic split between glass-refract
  and diffuse-fallback, *not* an absorption modulator. Paul prefers
  the current behavior on aesthetic grounds vs Magica's.
- `_ior` from MATL is stored as the offset above 1.0 (so `_ior=0.3`
  in the file is IOR 1.3 to us). MagicaVoxel convention.
- The grid's "loose" bounds aren't retightened on `Set(0)`. In
  practice we only erase via stroke-undo, which restores prior
  cells, so it doesn't matter — but it's a correctness gotcha if
  you ever grow a tool that permanently shrinks the model.
- `ToolState.h` defines `ToolSettings` (not `ToolState`);
  `RenderState.h` defines `RenderSettings` + `RenderProgress`. The
  file names date from before a rename pass.
- `PanelState.h` still defines a couple of drag-coalescing structs
  the SwiftUI panels never touch (`palette_drag`,
  `palette_context_slot`, `save_render_clicked`, `show_imgui_demo`)
  — relics from the ImGui panels, dormant but cheap to keep.
- `PreviewOverlay`'s additions/removals VoxelGrids are still defined
  but no longer populated by current-gen tools. The `active` flag
  is the only field that matters (sets the rasterizer's
  `preview_active` uniform). Keep the file for the FB overlay-pool
  rendering path until that migrates too.
- The `skip` parameter on `ViewContext::ComputeTargetCell` /
  `RaycastIgnoring` is no callers' arg anymore (Brush no longer
  populates `drag_skip_`). The plumbing stays for now in case a
  future tool needs it; the `CellBitmap` type stands ready.
- `main.mm` is intentionally tiny — argv check + Swift entry call.
- Bridge enums use `NS_ENUM(NSInteger, …)` with `NS_SWIFT_NAME(case)`
  on each entry so Swift gets idiomatic `.x` / `.brush` cases.
- `_brushEngine` and `_shapeEngine` share a `MTLCommandQueue` (the
  dedicated brush queue) — they're mutually exclusive at the gesture
  level and serializing them off the rasterizer's frame queue is
  what keeps mid-stroke latency low.
