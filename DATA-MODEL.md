# Data and Interaction Model

This document describes the model MacVoxel uses today: how scene data is stored,
what non-scene state exists around it, and how edits flow through CPU state into
the Metal renderers. It is written as a refactor aid, especially for cleaning up
the UI state before a SwiftUI port.

## Scene Representation

The app is currently single-document. `Document` owns the durable scene state:

- `VoxelGrid grid`
- `Palette palette`
- `std::string path`
- `uint64_t version`

`Document::version` is the broad invalidation counter. Most code increments it
after grid or palette mutations, and both renderers cache against it. The
counter is deliberately coarse: it says "the document changed", not which part
changed. More detailed grid invalidation lives inside `VoxelGrid`.

### VoxelGrid

`VoxelGrid` is a sparse, signed-coordinate voxel grid. Filled cells store a
`uint8_t` palette index; zero means empty. Storage is a hash map from chunk
coordinate to a dense `16 x 16 x 16` chunk:

- `ChunkCoord` is the chunk-space coordinate.
- `Chunk::cells` is 4096 bytes of palette indices.
- `Chunk::filled_count` tracks whether a chunk contains any non-empty cells.
- `Chunk::version` increments when cells in the chunk change, and also when a
  neighbor changes on a shared chunk boundary because visible faces may change.
- `VoxelGrid::dirty_chunks_` records chunk coordinates changed since the last
  renderer drain.

`VoxelGrid::Set` is the only mutating primitive. It allocates a chunk on first
non-zero write, removes an empty chunk after its last voxel is cleared, updates
total filled count, expands loose bounds, bumps the edited chunk's version, and
marks dirty chunks. If the edited voxel lies on a chunk boundary, existing
neighbor chunks are also bumped and marked dirty.

Bounds are loose after deletions. They expand on additions and reset on `Clear`,
but are not tightened when voxels are removed. This is acceptable for framing and
renderer extents, but anything needing exact post-delete bounds must compute
them or use a selection/floating-buffer bound.

`VoxelGrid::Clone` performs a deep copy of chunks without copying the dirty
queue. It is used as a lossless source snapshot for floating-buffer transform
resampling.

### Palette and Materials

`Palette` is a fixed 256-entry array of RGBA colors plus a parallel 256-entry
array of `Material`. Palette index 0 is the empty slot and normally has
transparent color semantics. Indices 1 through 255 are paintable colors.

Materials currently include diffuse, metal, emissive, and glass-style settings.
The ray-cast renderer consumes only color; the path tracer uploads both color
and material data, and also builds a light list from emissive voxels.

Palette edits bump `Document::version`, which causes the path tracer to rebuild
all voxel, palette, material, and light resources. The ray-cast renderer has a
palette signature and skips palette upload when unchanged, but it still enters
its document-update path when the document version changes.

### .vox Load/Save Shape

The internal scene is already flattened into one `VoxelGrid`. MagicaVoxel scene
graph/model transforms are resolved on load into signed grid coordinates.
Saving writes the current single grid and palette/material data. There is no
internal object/layer graph yet; ROADMAP Phase 15 will be the boundary where the
single-grid assumption stops holding.

## Non-Scene State

The app has several process-global singleton state objects plus substantial
transient state inside `VoxelView`.

### ToolState

`CurrentTool()` returns the global `ToolState`. It contains:

- active `ToolKind`
- active `ToolMode` (`Add`, `Remove`, `Paint`)
- active palette index
- brush size, brush shape, 2D/3D footprint mode
- line/circle/square/box/face tool options
- selected palette slots for multi-slot palette/material editing

Tool selection and tool configuration are therefore global UI state, not
document state. This matches the single-document app, but it is an important
SwiftUI migration point: it is view/application state that should become an
observable model rather than a free global.

### RenderState

`CurrentRenderState()` is global render UI state. It stores the active renderer
toggle, path tracer parameters, accumulation sample count, render resolution,
tonemapping, glass mode, NEE/RIS toggles, sky/sun/atmosphere settings, and the
"save render" panel bridge.

Some of this is user-editable configuration; some of it is renderer output
state. In particular, `sample_count` is written by `PathTraceRenderer` every
frame and read by the UI. For a SwiftUI port, render settings and render progress
should probably be separated.

### Selection

`CurrentSelection()` stores one active selection:

- `Bounds3 box`
- `bool active`
- `std::vector<std::array<int32_t, 3>> voxels`

The box is the selection AABB. `voxels` is the sparse selected-cell list used by
marquee, flood, box selection, palette color selection, and many modern
selection actions. Older AABB-oriented logic has been partially replaced: copy,
delete, paste, move, and floating-buffer operations mostly respect the sparse
list now, but comments still identify the AABB/sparse split as an area to unify.

Selection is not currently recorded for every edit. `EditHistory` can carry
optional pre/post selection snapshots, and floating-buffer commit uses that, but
ordinary brush/shape strokes leave selection alone.

### Clipboard

There are two clipboard concepts:

- voxel clipboard: copied selected cells with origin and dense local cell array
- palette color clipboard: a UI-local RGBA clipboard inside `PalettePanel.cpp`

Voxel paste stages into the floating buffer instead of immediately writing to
the document.

### FloatingBuffer

`CurrentFloatingBuffer()` is a second sparse `VoxelGrid` overlaid on top of the
document while moving, pasting, or transforming a selection. It stores:

- `grid`
- integer render/commit offset
- active flag
- whether it originated by lifting cells from the document
- original source cells for undo/cancel
- pre-lift selection snapshot
- independent `version`

This is the cleanest transient-edit model in the app. A lifted selection clears
source cells from `Document::grid` once, stores them in `FloatingBuffer::grid`,
and then moves by changing only `offset_x/y/z`. The ray-cast renderer renders
the document and the floating buffer as two sparse volumes, with the buffer
winning on overlap. Pure movement does not bump `FloatingBuffer::version`, so it
does not rebuild the floating GPU chunk pool.

Commit folds the source clears and target stamps into one `EditHistory` op and
updates the selection to the dropped cells. Cancel restores source cells for
lift-style buffers or simply discards paste-style buffers.

### GeneratorState

`CurrentGeneratorState()` stores the selected generator kind and generator
parameters. The active generator bounds do not live here; they are transient
viewport/gizmo state inside `VoxelView`.

### EditHistory

`EditHistory` is a global undo/redo stack of `EditOp`. An operation is a list of
cell changes plus optional pre/post selection snapshots. `BeginOp`, `Record`,
and `CommitOp` are used by brush strokes, shape commits, selection transforms,
and paste/move commits.

Within one operation, `Record` coalesces same-cell writes through a packed cell
key map. This matters for wide brush strokes and drag paths where the same cell
can be touched repeatedly.

Undo/redo applies old/new values through `VoxelGrid::Set`; callers then bump
`Document::version`.

### VoxelView Transient State

`VoxelView.mm` currently owns most interaction state:

- camera
- active drag mode
- mouse anchors and last cursor positions
- hover point
- brush drag skip set
- shape anchors
- live `_shapePreview` map
- face-tool seed cells and incremental face preview state
- generator gizmo active/bounds/handle state
- selection move/transform gizmo state
- renderer instances and command queue

This state is not scene data, but much of it is the real "editor interaction
model". It is tightly coupled to AppKit events, ImGui frame timing, picking, and
document mutation. This is the largest obstacle to a clean SwiftUI port.

## Interaction and Edit Flow

### Frame Loop

Each frame, `VoxelView::drawInMTKView`:

1. Starts a new ImGui frame.
2. Cancels invalid pending shape/generator interactions when tools change or
   Escape is pressed.
3. Draws panels, which mutate global state and sometimes the document.
4. Refreshes an active generator preview if kind/params/bounds/palette changed.
5. Draws overlays and gizmos.
6. Chooses path tracing or interactive ray casting.
7. Encodes ImGui on top.

Panel code directly mutates `ToolState`, `RenderState`, `GeneratorState`,
`Selection`, `Palette`, `Material`, and sometimes `Document::grid`. There is no
central action dispatcher.

### Picking

Viewport editing starts from camera rays in grid space. CPU raycast picks
against `Document::grid`; helper paths also consider the floating buffer when
needed so a moved/pasted selection can be picked before commit. For Add mode,
targeting generally places a cell adjacent to the hit face. For Remove/Paint,
targeting generally uses the hit occupied cell. Some tools fall back to the
ground plane for empty-space endpoints.

### Brush

Brush drag begins an `EditHistory` op on mouse down. Each edit computes a target
cell, expands it through the configured brush footprint, calls `VoxelGrid::Set`
for changed cells, records old/new values, and increments `Document::version`.
The op commits on mouse up.

For Add drags, `_dragSkipCells` tells picking to ignore cells placed earlier in
the same stroke so the cursor does not chase its own newly-created surface.

Performance shape: brush movement mutates the document continuously. That
creates dirty chunks continuously. The ray-cast renderer handles this
incrementally by uploading dirty chunks, but the CPU still computes footprint
cells, applies them one by one, records history, bumps document version, and
runs renderer update logic on every changed drag event.

### Line, Circle, Square, and Box

These tools use a live preview map. On mouse down they capture an anchor. During
drag, most shape tools:

1. Roll back every cell in `_shapePreview` to its original value.
2. Re-enumerate the shape for the current cursor.
3. Stamp the preview cells into `Document::grid`.
4. Store each touched cell's original value in `_shapePreview`.
5. Increment `Document::version`.

On mouse up, they roll back the preview, then re-stamp the final shape through
`EditHistory` as one undoable op.

This gives a simple undo story, but it means the document grid really changes
during preview. The ray-cast renderer sees those changes as normal dirty chunks.
For large previews or high cursor rates, this can upload many changed chunks
even though the user has not committed the operation.

### Face Tool

The Face tool is more incremental. On mouse down it picks a face and flood-fills
the coplanar seed cells. During drag, it tracks the current layer distance.
Instead of always rebuilding from scratch, it applies or rolls back only the
layers that changed between the previous distance and the new distance. It
falls back to full preview rebuild when direction or source-color mode changes.

Commit is still history-based: the live preview is rolled back first, then the
final extrusion/inset/paint/remove is applied inside one `EditHistory` op.

This is a different and more optimized preview strategy than Line/Circle/Square/
Box. It is a good candidate for a generic "incremental preview transaction"
abstraction.

### Generator Tool

Generator preview is GPU-assisted but document-backed. The viewport owns the
active AABB gizmo. When bounds, kind, params, or palette change:

1. Existing `_shapePreview` is rolled back.
2. `GeneratorEngine` dispatches a Metal compute kernel over the AABB.
3. The CPU waits for completion and reads back generated cell coordinates.
4. Generated cells are stamped into `Document::grid` as preview cells.

Mouse up leaves the generator gizmo active. Clicking outside the gizmo commits
the currently previewed cells into one history op by recording `_shapePreview`
original values against current grid values. Escape/tool switch cancels and
rolls back.

The generator avoids CPU-side primitive enumeration, but it still reads a cell
list back to the CPU and mutates the document grid for preview. It does not
currently keep generator preview as an overlay volume the way floating
selection does.

### Selection, Move, Paste, and Transform

Selection tools populate `Selection::voxels` and `Selection::box` without
mutating the document.

Move/paste/transform operations use `FloatingBuffer`. This is the app's best
large-data interaction path:

- lifting a selection mutates the document once and uploads changed chunks once
- dragging changes only an integer offset
- ray-cast rendering gets the offset as a uniform
- committing writes the final document changes once

Scaling a floating selection resamples `FloatingBuffer::grid` during handle drag
and bumps `FloatingBuffer::version`; the ray-cast renderer then rebuilds the
floating-buffer GPU mirror. That is expected because the buffer's cells actually
change. Pure movement avoids this cost.

## GPU Data Flow

### Shared Sparse GPU Layout

Both renderers use the same conceptual layout:

- coarse grid: dense array over occupied chunk-coordinate bounds, storing a
  1-based chunk-pool index or zero for empty
- chunk pool: dense `16 x 16 x 16` byte chunks
- palette buffer
- path tracer only: material buffer and emissive light buffer

Shader code traverses the sparse grid/chunk pool rather than a dense scene
volume.

### Interactive Ray-Cast Renderer

The ray-cast renderer has the more careful update path. On encode, if cached
document version differs, it drains `doc->grid.TakeDirtyChunks()`.

If the cache is invalid, there is no coarse buffer, or dirty chunks lie outside
the cached padded coarse bounds, it does a wholesale rebuild:

- scans chunk bounds
- pads bounds by four chunks in every direction
- allocates coarse grid
- allocates chunk pool with headroom
- copies every chunk
- uploads palette
- clears the dirty queue

Otherwise it applies dirty chunks incrementally:

- grows the chunk pool only if new chunk slots exceed capacity
- clears coarse slots for deleted chunks
- assigns pool slots for new chunks
- copies only dirty chunk contents
- updates chunk count

Palette upload is guarded by a signature, so ordinary voxel edits do not
re-upload palette data.

The floating buffer has a separate coarse grid and chunk pool. It rebuilds only
when `FloatingBuffer::version` changes. Offset-only motion is passed through
uniforms, so moving a large selection does not re-upload the model.

This path appears designed specifically to avoid the "reupload the entire model
on every cursor move" failure mode for normal document edits and floating
selection movement. The remaining risk is not full model upload; it is excessive
dirty-chunk churn caused by document-backed previews.

### PathTraceRenderer

The path tracer rebuilds all scene resources whenever `Document::version`
changes:

- coarse grid
- chunk pool
- linear-space palette
- material buffer
- emissive light list and light sampling CDF

This is intentionally simpler than the ray-cast path because path-traced mode is
stationary render mode, not the primary editing path. Accumulation restarts when
document resources, camera state, or render settings affecting the integrator
change. Render resolution changes allocate a new accumulation texture.

Entering path-traced mode auto-commits any active floating buffer first, so the
path tracer only sees the document grid. It does not render floating-buffer
overlays.

### GeneratorEngine

`GeneratorEngine` compiles one compute pipeline per generator kind. Each
generation request:

- ensures a grow-only output buffer can hold the full AABB volume
- zeroes a shared atomic counter
- dispatches one thread per AABB cell
- appends qualifying cells into the output buffer
- waits synchronously for completion
- reads the count and cell coordinates back to CPU memory

This is good at avoiding CPU primitive math, but it is not a fully GPU-resident
edit path: the generated result comes back to the CPU, then is applied through
`VoxelGrid::Set`, then uploaded to renderer resources through the usual dirty
chunk path.

## Current Consistency Gaps

The code already has good pieces, but similar concepts are represented in
several ways:

- Brush edits mutate the document directly during drag and record history as
  they go.
- Most shape previews mutate the document, roll back the whole preview on every
  cursor move, then commit through history on mouse up.
- Face preview mutates the document but diffs by layer.
- Generator preview uses GPU compute, readback, document-backed preview, and a
  persistent commit/cancel gizmo.
- Move/paste uses a true overlay model with `FloatingBuffer`, where movement is
  an offset and commit is deferred.
- Palette/material panel edits directly mutate document state and bump document
  version outside any undo system.
- Selection state is split between an AABB and sparse voxel list; most current
  paths use sparse voxels, but the data model still makes both peers.
- UI state lives partly in global singleton structs, partly in static locals in
  panels, and partly in `VoxelView` ivars.

## Suggested Improvements

### 1. Define an Explicit Editor State Model Before SwiftUI

Create a small set of model structs with clear ownership:

- `DocumentModel`: durable scene data and document path.
- `ToolSettings`: current tool, mode, palette index, and per-tool options.
- `RenderSettings`: user-editable render configuration.
- `RenderProgress`: sample count, convergence, current GPU stats.
- `SelectionModel`: selected cells and derived bounds.
- `InteractionState`: current gesture, anchors, hover, active preview, active
  gizmo.
- `PanelState`: UI-only panel state such as palette drag selection and context
  menu target.

This does not require Swift yet. The immediate win is making state boundaries
plain in C++/Objective-C++ so SwiftUI can later observe a coherent model instead
of re-discovering `VoxelView` ivars and panel statics.

### 2. Replace Global Singletons With an App/Editor Context

`CurrentTool`, `CurrentSelection`, `CurrentRenderState`, `CurrentGeneratorState`,
`CurrentFloatingBuffer`, and `CurrentHistory` should eventually be fields on an
`EditorContext` owned by the app/document/view layer. The app can still be
single-document, but passing a context explicitly will make dependencies visible
and prevent SwiftUI from needing to bridge process globals.

This is also a useful test seam: tool logic can be exercised against a context
without instantiating `VoxelView`.

### 3. Separate Document Mutations From Preview Overlays

The biggest conceptual cleanup would be to stop writing live previews into
`Document::grid`. Introduce a generic `PreviewVolume` or extend
`FloatingBuffer`-style overlay rendering to cover shape/generator previews:

- document grid remains committed scene state
- preview stores sparse cells plus original/merge policy
- ray-cast renderer composites document + preview overlays
- commit converts preview to one `EditHistory` op
- cancel drops preview without rollback writes

This would eliminate dirty document chunks during cursor-only preview changes.
It also gives SwiftUI a crisp state model: "there is an active preview" rather
than "the document has temporary cells plus a rollback map hidden in the view".

### 4. Unify Tool Commit Semantics Around Edit Transactions

Introduce a single edit transaction API used by every tool:

- `begin`
- `preview/update`
- `commit`
- `cancel`
- optional selection pre/post snapshots

Brush can be a streaming transaction. Shape/generator/face can be preview
transactions. Floating-buffer commit can become another transaction type. The
goal is not abstraction for its own sake; it is to make undo, selection updates,
document version bumps, and renderer invalidation happen in one predictable
place.

### 5. Make Selection Sparse-First

Promote sparse selected cells to the canonical selection and make bounds a
derived/cache value. For rectangular selection, the sparse set can still be
materialized at commit time, as it is today. Add O(1) membership if selection
membership is queried interactively.

This removes the lingering ambiguity where some operations are AABB-shaped and
others are sparse-shaped. It also prepares for marquee, flood, rotation, pattern
brush, and non-rectangular transform operations.

### 6. Give Palette and Material Edits Undoable Commands

Palette and material edits currently mutate `Document::palette` directly and
bump document version. For a modeling app, palette changes are scene edits and
should have undo/redo. They also cause path-tracer resource rebuilds. Wrapping
them in command/history entries will make them consistent with voxel edits and
make SwiftUI bindings safer.

A separate palette/material dirty bit would let renderers distinguish color-only,
material-only, and geometry changes.

### 7. Split Document Version Into Typed Dirty Signals

Keep a coarse document generation if useful, but add explicit dirty categories:

- geometry chunks dirty
- palette colors dirty
- materials dirty
- lights dirty
- document replaced
- render settings changed

The ray-cast renderer already uses dirty chunks and a palette signature; the path
tracer currently rebuilds everything on any document version change. Typed dirty
signals would let the path tracer avoid rebuilding voxel buffers for pure
material/color edits when possible, while still rebuilding the light list when
emissive material/color changes affect lights.

### 8. Reuse the Floating Overlay Idea for Large Shape and Generator Work

The floating buffer proves the right performance model for large transient data:
upload a sparse overlay when its cells change, move it with uniforms, and commit
once. Generator previews and large shape previews would benefit from the same
model. In particular, generator cell output could populate an overlay buffer
instead of mutating the document grid on every parameter or bounds change.

Longer-term, GPU-generated previews could stay GPU-resident until commit, but
even a CPU-side overlay grid would avoid document rollback churn and make the
renderer update path conceptually cleaner.

### 9. Audit Per-Cursor CPU Work for Brushes and Selections

ROADMAP already notes that generator interaction is smoother than brushes and
selection tools. The likely hotspots are now well bounded:

- brush footprint enumeration and per-cell `Set`/history work on every drag
  event
- document-backed shape preview rollback/re-stamp
- selection operations that scan all occupied cells on commit
- overlay wireframe drawing for large sparse selections

The renderer is not obviously re-uploading the entire document on every cursor
move in ray-cast mode. The more plausible issue is CPU-side edit/preview work
and repeated dirty-chunk uploads for temporary document mutations.

### 10. Move Interaction Logic Out of `VoxelView`

`VoxelView` should become the platform view/render-event adapter, not the owner
of every modeling state machine. Extract tool controllers or pure functions for:

- brush stroke
- shape preview/commit
- face extrusion
- generator gizmo
- selection move/transform
- selection creation

Each controller should operate on `EditorContext`, camera/picking services, and
an edit/preview transaction interface. That shape will map much more naturally
to SwiftUI, where controls mutate observable state and gestures call model
actions rather than burying state in an AppKit view subclass.

### 11. Keep the Ray-Cast Dirty-Chunk Path, But Make It Easier To Reason About

The current ray-cast upload path is a strength. Preserve:

- chunk-level dirty tracking
- padded coarse bounds
- amortized chunk-pool growth
- separate floating-buffer resources
- offset-only movement

The refactor opportunity is to make invalidation explicit and less dependent on
`Document::version` as the first gate. A renderer-facing `SceneUploadState`
could consume typed dirty events from transactions and make upload costs visible
in debug UI.

### 12. Treat Path-Traced Mode as a Committed-Scene Consumer

The path tracer currently ignores floating overlays by auto-committing before
entry, which keeps render mode simple. Preserve that unless there is a strong UI
reason to preview uncommitted edits in path-traced mode. If path tracing ever
needs uncommitted overlays, it should use the same formal preview/floating
volume model rather than special-casing `VoxelView` state.

