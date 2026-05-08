# Working in this repo

A note for the next Claude session that lands here. Read this first.

## What this is

MacVoxel — a native macOS voxel editor + path tracer. C++20 + Objective-C++,
AppKit shell, Metal, Dear ImGui. The README has the user-facing summary; this
file is for orienting on the code.

## Where things live

```
src/
├── main.mm                AppKit entry; bare-minimum NSApplication boot.
├── AppDelegate.mm         Menu bar, file dialogs, app lifecycle.
├── VoxelView.mm           MTKView subclass. Owns the per-frame Metal/ImGui
│                          loop, mouse routing, camera state, and the dispatch
│                          to either the ray-cast or path-trace renderer.
├── Camera.{h,cpp}         Orbit camera, pure C++.
├── Document.h             { VoxelGrid, Palette, path, version }. The single
│                          open document; renderers cache against `version`.
├── VoxelGrid.{h,cpp}      Sparse 16³-chunk hash-map grid. Tracks dirty chunks
│                          so the GPU only re-uploads what changed.
├── Palette.{h,cpp}        256-entry color + Material array.
├── Material.h             Per-palette-entry { type, roughness, metallic,
│                          emission, transparency, ior }.
├── VoxFile.{h,cpp}        MagicaVoxel .vox load/save. Scene graph + MATL.
├── CellKey.h              21-bit-per-axis pack/unpack for the int64 cell
│                          keys used by Raycast, EditHistory, the shape
│                          preview map, and the selection overlay.
├── Raycast.{h,cpp}        CPU DDA for picking (mouse-to-voxel).
├── Shapes.{h,cpp}         Pure C++ cell enumerators: Bresenham3D,
│                          ProjectInPlane / OffsetInPlane, planar disc /
│                          square / box / coplanar-face flood. The Line /
│                          Circle / Square / Box / Face tools' geometry
│                          all lives here.
├── RaycastRenderer.mm     Interactive GPU ray-cast renderer used during
│                          editing. Coarse-grid + chunk-pool, hierarchical
│                          empty-space skipping in the shader.
├── PathTraceRenderer.mm   Path tracer (render mode). Same GPU layout as the
│                          ray-cast renderer; trades responsiveness for
│                          progressive accumulation, GGX, Beer-Lambert, etc.
├── CliRender.mm           Headless `MacVoxel render` subcommand. Bypasses
│                          NSApplicationMain and drives PathTraceRenderer
│                          directly for deterministic CLI/CI renders.
├── Generators.h           Pure-C++ types for parameterized shape primitives:
│                          Bounds3i, Kind, Params.
├── GeneratorEngine.{h,mm} GPU compute runner — one MTLComputePipelineState
│                          per Kind, atomic-append output buffer, sync
│                          dispatch + readback. Each kernel is a thread-per-
│                          cell scan over the AABB.
├── ToolState.{h,cpp}      Active tool, brush size, palette index, etc.
├── GeneratorState.{h,cpp} Active generator kind + Params (mirrors ToolState).
├── EditHistory.{h,cpp}    Stroke-grained undo/redo.
├── Selection.{h,cpp}      Box selection.
├── Clipboard.{h,cpp}      Cut / copy / paste of selected regions.
├── RenderState.{h,cpp}    Path-traced toggle + bounces + sample count.
└── ui/
    ├── ModelPanel.cpp     Stats + render-mode toggle.
    ├── ToolPanel.cpp      Tool / brush UI.
    ├── PalettePanel.cpp   Color picker.
    ├── RenderPanel.cpp    Render-mode controls + Material editor for the
    │                      currently-selected palette slots.
    ├── GeneratorPanel.cpp Generator kind picker + per-kind parameter UI.
    ├── Fonts.cpp          Loads SF from /System at 2× for Retina.
    └── Theme.cpp          Apple-pro-app-inspired ImGui theme.
```

PLAN.md is the *original* Phase 0 handoff. It's archival — most of what's in
the "out of scope" list is now built. Don't take it as a current spec.

## Build / run loop

```sh
cmake --build build
pkill -f MacVoxel.app/Contents/MacOS/MacVoxel; sleep 0.5; open build/MacVoxel.app
```

The kill-and-relaunch is the right rhythm: AppKit treats `open` on an
already-running bundle as a no-op, so you have to actually exit the previous
process to see your changes. Ninja rebuilds are fast (~1–2 s for a single .mm
file change).

`-Wall -Wextra -Wpedantic -Werror` is on for project sources. ImGui is built
with `-Wno-everything`. Don't suppress warnings to silence; fix them.

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
  two renders with `md5` to confirm a change is/isn't a no-op.
- `--no-aces` swaps the ACES tonemap for a plain gamma-2.2 curve.
- The camera is fit-to-bounds (matching the GUI's load-time framing);
  there are no yaw/pitch/distance flags. If a scene has interior
  detail (sealed boxes, etc.) the headless view won't see it.

Sample `.vox` files live in `test/vox/`. Useful ones:
`teapot.vox` (clean diffuse), `_metal mat test.vox` (metal + emissive),
`_light test.vox` (mixed diffuse/metal/glass surfaces with small
emitters — good for spotting NEE / MIS issues).

## Conventions Paul has set

These came up repeatedly during development and are worth not relitigating:

- **Commits are per-step.** A logical fix or feature is one commit; don't bundle
  unrelated changes. Phase commits look like `P8.3.x: short title` (the `.x`
  letters disambiguate increments within a phase). Coauthor trailer is
  `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.
- **No unsolicited refactors.** If you're fixing a bug, fix the bug. Don't
  reformat surrounding code, rename variables, or tidy adjacent functions
  unless the user asked.
- **Comments explain *why*, never *what*.** The code says what. A comment
  exists when there's a hidden constraint, a workaround for a specific bug, or
  a non-obvious invariant. Single-line is the default; multi-paragraph is
  almost always wrong. No "added in P8.3" or "fixes the X case" — those rot.
- **Single-pass writing.** When something is right, write it cleanly the first
  time. Don't leave half-completed alternate paths or commented-out attempts.
- **No half-finished implementations.** Either it works or it isn't there.
- **No future-proofing.** Don't add config knobs, hooks, or abstractions for
  hypothetical future requirements. Three similar lines is fine; a premature
  abstraction is worse.
- **Test the change in the running app before reporting done.** For renderer /
  UI work, eyeballing the result matters more than the type-check passing.

## Work rhythm

- The user prefers terse updates. State what you found, what you're changing,
  and move on. Skip "Let me look at...", "I'll now...", and end-of-turn recaps.
- For exploratory questions ("why does X happen?" / "what would Y look like?"),
  give a 2–3 sentence answer with a recommendation and ask whether to proceed.
  Don't dump implementation in response to a curiosity question.
- For concrete asks, just do it. The "explain then propose" formality is
  unwelcome when the user already knows what they want.
- Auto mode is often on. Don't stop for permission on local, reversible work.
  Still ask before destructive ops or anything that affects shared state.

## Path tracer specifics (because most recent work has been here)

`src/PathTraceRenderer.mm` carries a long inline MSL shader (`kShaderSource`)
plus the Obj-C++ resource management for it. The shader has grown enough that
edits are touchy — it's worth reading the whole bounce loop before changing
the medium / glass paths.

Key invariants in the shader:

- **Coordinate space:** the shader works in *grid space*, not world space.
  `ray_origin_world` is rotated to `ray_origin = (x, -z, y)` to match the
  rasterizer's convention. All distances inside the bounce loop are in voxel
  units.
- **`medium_mat` skips same-material cells in the DDA.** A connected run of
  glass voxels reads as one medium — refraction fires only at true air↔glass
  boundaries, not at every internal cell face.
- **`medium_entry` + `medium_albedo` carry Beer-Lambert state.** Distance
  through the medium is `length(h.point - medium_entry)`; tint is
  `pow(albedo, distance * kAbsorptionScale)`. `kAbsorptionScale = 0.5` ties the
  user's albedo to a 2-voxel reference depth.
- **The DDA reports medium-exit boundaries.** Three transitions:
  skip-mat→empty cell, skip-mat→empty chunk, skip-mat→AABB-out. All return
  `h.hit = true, h.cell_val = 0` so the bounce loop's exit handler fires and
  applies BL. Without this, paths through freestanding slabs silently die.
- **`t_hit` is parametric distance from the *clipped* origin** (after AABB
  intersection), not from the world ray origin. Compute `h.point` against the
  clipped origin or you'll be off by `t_start` along the ray.
- **Color space.** Palette is sRGB on disk; the renderer decodes to linear on
  upload (`std::pow(c, 2.2f)` in `rebuildResourcesFromDocument:`) and the
  display fragment re-encodes (`pow(c, 1/2.2)`). Don't multiply linear and
  sRGB values together.
- **VNDF GGX, not naive GGX.** The microfacet sampler in `ggx_sample_vndf` is
  Heitz 2018 visible-normal sampling. Every sample is guaranteed to produce
  an above-surface reflection — no fallback-to-mirror clamp, no spike artifact.

## What the path tracer doesn't have yet

- Exposure control. ACES tonemap exists (toggleable via RenderState) and tames
  the highlight roll-off, but there's no user-facing exposure / EV slider, so
  scenes with very bright emissives still need careful authoring.
- Sun + sky model. The sky is a hardcoded constant `(0.65, 0.75, 0.95)` — no
  HDRI, no sun disc, no procedural gradient.
- Light importance sampling beyond uniform. NEE / MIS are in place
  (`nee_sample_light`, `nee_diffuse_mis`, `nee_ggx_mis`) but pick lights
  uniformly across the full per-emissive-voxel list and uniformly across the 3
  visible faces. No power-weighted or distance-weighted sampling.

These are all real upgrades but each is a project. Don't slip them in alongside
unrelated changes.

## Generators (P12.5)

Parameterized shape primitives that the user lays out via a gizmoized AABB
rather than drawing one cell at a time. The architecture is GPU-first: each
generator is a Metal compute kernel that scans its AABB at one thread per
cell, evaluates the primitive's inside-test, and atomically appends the
qualifying cell coords to an output buffer. The CPU reads the count, copies
`count × 12 bytes` directly into a `std::vector<shapes::Vec3i>` (PackedCell
in MSL = 3×int32, identical layout), and stamps the cells through the
existing `_shapePreview` machinery so the live preview / single-undo-step
commit path is shared with the shape tools.

Lives in:
- `src/Generators.h` — pure-C++ types (`Bounds3i`, `Kind`, `Params`).
- `src/GeneratorEngine.{h,mm}` — Obj-C++ engine. Holds one
  `MTLComputePipelineState` per `Kind`, a grow-only output buffer, an
  atomic counter buffer (zeroed via shared-storage CPU write — no blit
  needed on Apple Silicon's unified memory). Synchronous dispatch + wait
  for now; double-buffered async is the right move if drag rates demand
  it.
- `src/GeneratorState.{h,cpp}` — singleton holding the active kind +
  params. Mirrors `ToolState`.
- `src/ui/GeneratorPanel.cpp` — kind picker + parameter UI.
- `src/VoxelView.mm` — the gizmo state machine: click-drag-out lays the
  initial AABB (live preview during drag); mouseup leaves the box visible
  with face-normal arrow handles; clicking a handle drags that face along
  its outward normal (NDC-space projection, same trick as the Face tool's
  `faceDragVoxelsAtCursor:`); clicking outside any handle commits the
  preview through `EditHistory` as a single op; Esc cancels and rolls
  back.

Adding a new built-in is small: write the kernel function in
`kGenLibrarySource` (output protocol = thread-per-cell, atomic append on
match), add the enum entry, add a name in `KernelNameForKind`, add a panel
button, and any per-kind parameters go on `Params`. The eventual
user-authored shader path plugs into the same dispatch — that's a richer
project (runtime MSL compile + source editor + error reporting + hot
reload) but the engine doesn't need restructuring for it.

Invariants:
- Generators don't touch the document, AppKit, or ImGui. They take
  `(Bounds3i, Params)` and emit cells. Keeps the GPU-shader escape hatch
  open and the engine unit-testable in principle.
- The engine's output buffer grows 2× whenever a request exceeds capacity
  (4096-cell floor on first allocation), so a drag through bigger and
  bigger bounds doesn't realloc every frame.
- The gizmo's per-frame change detector (active kind / bounds / palette
  index) is what re-runs the engine when the user tweaks the panel — no
  ImGui callback wiring; just compare-and-refresh in the per-frame draw.

## Things that look weird but are intentional

- `transparency` controls a probabilistic split between glass-refract and
  diffuse-fallback, *not* an absorption modulator. At transparency=1 a colored
  glass still tints (Beer-Lambert with the actual albedo); MagicaVoxel does
  the opposite (transparency=1 = clear regardless of color). Paul prefers the
  current behavior on aesthetic grounds.
- `_ior` from MATL is stored as the offset above 1.0 (so `_ior=0.3` in the
  file is IOR 1.3 to us). That's the MagicaVoxel convention.
- The grid's "loose" bounds aren't retightened on `Set(0)`. In practice we
  only erase via stroke-undo, which restores prior cells, so it doesn't
  matter — but it's a correctness gotcha if you ever grow a tool that
  permanently shrinks the model.
