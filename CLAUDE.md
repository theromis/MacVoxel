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
  Shape + Generator commits. Dispatch-on-state-change enforced via
  `Tool::ShouldDispatch`. Face and Brush stayed on their specialized
  commit paths pending a `preview_rem` mask refactor — see the
  "Tool abstraction" section below.

The CPU `PreviewOverlay` is dormant — every active-development tool
now writes `tex_t` instead. The rasterizer still binds the legacy
`buf_coarse_grid` + `buf_chunk_pool` slot for the FloatingBuffer
(selection lift/paste/move-drag), which stays sparse because the FB
can wander outside the EditVolume during drag.

Deferred polish, not yet implemented:

- Brush-size quick-keys (`[` / `]`). Tool / mode letter keys
  (V / L / B / F / M / T / R / G) are wired in `MetalScene` keyDown.
- Drag-drop a `.vox` onto the running window (cold-launch via Finder
  Open With works through `.onOpenURL`).
- Theme parity vs the old `ui/Theme.cpp` pro-app dark.
- **`preview_rem` mask texture**: required to migrate Face commit
  + Brush kernel onto commit_generic (Phases 2.3 / 2.4 of the Tool
  refactor — see plan `happy-juggling-volcano.md`). Without the
  mask, Remove-mode preview cells would render as visible color
  during the drag instead of as "hidden doc cells".
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
│                          pyramid / torus / perlin — thread-per-
│                          cell-of-dispatch-bbox, writes palette to
│                          tex_t when inside shape and in bounds,
│                          else 0.
│
│   Editor state — the EditorContext bundle
├── EditorContext.{h,cpp}  Single-document editor context.
├── ToolState.h            `ToolSettings`. (File still named ToolState
│                          for git-history reasons.)
├── GeneratorState.h       Active generator kind + Params.
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
├── BrushOps.{h,cpp}       LEGACY CPU brush. Still compiles. The
│                          preview=true path is unused by current
│                          tooling but `ComputeNewCellValue` is still
│                          reachable from the brush kernel's CPU-side
│                          mode rules.
├── BrushTool.{h,cpp}              Brush — writes tex_a directly
│                                  (commit_generic migration deferred).
├── ShapeTool.{h,cpp}              Line / Circle / Square / Box.
│                                  Writes tex_t, commits via
│                                  commit_generic. BeginShapeAnchor
│                                  free function exposed for Generator.
├── FaceTool.{h,cpp}               CPU flood + GPU stamp_cells per
│                                  mouseDragged (the specialized
│                                  scatter path stays until preview_rem
│                                  unblocks commit_generic migration).
│                                  Wall flood-fill via FloodCoplanarEmpty.
├── GeneratorTool.{h,cpp}          Persistent gizmo (drag-out → idle →
│                                  commit). Tick-time dirty check via
│                                  ShouldDispatch. Commit() exposed
│                                  publicly for Enter-key handler.
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
   pre-stroke   │  ┌─────────────────────────────────────┐ │
   reads       ─┼─►│  oracle for "is doc[cell] != 0?"    │ │
   during      │  │  during brush stroke. drag_skip_cells│ │
   stroke      │  │  is computed from this.              │ │
                │  └─────────────────────────────────────┘ │
                └────────────────────┬─────────────────────┘
                                     │ end-of-stroke
                                     │ ApplyChanges(diff)
                                     ▼
                ┌──────────────────────────────────────────┐
                │  VoxelGrid          (CPU, sparse chunks) │
                │  ─ on-disk + .vox load/save format       │
                │  ─ EditHistory's per-cell records        │
                │  ─ Picking (Raycast.cpp DDA)             │
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
                │   ─ brush / shape / face / generator     │
                │     kernels WRITE this during a stroke   │
                │   ─ oracle (16³ R8Uint) for empty-skip   │
                │     in the rasterizer DDA                │
                │                                          │
                │  Companion: tex_t (preview, 256³ R8Uint) │
                │   ─ shape / face / generator preview     │
                │   ─ composited over tex_a by rasterizer  │
                │     when `preview_active`                │
                │   ─ previewOracleTexture (16³)           │
                └──────────────────────────────────────────┘
```

During a stroke:
1. CPU: pre-stroke `VoxelGrid` and `VoxelVolume.shadow` are byte-equal
   inside the EditVolume (debug-build asserted in `Document::SetCell`).
2. GPU compute kernel writes `tex_a` (brush) or `tex_t` (shape /
   face / generator). The CPU side stays frozen.
3. Picking uses CPU `VoxelGrid` + a `drag_skip_cells` set the
   controller populated from the brush footprint (using
   `volume_shadow.Get` as the still-pre-stroke oracle). The skip
   set makes raycasts behave as if the new cells weren't there yet —
   the next stamp targets the original surface.
4. On `OnMouseUp`, the controller:
   - `waitForPendingWork` on the engine's queue,
   - blits the stroke's bbox of `tex_a` back to CPU,
   - diffs against `volume_shadow` (which is still pre-stroke state),
   - emits a `CellChange[]` diff,
   - calls `doc.ApplyChanges(diff)` to bring `grid` + `shadow` up to
     date, and `history.RecordBatch(diff)` to log undo,
   - drains `volume_shadow.TakeDirtyChunks()` (the kernel already
     wrote `tex_a` so the next syncFromVolume should be a no-op),
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
  - `Tick` (per-frame, used by Generator for dirty-checking the gizmo)
  - `DrawOverlay` (overlay rendering — only Generator has one today)
  - `IsDragging` / `Cancel`
  - `DispatchParamsHash` + `ShouldDispatch` (the dispatch-on-state-change
    helper — see "Tool perf rule" below)

| Tool | File | Notes |
| --- | --- | --- |
| Brush | `BrushTool.{h,cpp}` | Writes `tex_a` directly (no commit pass yet — Phase 2.4 deferred behind `preview_rem`). |
| Shape | `ShapeTool.{h,cpp}` | Line/Circle/Square/Box. Writes `tex_t`, commits via `commit_generic`. `BeginShapeAnchor` is a free function here, also called by Generator. |
| Face | `FaceTool.{h,cpp}` | Still on the per-cell scatter path (`shape_stamp_cells` + `shape_commit_cells`) — Phase 2.3 migration deferred behind `preview_rem`. |
| Generator | `GeneratorTool.{h,cpp}` | Persistent gizmo (drag-out → idle-with-handles → commit). Public `Commit` so MetalScene's Enter-key handler can fire it. `HasActiveGizmo` for the dispatcher's special-case intercept. |

`EditEngine` (`src/EditEngine.{h,mm}`) is the pure-C++ façade tools
call into instead of the old `std::function` closures. The Obj-C++
impl wraps `BrushEngine` / `ShapeEngine` / `GeneratorEngine` /
`VolumeTexture` and handles world↔texture-local translation for the
bbox-shaped methods.

The unified commit kernel `commit_generic` (in `ShapeKernel.metal`)
implements the MagicaVoxel `shader_0018.glsl` shape — bm-parameterized
blend (Add / Erase / Replace / Intersect) + brush-source selector
(`tex_t` vs constant fill). Shape + Generator commits route through
it. Face and Brush still use specialized paths because their
Remove-mode semantics need a `preview_rem` mask texture (deferred)
to avoid making erase-preview cells render as visible color during
the drag.

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
  - BrushTool skips — each stamp is at a new cursor cell, and
    `BrushTool::StampAtCursor`'s per-cell `last_drag_edit_cell` check
    already covers the case.

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
- `BrushOps`'s `StampBrushFootprint(preview=true)` no longer has
  any active callers, but the function compiles and the C++ types
  it uses (`ComputeNewCellValue`) are still pulled in by the brush
  controller's mode rules. Don't delete without auditing.
- `main.mm` is intentionally tiny — argv check + Swift entry call.
- Bridge enums use `NS_ENUM(NSInteger, …)` with `NS_SWIFT_NAME(case)`
  on each entry so Swift gets idiomatic `.x` / `.brush` cases.
- `_brushEngine` and `_shapeEngine` share a `MTLCommandQueue` (the
  dedicated brush queue) — they're mutually exclusive at the gesture
  level and serializing them off the rasterizer's frame queue is
  what keeps mid-stroke latency low.
