# MacVoxel

The editor is the Rust crate at the repository root. `cargo run` opens it.
The binary is `macvoxel`. The Swift/Metal app is in `legacy/` and is not
linked.

## Layout

`src/main.rs` is the window. `state/` is the session: `document` (palette and
camera), `files` (open and save), `objects` (bones and undo), `pointer`,
`selection`, `drag`, `pick`, `geom`, and `vox/` (`.vox` read, write, and the
rig chunk). `viewport.rs` is orbit and pointer input. `panels/` is the side
UI. `tools/` is brush shapes and generators. `mesh.rs` and `gpu.rs` draw the
edit-mode mesh. `trace/` is the CPU path tracer. `trace_gpu.rs` plus
`trace.wgsl` and `blit.wgsl` are the wgpu tracer used by Render mode.
`export/` writes glTF. `native_menu.rs` is the macOS menu. `mcp.rs`,
`remote.rs`, and `control.rs` are the MCP server and the `--control` port.
Unit tests live in `tests/` and are included from the module they cover.

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

Render mode dispatches `trace.wgsl`. The CPU tracer in `src/trace` is the
fallback and the tested algorithm; the shader uses the same sky and BSDF.
Atmospheric sky is Nishita single-scatter (Rayleigh and Mie). Off, the sky is
the flat horizon gradient. Metal samples a GGX visible normal with probability
`metallic` and otherwise uses the diffuse estimator. Glass roughness samples
that normal, then Fresnel and Snell; roughness 0 is a single delta ray.
Absorption glass stays a tinted straight ray. Save Render writes the PNG once
the frame reaches Samples. Denoise is the edge-aware filter. Open Image
Denoise is not linked.

## Tests

```sh
cargo test --offline --bin macvoxel -- --skip ping_round_trips
```

`ping_round_trips_with_the_token` needs a socket the sandbox does not allow.
Do not filter on the substring `ping`: `save_round_trips` matches it too.
The package is a binary, so `--lib` does not apply.

Comments, docs, and UI strings are English.
