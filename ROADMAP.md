# Roadmap

Distilled from `TODO.txt`. Phases are ordered by my best read of impact-per-effort
and dependency direction; reorder freely.

Effort labels are rough: **S** ≈ a few hours, **M** ≈ a day, **L** ≈ multi-day.

---

## Phase 9 — Modeling foundation cleanup

The day-to-day editing experience has a couple of paper cuts and one missing
abstraction (tool mode). Fix those and the rest of the modeling work has a
solid base. **S–M total.**

- **Tool modes (S).** Global Add / Remove / Paint state. Every modeling tool
  routes through it instead of having its own add/erase logic. Sets up the
  Modeling Tools phase.
- **Drag-paint cell-change fix (S).** Currently fires every pointer move; should
  fire only when the raycast lands on a new cell. One commit.
- **Pointed-at voxel highlight (S–M).** Outline / tint the cell under the
  cursor. Drawn in the ray-cast shader so it tracks the camera.
- **SF Symbols in tool / palette UI (S).** Replace text labels for tools, brush
  size buttons, mode toggles. ImGui draws them as fonts via Apple's SF Symbols
  font (`/System/Library/Fonts/SF-Pro.ttf` glyph range).
- **Settle on a UI font size (S).** Currently 13pt body / 15pt header (HIG
  body + Title 3). Pro apps often run 11–12pt for density, consumer apps
  trend 15–17pt. Pick the size that fits MacVoxel's identity once enough
  panels exist to compare against.

## Phase 10 — Render-mode QoL & tonemapping

The path tracer is feature-complete enough that we should make output usable.
ACES alone is a huge visible win for ~10 lines of shader. **S–M total.**

- **ACES tonemapping (S).** Replace the gamma-only display fragment with
  ACES-fitted tonemap → sRGB encode. Bright emissives stop blowing out.
- **Render-resolution + max-samples controls (S).** Path-trace panel gets
  resolution scale (½ / 1× / 2×) and max-samples target.
- **Progress bar (S).** Sample-count vs. target.
- **Pause when unfocused (S).** Stop accumulating when the app loses
  `windowDidResignKey`. Resume on regain.
- **PNG export (S).** "Save render…" item that writes the current accumulator
  divided by sample count, post-tonemap, as PNG.

## Phase 11 — Palette redesign

Self-contained UX overhaul. **M.**

- 8×32 grid (or 16×16 — TBD), id 0 in a fixed corner.
- Grid resizes to horizontal space.
- Click-drag → rect selection of slots.
- Shift-click → add/remove from selection.
- Material edits apply to all selected slots.

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

If we had to pick one phase right now: **Phase 9** (modeling cleanup), then
**Phase 10** (render QoL + ACES). Both are mostly small commits, both are
visible improvements every session, and they unblock the bigger phases that
follow.
