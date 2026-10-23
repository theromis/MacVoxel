# MacVoxel

The editor is the Rust crate at the repository root. `cargo run` opens it.
The binary is `macvoxel-egui`. The Swift/Metal app is in `legacy/` and is not
linked.

## Layout

`src/main.rs` is the window. `state.rs` holds the document, tools, and `.vox`
load/save. `viewport.rs` is orbit and pointer input. `panels.rs` is the side
UI. `tools.rs` is brush, shapes, and generators. `mesh.rs` and `gpu.rs` draw
the edit-mode mesh. `trace.rs` is the CPU path tracer and the scene packer.
`trace_gpu.rs` is the wgpu compute tracer used by Render mode. `export.rs`
writes glTF. `native_menu.rs` is the macOS menu. `mcp.rs`, `remote.rs`, and
`control.rs` are the MCP server and the `--control` port.

## .vox

Index 0 is empty. A loaded scene keeps its node graph (`VoxGraph` on the
session): groups, layers, every animation frame, and `_hidden`. Save writes
that graph back. Frame 0 is the edited pose. Objects created in the editor
are appended. Hidden objects stay in the file and are omitted from the mesh,
the tracer, and mesh export.

Cells of a rotated model are baked into world space for editing. `Volume.rot`,
`pivot`, and `model_dims` put them back into model space on save.

## Mesh export

`export_glb` merges coplanar faces of one palette slot, then
`split_junctions` cuts an edge where a corner of another face lands in the
open span. The same plane and the same slot is not a cut. Positions are glTF
Y-up `(x, z, -y)`. The menu export uses a palette texture. `COLOR_0` is
linear. MCP `export_mesh` leaves merge off unless the caller sets it.

## Render

Render mode dispatches the compute shader in `trace_gpu.rs`. It is not
`legacy/src/PathTrace.metal`. The CPU tracer is the fallback and the tested
algorithm. Save Render writes the accumulated frame, not an offline sample
count. The Denoise checkbox is a small edge-aware filter. OIDN stays in the
legacy app.

## Tests

```sh
cargo test --offline --bin macvoxel-egui -- --skip ping_round_trips
```

`ping_round_trips_with_the_token` needs a socket the sandbox does not allow.
Do not filter on the substring `ping`: `save_round_trips` matches it too.
The package is a binary, so `--lib` does not apply.

Comments, docs, and UI strings are English.
