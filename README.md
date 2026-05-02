# MacVoxel

A native macOS voxel editor in the spirit of MagicaVoxel. AppKit shell, Metal-backed
content view, Dear ImGui for all in-window UI, GPU ray-cast renderer for editing,
GPU path tracer for render mode.

## Build

Requires macOS 13 (Ventura) or later, Xcode command line tools, and CMake 3.24+.

```sh
git clone --recurse-submodules <repo-url> macvoxel
cd macvoxel
cmake -B build -G Ninja
cmake --build build
open build/MacVoxel.app
```

If you cloned without `--recurse-submodules`:

```sh
git submodule update --init --recursive
```

The `-G Ninja` flag is optional but produces faster, cleaner builds.

## What it does

- Loads and saves single- and multi-model MagicaVoxel `.vox` files. Scene graph
  (nTRN/nGRP/nSHP) is honored on load. Material chunks (MATL) are parsed —
  `_diffuse`, `_metal`, `_glass`, `_emit` types come through with their
  roughness, metallic, transparency, IOR, and emission settings.
- Edits voxels with place / erase / paint / pick tools, brush sizes 1–8.
  Drag-paint streams cells into one undoable stroke. Box selection with cut /
  copy / paste / delete.
- Renders interactively via a GPU ray-cast shader with hierarchical empty-space
  skipping. Edits upload incrementally per dirty chunk, so big scenes stay
  responsive while you paint.
- Switches into a path-traced render mode for final-quality output:
  progressive accumulation, multi-bounce GI with Russian roulette, stochastic
  AA, virtual ground plane. Materials supported:
  - **Diffuse** — cosine-weighted hemisphere bounce.
  - **Metal** — GGX VNDF microfacet sampling, `metallic` toggles between
    specular and diffuse paths, `roughness` widens the lobe.
  - **Emissive** — `emission` is the multiplier on the albedo color, terminates
    the path on hit.
  - **Glass** — Fresnel reflect / Snell refract on entry and exit, GGX VNDF
    microfacets for frosted glass, true total internal reflection,
    Beer-Lambert absorption through the medium body, transparency probabilistically
    blends glass-vs-diffuse.

## Controls

### Camera
- **Option + drag** — orbit (drag-the-world).
- **Option + Shift + drag** — pan.
- **Two-finger scroll** or **pinch** — zoom.

### Editing
- **Left-click** — apply the current tool (place / erase / paint / pick).
- **Drag** — drag-paint with the current tool, accumulated as one undo step.
- **B** — box selection. Click-drag to mark a region; copy / cut / paste / delete
  apply to it.
- **⌘Z / ⇧⌘Z** — undo / redo, per stroke.
- **⌘X / ⌘C / ⌘V** — cut / copy / paste the current selection.
- Brush size, palette index, tool, and material type are all in the side panels.

### File
- **⌘O / ⌘S / ⇧⌘S** — open / save / save-as `.vox`.
- **⌘D** — toggle the ImGui demo window (debug aid).
- **⌘Q** — quit.

Dragging inside an ImGui window never moves the camera or edits voxels — the
`ImGui::GetIO().WantCaptureMouse` gate suppresses scene input.

## A few implementation notes

- **Sparse chunked grid.** Voxels live in 16³ chunks keyed by chunk-coord in a
  hash map. Cells default to 0 (empty); world coords are signed so MagicaVoxel
  scene-graph translations work directly. The grid tracks dirty chunks so the
  GPU only re-uploads what changed.
- **Single render pass per frame.** Scene → ImGui both encode into one
  `MTLRenderCommandEncoder` with a shared depth buffer. The path-traced mode
  uses a two-pass setup (accumulate into RGBA32F float texture, then divide by
  sample count for display) but still composites ImGui in a single pass on top.
- **No greedy mesher.** An earlier phase had one; it was retired when the GPU
  ray-cast renderer outpaced it. The grid is uploaded directly to a
  coarse-grid-of-chunk-indices + chunk pool layout that the shader DDAs through.
- **Color space.** Palette is sRGB on disk, converted to linear on GPU upload;
  the path tracer works in linear and the display fragment re-encodes to sRGB.
- **UI.** Dear ImGui (docking branch). San Francisco at runtime from
  `/System/Library/Fonts/SFNS.ttf` — Apple's license forbids bundling it. A
  custom theme is in `src/ui/Theme.cpp`.

## License

MIT. See `LICENSE`.
