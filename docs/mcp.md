# MacVoxel MCP

`macvoxel-egui` speaks the [Model Context Protocol](https://modelcontextprotocol.io)
on stdin/stdout. It is the editor in this repository.

| Server | Binary | Window | What an agent can do |
|---|---|---|---|
| MacVoxel | `macvoxel-egui` | optional | Edit voxels, export glTF, and path-trace a PNG with `render`. Screenshot, inspect, and click the live window when connected. |

## Editor

`macvoxel-egui mcp` is the Rust editor. Build it from the repository root:

```sh
cargo build
```

The binary is `target/debug/macvoxel-egui` (or the path Cargo prints). Logs and
usage go to stderr. Stdout carries only protocol messages.

### Headless

```sh
macvoxel-egui mcp
```

The session lives in this process. It starts empty: one object, the default
palette, no file path. No window opens. `screenshot`, `screenshot_viewport`,
`screenshot_region`, `ui_inspect`, and `ui_click` fail and say how to connect.
`macvoxel-egui mcp --help`
prints usage and exits. Any other argument is an error, so a client that meant
to reach the window does not silently edit a private document.

```json
{
  "mcpServers": {
    "macvoxel-egui": {
      "command": "/absolute/path/macvoxel-egui",
      "args": ["mcp"]
    }
  }
}
```

### Connected to the window

Start the editor with a control port. It listens on `127.0.0.1` only.

```sh
macvoxel-egui --control 7979
macvoxel-egui --control 7979 path/to/model.vox
```

`MACVOXEL_CONTROL_PORT` is the port when `--control` is omitted. A port on the
command line wins.

```sh
macvoxel-egui mcp --connect 127.0.0.1:7979
```

`--connect` requires `HOST:PORT`. Without it, or with an unknown argument, the
process exits instead of falling back to a headless session. If nothing is
listening, startup fails.

`--launch` opens this same binary with `--control PORT` when the port is
closed, then waits up to 20 seconds. If the editor is already listening, it
connects and does not open a second window.

```json
{
  "mcpServers": {
    "macvoxel-egui": {
      "command": "/absolute/path/macvoxel-egui",
      "args": ["mcp", "--connect", "127.0.0.1:7979", "--launch"]
    }
  }
}
```

The editor writes an unguessable token to an owner-only file,
`macvoxel-control-<port>.token`, under `$XDG_RUNTIME_DIR` or `~/.cache`. The
MCP bridge reads that file itself. A request without the token is refused.
The path is printed on stderr when the port opens; the token is not.

Edits from a connected client appear in the open window. The headless session
and the window are different documents.

### Protocol

Newline-delimited JSON-RPC 2.0, the same rules as the C++ server below: one
message per line, 16 MiB limit, `initialize` first, `ping` before that, tool
failures as `isError: true`. The default revision is `2025-06-18`.
`2026-07-28`, `2025-03-26`, and `2024-11-05` are accepted and echoed back.

### Coordinates

Edits apply to the **active object**, in that object's local cells. `x` and `y`
are horizontal, `z` is up. The object's `translation` from `inspect_document`
is only where it sits in the window. Palette index `0` is empty and erases a
cell. Indices `1..255` are colors. A cell must lie in `[-1024, 1024)`. A write
that would make the active object longer than 256 on any axis is refused and
changes nothing.

`save_file` writes every object. A file that had a scene graph is written
back with that graph: groups, layers, hidden objects, and animation frames
after the first stay. Frame 0 takes the edited translation, rotation, name,
and `_hidden`. Each model is at most 256 cells on an axis. A rotation read
from the file is baked into the cells for editing and written back as `_r`.
Resizing that object keeps the rotation. A new document, or a file with no
scene graph, is saved as one group of objects.
`open_file` loads every object. `nTRN` translation and rotation are applied,
and `_hidden` on a node or an ancestor hides that object in the mesh and the
tracer. A file with no scene graph still loads its first model.

### Tools

| Tool | Required arguments | What it does |
|---|---|---|
| `new_document` | — | Empty document, default palette, cleared path and undo stack |
| `open_file` | `path` | Open a `.vox`, replacing the session |
| `save_file` | — | Write every non-empty object. `path` overwrites the open file when omitted |
| `inspect_document` | — | Path, counts, bounds, objects, palette |
| `get_voxel` | `x`, `y`, `z` | Palette index of one local cell. `0` is empty |
| `set_voxel` | `x`, `y`, `z`, `palette` | Write one cell. One undo step |
| `set_voxels` | `cells` | Write up to 200000 cells as one undo step |
| `fill_box` | `x0`, `y0`, `z0`, `x1`, `y1`, `z1`, `palette` | Fill an inclusive box, at most 2000000 cells, one undo step |
| `get_voxels` | `x0`, `y0`, `z0`, `x1`, `y1`, `z1` | Non-empty cells inside an inclusive box, at most 100000 |
| `set_palette` | `index`, `r`, `g`, `b` or `entries` | Replace one slot, or many via `entries`, as one undo step. `a` defaults to 255 |
| `set_active_object` | `index` | Edit a different object from `inspect_document` |
| `undo` | — | Undo the last edit |
| `redo` | — | Redo the last undone edit |
| `render` | `path` | Path-trace the scene to a PNG. `width` and `height` default to 256. `samples` defaults to 16. `bounces` defaults to 4. `denoise` defaults to true. `yaw` defaults to 30°, `pitch` to 25° |
| `screenshot` | — | PNG of the whole editor window. Connected mode only |
| `screenshot_viewport` | — | PNG of the 3D viewport, including its mode chips. Connected mode only |
| `screenshot_region` | `x`, `y`, `width`, `height` | PNG of a rectangle in window points. Connected mode only |
| `ui_inspect` | — | Previous frame's controls, tool, mode, active object, voxel count, and status. Connected mode only |
| `ui_click` | `x`, `y` | Click the topmost registered control. A viewport hit stamps the active tool. A slider sets its value from the point. A palette cell selects that slot. Connected mode only |
| `export_mesh` | `path` | Write a glTF 2.0 `.glb` of every object. `merge` defaults to false. `vertexColors` defaults to false |

`set_voxels` accepts each cell as `{"x","y","z","palette"}` or as
`[x, y, z, palette]`. A later duplicate of the same coordinate wins. Cells
that already hold the requested index are not an undo step.

`fill_box` corners may arrive in either order. The box is inclusive.

`set_palette` takes either one slot (`index`, `r`, `g`, `b`, optional `a`) or
`entries`: an array of those objects, at most 256. Pass one form or the other,
not both. A call that changes nothing does not push undo.

`inspect_document` returns:

- `path`, `activeObject`, `objectCount`, `voxels` (every object)
- `bounds` of every object in world space and `activeBounds` of the object
  being edited (`null` when empty). Each box is `{min: [x,y,z], max: [x,y,z]}`
- `unsynced` (always false; edits are already in the window), `canUndo`, `canRedo`
- `objects`: `index`, `name`, `hidden`, `active`, `model`,
  `voxels`, local `bounds`, and `translation` `[x,y,z]`
- `palette`: 256 strings, `#rrggbbaa`, index 0 first

A screenshot tool returns a text block with `width`, `height`, and `path`, plus
an MCP `image` block (`image/png`). `path` also writes that file. Omit it to
keep the picture only in the reply. `screenshot_region` is measured in window
points from the top-left of the client area, not the title bar. On a retina
display the PNG is larger than the point size. A rectangle outside the window
is an error.

`ui_inspect` describes the previous frame. `window` is the client area.
`regions` lists the tool buttons, Add/Remove/Paint, the outliner New,
Duplicate, and Delete buttons, the sliders, the palette cells, the
Model/Object and Edit/Render chips, and the viewport. Each region is `id`,
`label`, `x`, `y`, `width`, `height` in window points from the top-left of
the client area. The reply also includes `tool`, `toolMode`, `editorMode`,
`renderMode`, `activeObject`, `voxels`, and `status`.

`ui_click` takes `x` and `y` in those same points and activates the topmost
region that contains the point. A hit on the viewport is a press and release
of the active tool. A hit on a slider sets that slider from how far `x` is
along the track. A hit on a palette cell selects that slot. A point on no
region is an error. Both tools need the connected window; headless they fail
like the screenshots.

`render` path-traces every visible object and writes a PNG. It does not need a
window. `width` and `height` are 1..1024 and default to 256. `samples` is
1..128 and defaults to 16. `bounces` is 0..8 and defaults to 4. `seed`
defaults to 1. The camera frames the scene, then orbits: `yaw` defaults to
30 degrees, `pitch` to 25 degrees (−90..90), and `distance` multiplies that
framing distance (greater than 0, at most 100). The file is ACES tonemapped.
`denoise` defaults to true and runs the editor's edge-aware filter. Open
Image Denoise is not linked. An empty scene is an error. The call does not
move the editor camera. The reply is `path`, `width`, `height`, and `samples`.

`export_mesh` writes every solid voxel of every visible object, exposed faces
only. Hidden objects are left out. `merge` defaults to false, one quad per
exposed face. `true` greedy-merges coplanar faces that share a palette slot,
then splits an edge where a corner of a neighbouring face on a different
plane or palette slot lands in the open span, so the seam is not a
T-junction. `vertexColors` defaults to false:
one material, a 256-wide palette texture, and each face's UVs point at its
palette slot. `true` stores a linear `COLOR_0` and no image. The palette
texture keeps the sRGB bytes. `COLOR_0` is converted with the sRGB transfer
curve. The file is Y-up, positions `(x, z, −y)`. File → Export Mesh… uses the
palette texture and always merges. An empty scene is an error.

### What this server does not do

Render mode in the window path-traces on the GPU; saving that frame is a
window command. `render` is a separate CPU trace. It does not drive every mouse tool
by name. `ui_click` hits the controls `ui_inspect` lists, including sliders
and palette cells, plus a stamp in the viewport. Voxel changes also go
through `set_voxel`, `set_voxels`, and `fill_box` on the active object.
Screenshots need the connected window.

## Legacy editor

The Swift/Metal app in `legacy/` has its own headless MCP server. Its `render`
tool path-traces on Metal and can run Open Image Denoise. Build it from that
directory (`cmake -B build`) and run
`MacVoxel mcp`. It does not share a document with `macvoxel-egui`. See
`legacy/README.md`.
