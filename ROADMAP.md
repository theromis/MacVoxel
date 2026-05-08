# Roadmap

Distilled from `TODO.txt`. Phases are ordered by my best read of impact-per-effort
and dependency direction; reorder freely.

Effort labels are rough: **S** ≈ a few hours, **M** ≈ a day, **L** ≈ multi-day.

---

## Done

- **Phase 9 — Modeling foundation cleanup.** Tool modes, drag-paint dedupe,
  hover highlight, SF Symbols icons, font sizing.
- **Phase 10 — Render-mode QoL & tonemapping.** ACES, render-resolution +
  max-samples, progress bar, focus pause, PNG export, explicit render
  resolution with letterbox.
- **Phase 10.5 — Path tracer correctness (unplanned).** MagicaVoxel-style
  emission (intensity + integer power decades), next-event estimation on
  emissive voxels, MIS with the power heuristic for direct lighting (with
  numerically stable mis_power that sidesteps the inf/inf=NaN trap),
  Fresnel reflection on medium exit (the "ghost" second reflection visible
  in clear glass), Probabilistic vs Absorption transmission modes for
  glass with a UI toggle and CLI flag.
- **Phase 10.6 — Headless render CLI (unplanned).** `MacVoxel render
  --input … --output …` invocation that bypasses NSApplicationMain and
  drives PathTraceRenderer directly. Deterministic per `--seed`. Lets
  Claude (and CI) iterate on the renderer without a GUI session.
- **Phase 11 — Palette redesign.** 8×32 grid matching MagicaVoxel's
  layout (id 1 bottom-left, id 0 top-right corner with hatch),
  per-axis swatch scaling within [8, 28] px, click-drag rect selection,
  shift-click / shift-drag toggle, bulk material editor in the Render
  panel writing to all selected slots. Material section moved out of
  the Palette panel into the Render panel as part of this. Fixed an
  old keyboard-input bug along the way (VoxelView was claiming first
  responder, evicting ImGui's KeyEventResponder).
- **Phase 11.5 — Palette right-click menu.** Copy/Paste color between
  slots; Make gradient across selected slots; introduced a sparse
  voxel-selection vector to back Select-voxels-by-color and the two
  paint actions (solid pick / random pick). Per-voxel wireframe
  highlight with interior-face dedupe + back-face culling. Two
  carry-overs filed for Phase 13: depth-aware occluded-voxel culling,
  and unifying AABB cut/copy/delete with the sparse selection.
- **Phase 12 — New modeling tools.** Brush enhancements (size, shape,
  2D / 3D), Line (Straight + Project modes), Circle (Fill + Even), Square
  (Fill + Even), Box (Fill toggle), and Face (extrude / inset with
  Color / Geometry seed flood, Geometry / Palette extrude color, 4 / 8
  connectivity). Every two-click tool routes through a shared shape-
  preview pipeline so live voxel preview + single-undo-step commit comes
  for free; pure cell enumeration lives in `Shapes.{h,cpp}`.
- **Phase 12.5 (foundation) — Generators engine + Ellipsoid + gizmo.**
  Parameterized shape primitives that the user lays out via a gizmoized
  AABB rather than drawing one cell at a time. GPU-first architecture:
  each generator is a Metal compute kernel that scans its AABB at one
  thread per cell, evaluates the primitive's inside-test, and atomically
  appends qualifying cell coords to an output buffer; CPU reads the
  count and stamps via the existing `_shapePreview` machinery so the
  live preview / single-undo-step commit flow is shared with the shape
  tools. Shipped: GPU compute infrastructure, the Ellipsoid kernel, the
  Generators panel, and the full gizmo (face-arrow handles with
  NDC-space drag projection, click-outside-to-commit, Esc to cancel,
  per-frame change detection so panel / palette edits re-run the engine
  in place). Cylinder / Cone / Pyramid / Maze / Perlin / Fractal — and
  the user-authored MSL shader escape hatch — slot in on top of this
  without architecture changes.

## Phase 12.5 (rest) — Additional generator kinds

The engine + gizmo are done; each new kind is one MSL kernel function,
one `Kind` enum entry, one entry in `KernelNameForKind`, one panel
button, and any per-kind fields on `Params`.

- **Cylinder (S).** Axis (X / Y / Z), inscribed in the AABB on the two
  perpendicular axes. Optional: hollow / wall thickness.
- **Cone (S).** Axis + apex direction (which face the apex points
  toward). Tapers linearly from base radius to 0.
- **Pyramid (S).** Like Cone but Chebyshev-norm cross-section (square
  base) instead of Euclidean.
- **Maze (M).** Recursive backtracker or Wilson's, seeded into the
  AABB's interior. Needs a seed field on `Params` and an RNG primitive
  in MSL (PCG or wyrand fits in a kernel).
- **Perlin / value noise (M).** Frequency, octaves, threshold, seed.
  Threshold + signed noise gives terrain-like fills.
- **Fractal (M).** Iterations, ratio, seed. Sierpinski-style or
  Mandelbrot-bulb cross-section.
- **(Stretch) User-authored MSL shader generator (L).** Runtime
  compile via `MTLLibrary newLibraryWithSource:`, source editor in the
  panel, error reporting routed back into the editor, hot reload on
  edit. Standard "fill this function" stub the user implements.
  Independent of the built-in kernels — they all dispatch through the
  same engine.

## Phase 13 — Selection upgrades

- **Marquee selection (M).** Screen-space rectangle → set of voxels whose
  projection is inside it. Front-face only? TBD.
- **Contiguous-region selection (S).** Flood fill from clicked voxel by same
  material.
- **90° rotation around X/Y/Z (S).** Three buttons / shortcuts.
- **Free transform gizmo (L).** ImGuizmo-style rotate / scale of the selection
  with live preview, committed on confirm.
- **Set selection as Pattern (S).** Wires Phase 12's brush tool.
- **Proper hidden-surface cull on per-voxel selection highlights (M).**
  Phase 11.5 added a per-voxel wireframe with interior-face dedupe and
  back-face culling, but voxels that are themselves visible-from-camera
  but occluded by other geometry still draw their wireframes through
  the occluder. A naive per-voxel DDA from the camera looked off; the
  right fix probably needs depth-buffer integration with the renderer
  pass or a coarser silhouette extraction. Tackle alongside the
  selection-as-set work since both want a real depth-aware overlay.
- **AABB cut/copy/delete unify with sparse selection (S).** Today
  AppDelegate's clipboard ops still iterate the AABB and ignore
  Selection::voxels. Extend them to filter by the sparse set when
  present (need O(1) membership — promote the list to an
  unordered_set or maintain both side-by-side).
- **Brush / pattern tool (M).** Stamps a pre-captured selection at the cursor;
  brush source is set from a Selection Verb (next phase).

## Phase 13.5 — Edit-volume foundation

Establishes a bounded, visually-referenced edit volume. Today the editor
treats the grid as implicitly infinite, so empty-space clicks can only
fall back to the z=0 ground plane — there's no way to anchor an empty
endpoint flush to a side wall, and no visual reference for where you're
clicking in empty space.

- **Faint floor grid (S).** Render integer-voxel grid lines on the z=0
  plane (and optionally the camera-facing side walls, MagicaVoxel-style)
  so the user can see where empty-space clicks will land.
- **Bounded editable volume (M).** Cap the grid to MagicaVoxel's 256³
  max object size. Edits outside the volume are clamped or rejected; the
  bounds become the canonical volume the floor grid and the empty-endpoint
  fallback both reference. .vox round-tripping should already match.
- **Multi-plane empty-endpoint fallback (S, depends on the volume).**
  Today the Line tool falls back to z=0 for empty clicks (so empty
  endpoints only land on the floor). With a defined volume, an empty
  click should fall back to whichever of the 3 camera-facing bounding
  faces the ray hits first — XY, XZ, or YZ — letting the user anchor
  empty Remove/Paint endpoints flush to any wall.

## Phase 14 — Renderer features

Mostly self-contained shader work. Each item shippable independently. **M each
unless noted.**

- **Perspective ↔ orthographic toggle.** Both renderers; one shared camera flag.
- **Sky / sun model.** Replace the hardcoded sky color with a configurable
  sun (color, size, intensity) + sky (zenith / horizon colors). Path tracer
  samples it directly; ray-cast just shows it as background.
- **Atmospheric scattering (M–L).** Simple Hosek-Wilkie or Preetham. Drop-in
  replacement for the flat sky.
- **Depth-of-field (M).** Aperture + focal distance camera params; left-click
  in view sets focal distance.
- **Bloom (S–M).** Post-pass on the display fragment. Threshold + blur.
- **Fog (S).** Distance-based atmospheric tint. Bonus: height fog.
- **IBL / HDRI (L).** Replace the constant sky with an environment map; sample
  importance-weighted for the path tracer.

## Phase 15 — Scene graph + layers

The biggest structural change. Every prior phase keeps the single-grid
Document model; this one breaks it. **L–XL.**

- **Multi-object Document.** Each object owns a `VoxelGrid` and a transform.
- **Object create / place / resize / delete.**
- **Duplicate as instance.** Shared grid, separate transform.
- **Layers.** Each object belongs to a layer; layers toggle visibility.

This phase touches every renderer (the GPU layout assumes one coarse grid)
and every tool (raycast / picking is currently per-grid). Plan for it as a
phase boundary, not a side change.

## Phase 16 — Advanced materials

- **Sub-surface scattering (M).** Real SSS (random-walk inside the medium with
  scattering coefficient) rather than the accidental "SSS-y look" we get from
  rough glass. Same Beer-Lambert plumbing, just adds in-scattering.
- **Disney BSDF / "mixed" material (L).** A single material with sliders for
  diffuse / metal / glass / SSS weights. Supersedes the discrete `MaterialType`
  enum eventually.

---

## Suggested next-up

**Cylinder + Cone + Pyramid generators.** The Generators engine and gizmo
are working end-to-end on Ellipsoid. Adding three more pure-math kernels
on top of the existing dispatch is small, demonstrably useful, and proves
out the "any new kind is one kernel function" claim before getting into
the bigger projects (Maze / Perlin RNG, user-shader runtime compile, or
Phase 13 selection upgrades).
