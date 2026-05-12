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
- **Phase 12.5 — Generators engine + four primitives + gizmo.**
  Parameterized shape primitives that the user lays out via a gizmoized
  AABB rather than drawing one cell at a time. GPU-first architecture:
  each generator is a Metal compute kernel that scans its AABB at one
  thread per cell, evaluates the primitive's inside-test, and atomically
  appends qualifying cell coords to an output buffer; CPU reads the
  count and stamps via the existing `_shapePreview` machinery so the
  live preview / single-undo-step commit flow is shared with the shape
  tools. Shipped: GPU compute infrastructure, four kernels (Ellipsoid,
  Cylinder, Cone, Pyramid — the latter three sharing an `AxisView`
  helper for axis-parameterized cross-sections, with `axis` and
  `apex_at_max` fields on `Params`), the Generators panel, and the
  full gizmo (axis-coloured face-arrow handles with NDC-space drag
  projection, click-outside-to-commit, Esc to cancel, per-frame change
  detection so panel / palette edits re-run the engine in place).
  Stretch / RNG-driven kinds and the user-shader path slot in on top
  without architecture changes.
- **Phase 13 - Selection upgrades**
  Marquee, box, flood selection, Cmd-drag selection movement, free transform
  gizmo, 90° rotation controls in palette, `FloatingBuffer` 
- **Phase 14 - Sun light and atmospheric simulation**
  Replaced the hardcoded sky color with a configurable
  sun (color, size, intensity) + sky (zenith / horizon colors). Path tracer
  samples it directly; ray-cast just shows it as background. Atmospheric
  scattering per Nishita.
- **SwiftUI port (`swiftui-port` branch, 2026-05).** Replaced the AppKit
  shell + Dear ImGui UI with a native SwiftUI app. `EditorContextBridge`
  (Obj-C++) wraps `std::unique_ptr<EditorContext>`; `EditorState`
  (`@Observable`) is the Swift façade with a 10 Hz tick driving
  observation for controller-driven mutations. `MetalScene` (MTKView
  subclass) takes over `VoxelView`'s job; `SceneOverlayRenderer` +
  `Overlay.metal` + `OverlayDraw` replace ImGui's draw-list calls so
  the per-tool controllers' `DrawOverlay` paths are fully decoupled
  from ImGui. All seven panels rewritten in SwiftUI. `third_party/imgui`
  submodule + `src/ui/*` + `AppDelegate.{h,mm}` + `VoxelView.{h,mm}`
  deleted. Binary shrank 4.6 MB → 2.6 MB. Deferred to follow-up:
  Material editor's drag-select coverage, tool quick-keys, drag-drop
  onto window, theme parity vs the old `ui/Theme.cpp`.
- **Palette drag-rect multi-select + context menu (2026-05).** Ported
  the deferred Phase 11 / 11.5 palette UX onto the SwiftUI panel: a
  parent `DragGesture(min:0)` that maps cursor → (col,row) via the
  grid's 16-pt pitch and commits the rect through a new
  `selectPaletteRange` bridge method; per-swatch `.contextMenu` for the
  six items (Copy / Paste color, Select voxels by color, Paint solid /
  Paint random, Make gradient). Since SwiftUI's `.contextMenu` has no
  menu-open hook, each action takes the right-clicked anchor and the
  bridge runs the "anchor replaces selection if not already in it"
  fixup at action-click time; menu enable predicates use
  `effectiveSelectedSlotCount(anchor:)` to model that post-fixup view.

## Phase 12.5+ — RNG-driven generator kinds + user shader path

The engine + gizmo are done; each new kind is one MSL kernel function,
one `Kind` enum entry, one entry in `KernelNameForKind`, one panel
button, and any per-kind fields on `Params`.

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

## Known issues

- **File > Open Recent missing.** Used to be present but empty; now
  the SwiftUI `CommandGroup(replacing: .newItem)` doesn't preserve
  the standard Open Recent submenu at all. `EditorContextBridge` still
  calls `noteNewRecentDocumentURL:` on every successful open/save, and
  `CFBundleDocumentTypes` is still declared, so the data is being
  recorded — the menu surface just needs to be re-introduced. Likely
  fixes: (a) use `CommandGroup(after: .newItem)` so the standard
  group stays, (b) build an explicit "Open Recent" `Menu` ourselves
  from a `@AppStorage` URL list, (c) adopt a minimal `NSDocument`
  subclass for `.vox` so SwiftUI's document-aware machinery kicks in.
  `.onOpenURL` (Finder Open With) works fine.

- **Tool performance.** The Generator tool is notably more performant
  than the brushes and selection tools. It achieves MagicaVoxel-level
  responsiveness, while the Brush and Selection tools stutter at high
  cursor speeds or while affecting larger volumes. This is undoubtedly
  because we're either doing more work on the CPU than we should for
  those tools or because we're moving data back and forth in memory
  more often than we need to. We need to identify the bottleneck and
  fix it. **Any** operation that can be handled on the GPU should be.

- **Post-port polish backlog.** Carried over from the SwiftUI port:
  tool quick-keys (1–0 + `[` / `]`); drag-drop `.vox` onto the running
  window; theme parity vs the old `ui/Theme.cpp`'s pro-app dark.

- **Wall-anchored Line preview invisible from far cameras.** With
  Phase 13.5's multi-plane empty-endpoint fallback, dragging a Line
  out against a volume wall in an empty document only renders the
  preview when the camera is close to the target wall — far cameras
  see no preview during drag, though mouseUp still commits the line
  correctly. Cause is in `RaycastRenderer`'s shader: the early-out
  at line 856 (`_coarseBuffer == nil` → return) skips rendering
  entirely on empty docs, and even with that bypassed the AABB
  union of doc + buf reads from `coarse_min = (0,0,0)` on an empty
  doc, dragging a phantom region from origin into the AABB and
  triggering the "outside both volumes' chunk extents" mid-march
  bail before the ray reaches the buf's actual chunks. Fixing
  needs a coordinated change to (a) bind stub buffers for the doc
  slot when empty so the shader can still run, and (b) compute the
  AABB from non-degenerate sources only. Got partway through in
  one session; reverted because the close-camera path already
  works and the bug is rarely hit in real use.

---

## Suggested next-up

Immediate focus is **bug-squishing the SwiftUI port** — Paul flagged
this as the priority after taking the port for a spin. Once those are
cleared, the natural next forks are:

- **Post-port polish** under Known Issues above (tool quick-keys,
  Open Recent fix).
- **Phase 13.5 (edit-volume foundation)** — faint floor grid + bounded
  volume; lifts the editor out of "infinite empty space" and makes
  empty-space clicks predictable.
- **Phase 12.5+ Maze / Perlin / Fractal** — fun, but each needs an MSL
  RNG primitive and a richer Params shape, so M-sized rather than S.
- **Phase 14.5 ReSTIR DI** — the next step now that power-weighted
  NEE has shipped. Three passes (candidate / temporal / spatial),
  per-pixel reservoir, replaces the current direct-light NEE.

Pick by what feels most fun; nothing is on a deadline.
