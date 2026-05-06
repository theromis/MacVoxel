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

## Phase 12 — New modeling tools

Each is a distinct tool; ordered roughly by usefulness. **L total, but
shippable per-tool.**

- **Line tool (S–M).** Two-click point-to-point. *Straight* mode = 3D Bresenham
  through cells; *project* mode = locks to nearest axis plane.
- **Face tool (M).** Pick a coplanar contiguous region; extrude / inset by a
  drag distance. Floods on the same material + same axis.
- **Box / volume tool (S).** Two-click cuboid. Filled or hollow toggle.
- **Brush / pattern tool (M).** Stamps a pre-captured selection at the cursor;
  brush source is set from a Selection Verb (next phase).

## Phase 13 — Selection upgrades

- **Marquee selection (M).** Screen-space rectangle → set of voxels whose
  projection is inside it. Front-face only? TBD.
- **Contiguous-region selection (S).** Flood fill from clicked voxel by same
  material.
- **90° rotation around X/Y/Z (S).** Three buttons / shortcuts.
- **Free transform gizmo (L).** ImGuizmo-style rotate / scale of the selection
  with live preview, committed on confirm.
- **Set selection as Pattern (S).** Wires Phase 12's brush tool.

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

## Phase 15 — Insertable primitives

Parametric shapes with an edit gizmo, committed to voxels on confirm. **L total.**

- **Sphere / cylinder / cone / pyramid (M each).** Each gets a parameter set
  (radius, height, axis…) and an in-scene gizmo.
- **Commit-to-voxels on deselect.** The primitive becomes ordinary voxels.
- **(Stretch) Procedural shader tools.** Noise terrain, spiral/coil generators
  driven by small MSL snippets. **L.**

## Phase 16 — Scene graph + layers

The biggest structural change. Every prior phase keeps the single-grid
Document model; this one breaks it. **L–XL.**

- **Multi-object Document.** Each object owns a `VoxelGrid` and a transform.
- **Object create / place / resize / delete.**
- **Duplicate as instance.** Shared grid, separate transform.
- **Layers.** Each object belongs to a layer; layers toggle visibility.

This phase touches every renderer (the GPU layout assumes one coarse grid)
and every tool (raycast / picking is currently per-grid). Plan for it as a
phase boundary, not a side change.

## Phase 17 — Advanced materials

- **Sub-surface scattering (M).** Real SSS (random-walk inside the medium with
  scattering coefficient) rather than the accidental "SSS-y look" we get from
  rough glass. Same Beer-Lambert plumbing, just adds in-scattering.
- **Disney BSDF / "mixed" material (L).** A single material with sliders for
  diffuse / metal / glass / SSS weights. Supersedes the discrete `MaterialType`
  enum eventually.

---

## Suggested next-up

**Phase 12 — modeling tools.** The renderer and palette UX are in a good
spot; the next visible-every-session win is making it faster to *build*
voxel models. Line and box tools are small commits each; face/extrude
unlocks the kind of moves that turn a sketch into a finished shape.
