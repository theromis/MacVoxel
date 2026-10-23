# MacVoxel MCP

Two programs speak the [Model Context Protocol](https://modelcontextprotocol.io)
on stdin/stdout. They do not share a document.

| Server | Binary | Window | What an agent can do |
|---|---|---|---|
| egui editor | `macvoxel-egui` | optional | Edit voxels. Screenshot, inspect, and click the live window when connected. No path tracer, no mesh export. |
| C++ editor | `MacVoxel mcp` | never | Edit voxels, path-trace a PNG, export glTF. An already open MacVoxel window does not see these edits. |

## egui editor

`macvoxel-egui mcp` is the egui preview (`egui/`). Build it with Cargo:

```sh
cargo build --manifest-path egui/Cargo.toml
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

`save_file` writes the active volume only, origin-aligned, as one MagicaVoxel
model. It does not write the other objects or their translations.
`open_file` keeps the first model in the file. Extra models and `nTRN`
transforms are not applied.

### Tools

| Tool | Required arguments | What it does |
|---|---|---|
| `new_document` | — | Empty document, default palette, cleared path and undo stack |
| `open_file` | `path` | Open a `.vox`, replacing the session |
| `save_file` | — | Write the active volume. `path` overwrites the open file when omitted |
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
| `screenshot` | — | PNG of the whole editor window. Connected mode only |
| `screenshot_viewport` | — | PNG of the 3D viewport, including its mode chips. Connected mode only |
| `screenshot_region` | `x`, `y`, `width`, `height` | PNG of a rectangle in window points. Connected mode only |
| `ui_inspect` | — | Previous frame's controls, tool, mode, active object, voxel count, and status. Connected mode only |
| `ui_click` | `x`, `y` | Click the topmost registered control. A viewport hit stamps the active tool. Connected mode only |

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
- `objects`: `index`, `name`, `hidden` (always false), `active`, `model`,
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
Duplicate, and Delete buttons, the Model/Object and Edit/Render chips, and
the viewport. Each region is `id`, `label`, `x`, `y`, `width`, `height` in
window points from the top-left of the client area. The reply also includes
`tool`, `toolMode`, `editorMode`, `renderMode`, `activeObject`, `voxels`, and
`status`.

`ui_click` takes `x` and `y` in those same points and activates the topmost
region that contains the point. A hit on the viewport is a press and release
of the active tool. A point on no region is an error. Both tools need the
connected window; headless they fail like the screenshots.

### What this server does not do

It does not path-trace, save a render, or export a mesh. It does not drive
every mouse tool by name. `ui_click` only hits the controls `ui_inspect`
lists, plus a stamp in the viewport. Voxel changes also go through
`set_voxel`, `set_voxels`, and `fill_box` on the active object. Screenshots
need the connected window.

## C++ editor

`MacVoxel mcp` is a server on stdin/stdout. An agent uses it to open, edit,
save, render, and export a `.vox` document without starting the editor window.

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

An MCP client keeps the server binary it launched. After rebuilding MacVoxel,
restart the client or its session to load the new binary.

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
| `set_palette` | `index`, `r`, `g`, `b` or `entries` | Replace one slot, or many via `entries`, as one undo step. `a` defaults to 255 |
| `set_active_object` | `index` | Edit a different object from `inspect_document` |
| `undo` | — | Undo the last edit |
| `redo` | — | Redo the last undone edit |
| `render` | `path` | Path-trace the whole scene to a PNG |
| `export_mesh` | `path` | Write a glTF 2.0 `.glb` of the whole scene. `merge` defaults to false |

`set_voxels` accepts each cell as `{"x","y","z","palette"}` or as
`[x, y, z, palette]`. A later duplicate of the same coordinate wins. Cells
that already hold the requested index are not an undo step.

`fill_box` corners may arrive in either order. The box is inclusive.

`set_palette` takes either one slot (`index`, `r`, `g`, `b`, optional `a`) or
`entries`: an array of those objects, at most 256. A later duplicate `index`
wins. The batch is one undo step. Slots that already hold the requested color
are skipped, and a call that changes nothing does not push undo. Pass one form
or the other, not both.

`inspect_document` returns:

- `path`, `activeObject`, `objectCount`, `voxels`
- `bounds` of the whole scene and `activeBounds` of the object being edited
  (`null` when empty). Each box is `{min: [x,y,z], max: [x,y,z]}`
- `unsynced`, `canUndo`, `canRedo`
- `objects`: `index`, `name`, `hidden`, `active`, `model`, `voxels`, `bounds`
- `palette`: 256 strings, `#rrggbbaa`, index 0 first

`render` blocks until the PNG is written. Defaults are 256×256, 16 samples,
4 bounces, seed 1, denoising on. Limits are 1..1024 pixels, 1..128 samples,
0..8 bounces. `denoise` false writes the raw samples; the editor's own export
is unchanged. The camera frames the scene (30° yaw, 25° pitch, distance that
fits it). `yaw` and `pitch` are degrees around that target; omit either to
keep the framing angle. Pitch 90 looks straight down, and pitch is limited to
-90..90. `distance` multiplies the framing distance (greater than 0, at most
100, default 1). An empty scene is an error.

`export_mesh` writes every solid voxel of every object, exposed faces only.
`merge` defaults to false, which writes one quad per exposed face. `true`
greedy-merges coplanar faces that share a palette slot into larger quads, so
a flat run of the same color becomes one rectangle instead of a quad per voxel.
Edges of those quads are then split where a corner of a neighbouring face on
a different plane or palette slot lands in the middle, so those seams are not
T-junctions. Triangles of one merged face share vertices. The default stays
one quad per face, so existing output does not change.
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
MacVoxel export --input in.vox --output out.glb --merge
```

## What this server does not do

It does not drive the mouse tools (brush, shapes, generators, selection) and
it does not update a running editor window. Voxel changes go through
`set_voxel`, `set_voxels`, and `fill_box` on the active object.
