This is a fork of https://tangled.org/pa.ulst.ar/MacVoxel

# MacVoxel

A voxel editor in the spirit of MagicaVoxel. The application is a Rust
program: an egui window, a wgpu viewport, and a `.vox` document. The earlier
Swift/Metal editor is in [`legacy/`](legacy/README.md).

## Build

```sh
cargo run
cargo run -- path/to/model.vox
```

The binary is `macvoxel-egui`. On macOS the File and Edit commands live on
the application menu bar. Elsewhere those commands are not in the window yet.

## What it does

- Loads and saves MagicaVoxel `.vox` files. A file that has a scene graph is
  written back with its groups, layers, hidden objects, and animation frames.
  Frame 0 keeps the edited translation, rotation, name, and `_hidden`.
  Materials (`_diffuse`, `_metal`, `_glass`, `_emit`) round-trip.
- Edits voxels with a brush, line, box, face fill, generators, and a marquee.
  Object mode moves, rotates, and flips whole objects. Strokes undo as one step.
- Draws the scene as a mesh. Coplanar faces of one palette color merge, and
  the export then splits edges so a neighbour's corner is not a T-junction.
- Switches to a path-traced Render mode. The frame accumulates on the GPU
  through wgpu. A scene that does not fit one grid falls back to the CPU
  tracer. Save Render writes the frame that is on screen.

## Controls

- **Right-drag** orbits. **Scroll** zooms. **Space-drag** or middle-drag pans.
- **Left-drag** uses the active tool.
- **V** brush, **L** line, **B** box, **F** face, **U** mutator, **M** marquee.
- In Object mode, **X / Y / Z** rotates the active object. **Shift** flips it.
- **⌘Z / ⇧⌘Z** undo and redo. **⌘C / ⌘X / ⌘V** copy, cut, and paste.
- **⌘N / ⌘O / ⌘S / ⇧⌘S** new, open, save, and save as.
- **⇧⌘E** exports a glTF `.glb` with a palette texture and merged faces.

## MCP

`macvoxel-egui mcp` edits a document over stdin/stdout. `render` path-traces
a PNG in that process. Connected to a window it can also screenshot and
click. Details are in [docs/mcp.md](docs/mcp.md).

```sh
cargo build
macvoxel-egui --control 7979
macvoxel-egui mcp --connect 127.0.0.1:7979 --launch
```

## License

MIT. See `LICENSE`.
