# MacVoxel MCP server

`MacVoxel mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server on
stdin/stdout. An agent uses it to open, edit, save, render, and export a `.vox`
document without starting the editor window.

The server is headless. A MacVoxel window that is already open does not see
these edits.

## Run

Build the app, then point a client at the binary:

```sh
cmake -B build -G Ninja && cmake --build build
claude mcp add macvoxel -- "$PWD/build/MacVoxel.app/Contents/MacOS/MacVoxel" mcp
```

Other clients use the same command:

```json
{
  "mcpServers": {
    "macvoxel": {
      "command": "/absolute/path/MacVoxel.app/Contents/MacOS/MacVoxel",
      "args": ["mcp"]
    }
  }
}
```

`MacVoxel mcp --help` prints usage and exits. Anything else on the command line
is an error. Logs and usage go to stderr. Stdout carries only protocol messages.

## Protocol

Newline-delimited JSON-RPC 2.0. The revision answered by default is
`2025-06-18`. `2026-07-28`, `2025-03-26`, and `2024-11-05` are accepted and
echoed back. A client that names another revision is answered with `2025-06-18`.

`initialize` is the first request. `ping` is answered before that. Every other
request is rejected until `initialize` has succeeded. `notifications/initialized`
is accepted and needs no reply. `tools/list`, `tools/call`, empty
`resources/list`, `resources/templates/list`, and `prompts/list`, plus
`logging/setLevel`, are the methods that follow.

A tool failure is a successful JSON-RPC result with `isError: true` and a text
block. The agent can read the message and try again. Protocol failures use the
usual codes (`-32700` parse error, `-32600` invalid request, `-32601` method
not found, `-32602` invalid params).

One message per line. A line longer than 16 MiB is refused.

## Coordinates

Edits apply to the **active object**. `x` and `y` are horizontal, `z` is up.
The world is `[-1024, 1024)`. Palette index `0` is empty and erases a cell.
Indices `1..255` are colors. Each object is at most 256 voxels on a side; a
write that would grow it past that is refused and changes nothing.

`set_active_object` folds the current object's edits into the scene and switches
which object the voxel tools read and write. `save_file`, `render`, and
`export_mesh` fold those edits before they write.

`new_document` starts an empty one-object document with the MagicaVoxel default
palette and clears the file path and the undo stack. `open_file` replaces the
session the same way.

## Tools

| Tool | Required arguments | What it does |
|---|---|---|
| `new_document` | — | Empty document, default palette |
| `open_file` | `path` | Open a `.vox`, replacing the session |
| `save_file` | — | Write `.vox`. `path` overwrites the open file when omitted |
| `inspect_document` | — | Path, counts, bounds, objects, palette |
| `get_voxel` | `x`, `y`, `z` | Palette index of one cell. `0` is empty |
| `set_voxel` | `x`, `y`, `z`, `palette` | Write one cell. One undo step |
| `set_voxels` | `cells` | Write up to 200000 cells as one undo step |
| `fill_box` | `x0`, `y0`, `z0`, `x1`, `y1`, `z1`, `palette` | Fill an inclusive box, at most 2000000 cells, one undo step |
| `get_voxels` | `x0`, `y0`, `z0`, `x1`, `y1`, `z1` | Non-empty cells inside an inclusive box, at most 100000 |
| `set_palette` | `index`, `r`, `g`, `b` | Replace one slot. `a` defaults to 255. One undo step |
| `set_active_object` | `index` | Edit a different object from `inspect_document` |
| `undo` | — | Undo the last edit |
| `redo` | — | Redo the last undone edit |
| `render` | `path` | Path-trace the whole scene to a PNG |
| `export_mesh` | `path` | Write a glTF 2.0 `.glb` of the whole scene |

`set_voxels` accepts each cell as `{"x","y","z","palette"}` or as
`[x, y, z, palette]`. A later duplicate of the same coordinate wins. Cells
that already hold the requested index are not an undo step.

`fill_box` corners may arrive in either order. The box is inclusive.

`inspect_document` returns:

- `path`, `activeObject`, `objectCount`, `voxels`
- `bounds` of the whole scene and `activeBounds` of the object being edited
  (`null` when empty). Each box is `{min: [x,y,z], max: [x,y,z]}`
- `unsynced`, `canUndo`, `canRedo`
- `objects`: `index`, `name`, `hidden`, `active`, `model`, `voxels`, `bounds`
- `palette`: 256 strings, `#rrggbbaa`, index 0 first

`render` blocks until the PNG is written. Defaults are 256×256, 16 samples,
4 bounces, seed 1, denoising off. Limits are 1..1024 pixels, 1..128 samples,
0..8 bounces. The camera frames the scene. An empty scene is an error.

`export_mesh` writes every solid voxel of every object, exposed faces only.
`vertexColors` defaults to false:

- **false.** One material. A 256-wide palette texture, and each face's UVs
  point at its palette slot.
- **true.** No image. Each vertex carries the palette color in the glTF
  `COLOR_0` attribute. The material base color is white.

The palette texture stores the sRGB bytes unchanged, so the swatch matches.
`COLOR_0` is linear in the glTF spec: each channel is converted with the sRGB
transfer curve before it is written. Storing the raw byte there makes Blender
treat it as linear and the color comes out lighter. Alpha is coverage and is
not gamma-encoded. The glTF file is Y-up. Positions are `(x, z, −y)`, so
Blender's importer keeps voxel +Z as Blender +Z.

The same mesh is available from File → Export Mesh… (⇧⌘E) and without MCP:

```sh
MacVoxel export --input in.vox --output out.glb
MacVoxel export --input in.vox --output out.glb --vertex-colors
```

## What this server does not do

It does not drive the mouse tools (brush, shapes, generators, selection) and
it does not update a running editor window. Voxel changes go through
`set_voxel`, `set_voxels`, and `fill_box` on the active object.
