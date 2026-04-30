# MacVoxel

A native macOS voxel editor in the spirit of MagicaVoxel. AppKit shell, Metal-backed
content view, Dear ImGui for all in-window UI.

Current state: **Phase 3** — voxels render as one instanced cube per filled cell, with
MagicaVoxel `.vox` import/export, orbit/pan/zoom camera, and a debug Model panel. See
`PLAN.md` for the full roadmap.

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

The `-G Ninja` flag is optional but produces faster, cleaner builds; omit it to use
CMake's default Makefile generator.

## What you should see

- Window titled **MacVoxel**, 1280×800, dark slate-blue (`#1e1e2e`) interior.
- On launch: a 16×16×16 grid containing a single voxel — proof of life until
  you open a real model.
- **File → Open** (⌘O) loads a MagicaVoxel `.vox` file. The camera auto-frames
  the model and the **Model** panel updates with dimensions, voxel count,
  palette swatches, and frame timing. **File → Save / Save As** (⌘S / ⇧⌘S)
  writes a single-model `.vox`.
- Each voxel is rendered as a back-face-culled, depth-tested instanced cube
  with a hard-coded directional light. There is no interior-face culling yet —
  Phase 4 (greedy meshing) is the optimization step.
- **⌘D** toggles the full ImGui demo window (also under View → Show ImGui Demo).
- **⌘Q** or closing the window quits cleanly.

### Camera controls

- **Option + drag** — orbit (drag-the-world: scene follows the cursor).
- **Option + Shift + drag** — pan.
- **Two-finger scroll** or **pinch** — zoom.
- Dragging inside an ImGui window never moves the camera — the
  `ImGui::GetIO().WantCaptureMouse` gate suppresses scene input there.

The UI font is San Francisco, loaded at runtime from `/System/Library/Fonts/SFNS.ttf`.
Apple's license forbids bundling SF, so it is not committed; macOS 13+ ships it at
that path.

## License

MIT. See `LICENSE`.
