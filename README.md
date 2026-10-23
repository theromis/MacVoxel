This is fork of https://tangled.org/pa.ulst.ar/MacVoxel

# MacVoxel

A native macOS voxel editor in the spirit of MagicaVoxel. SwiftUI shell over an
Obj-C++ bridge over a C++20 core, Metal for the scene view + overlay pass, GPU
ray-cast renderer for editing, GPU path tracer for render mode.

## Build

Requires macOS 14 (Sonoma) or later (SwiftUI's `@Observable` floor), Xcode
command line tools, and CMake 3.24+.

```sh
git clone <repo-url> macvoxel
cd macvoxel
cmake -B build -G Ninja
cmake --build build
open build/MacVoxel.app
```

The `-G Ninja` flag is optional but produces faster, cleaner builds.

## What it does

- Loads and saves single- and multi-model MagicaVoxel `.vox` files. Scene graph
  (nTRN/nGRP/nSHP) is honored on load. Material chunks (MATL) are parsed —
  `_diffuse`, `_metal`, `_glass`, `_emit` types come through with their
  roughness, metallic, transparency, IOR, and emission settings.
- Edits voxels with a family of tools: brush (place / erase / paint / pick,
  sizes 1–8), shapes (line / circle / square / box), face-fill flood,
  parametric generators (ellipsoid, cylinder, cone, pyramid, torus, helix,
  noise, tree, conifer) bounded by a drag-out gizmo, and neighborhood mutators
  (foliage). Drag-paint streams cells into one undoable stroke. Marquee / box /
  flood selection with cut / copy / paste / delete.
- Renders interactively via a GPU ray-cast shader with hierarchical empty-space
  skipping. Edits upload incrementally per dirty chunk, so big scenes stay
  responsive while you paint.
- Switches into a path-traced render mode for final-quality output:
  progressive accumulation, multi-bounce GI with Russian roulette, stochastic
  AA, virtual ground plane, and optional Open Image Denoise (Intel OIDN, Metal
  backend) guided by first-hit albedo/normal buffers. Materials supported:
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
- **Right-drag** — orbit.
- **Middle-drag** or **Space + drag** — pan.
- **Two-finger scroll** or **pinch** — zoom.

### Editing
- **Left-click / drag** — apply the current tool. Drag-paint accumulates as
  one undoable stroke.
- **⌥ + left-click** — eyedropper: pick the clicked voxel's palette slot.
- **⌘ + left-click / drag** — Cmd-drag a selected voxel slides the selection
  in the plane of the clicked face (lifts to a floating buffer on first drag).
- **Esc** — cancel any pending two-click shape / Generator gizmo.
- **⌘Z / ⇧⌘Z** — undo / redo, per stroke.
- **⌘X / ⌘C / ⌘V / ⌫** — cut / copy / paste / delete the current selection.
- **⇧⌘D** — deselect (commits any floating buffer to the document, clears
  marquee).
- Tool, brush, palette, materials, render and light settings all live in
  the side panels.

### File
- **⌘N / ⌘O / ⌘S / ⇧⌘S** — new / open / save / save-as `.vox`.
- **⌘W** — close window.
- **⌘Q** — quit.

## A few implementation notes

- **GPU-authoritative editing.** During a stroke the live voxel state is a
  dense 256³ `texture3d` on the GPU that the renderers sample directly; tools
  write into a preview texture composited on top, promoted into the main
  texture by a commit kernel at mouse-up. Two CPU mirrors are reconciled at
  each commit: a dense shadow that backs undo diffs, and a sparse 16³-chunk
  hash map (cells default to 0/empty) that is the on-disk `.vox` format and the
  path tracer's source. World coords are signed so MagicaVoxel scene-graph
  translations work directly.
- **Two-pass overlay composition.** The interactive ray-cast renderer + a
  tiny native Metal overlay pipeline (`SceneOverlayRenderer` + `Overlay.metal`)
  share one render encoder: scene fragments, then 2D screen-space gizmos /
  marquee / hover / selection wireframes drawn as triangle lists with
  premultiplied-alpha blend. The path-traced mode renders the scene to its own
  accumulation buffer first, then runs the overlay pass on top of the drawable
  in a follow-up encoder.
- **No greedy mesher; two traversals.** An earlier phase had a mesher; it was
  retired when the GPU ray-cast renderer outpaced it. The interactive renderer
  DDAs straight through the 256³ voxel texture, skipping empty space via a 16³
  occupancy oracle. The path tracer keeps its own coarse-grid-of-chunk-indices
  + chunk-pool structure, built from the sparse grid, that its shader DDAs
  through.
- **Color space.** Palette is sRGB on disk, converted to linear on GPU upload;
  the path tracer works in linear and the display fragment re-encodes to sRGB.
- **UI.** SwiftUI panels backed by an Obj-C++ `EditorContextBridge` around the
  C++ `EditorContext`. `MetalScene` (MTKView subclass) hosts the renderers
  inside an `NSViewRepresentable`; SwiftUI never sees C++ directly.

## License

MIT. See `LICENSE`.
