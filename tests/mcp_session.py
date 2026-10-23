#!/usr/bin/env python3
"""Headless checks for the MCP server.

Renders two documents in one session and compares pixels, so a stale path
tracer cache (versions restarting at zero after open_file) fails the run.
Also checks batched set_palette and greedy mesh merge.
"""

import json
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "build" / "MacVoxel.app" / "Contents" / "MacOS" / "MacVoxel"


def png_pixels(path):
    data = Path(path).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path} is not a PNG")
    pos = 8
    width = height = color_type = None
    idat = bytearray()
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        kind = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", chunk
            )
            if depth != 8 or interlace != 0 or color_type not in (2, 6):
                raise SystemExit(f"unexpected PNG header in {path}")
        elif kind == b"IDAT":
            idat += chunk
        elif kind == b"IEND":
            break
    bpp = 4 if color_type == 6 else 3
    raw = zlib.decompress(bytes(idat))
    stride = width * bpp
    rows = []
    prev = bytearray(stride)
    i = 0
    for _y in range(height):
        filt = raw[i]
        i += 1
        row = bytearray(raw[i : i + stride])
        i += stride
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            up = prev[x]
            ul = prev[x - bpp] if x >= bpp else 0
            if filt == 0:
                pred = 0
            elif filt == 1:
                pred = left
            elif filt == 2:
                pred = up
            elif filt == 3:
                pred = (left + up) // 2
            elif filt == 4:
                p = left + up - ul
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - ul)
                pred = left if pa <= pb and pa <= pc else up if pb <= pc else ul
            else:
                raise SystemExit(f"bad PNG filter {filt}")
            row[x] = (row[x] + pred) & 255
        rows.append(bytes(row))
        prev = row
    return b"".join(rows)


class Session:
    def __init__(self, proc):
        self.proc = proc
        self.seq = 0

    def request(self, method, params=None, note=False):
        self.seq += 1
        msg = {"jsonrpc": "2.0", "method": method}
        if not note:
            msg["id"] = self.seq
        if params is not None:
            msg["params"] = params
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        if note:
            return None
        line = self.proc.stdout.readline()
        if not line:
            raise SystemExit("server closed stdout")
        reply = json.loads(line)
        if "error" in reply:
            raise SystemExit(f"{method} failed: {reply['error']}")
        return reply["result"]

    def tool(self, name, arguments=None):
        result = self.request(
            "tools/call", {"name": name, "arguments": arguments or {}}
        )
        if result.get("isError"):
            raise SystemExit(f"{name} failed: {result['content'][0]['text']}")
        return json.loads(result["content"][0]["text"])


def fill(session, palette):
    session.tool(
        "fill_box",
        {
            "x0": 0,
            "y0": 0,
            "z0": 0,
            "x1": 7,
            "y1": 7,
            "z1": 7,
            "palette": palette,
        },
    )


def main():
    if not BIN.is_file():
        raise SystemExit(f"missing {BIN}; build MacVoxel first")
    proc = subprocess.Popen(
        [str(BIN), "mcp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    try:
        session = Session(proc)
        session.request(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "mcp_session", "version": "0"},
            },
        )
        with tempfile.TemporaryDirectory(prefix="macvoxel-mcp-") as tmp:
            tmp = Path(tmp)
            check_palette(session)
            check_merge(session, tmp)
            check_junctions(session, tmp)
            check_camera(session, tmp)
            check_reload(session, tmp)
    finally:
        proc.stdin.close()
        code = proc.wait(timeout=30)
        if code != 0:
            raise SystemExit(f"server exited {code}")
    print("ok")


def check_palette(session):
    session.tool("new_document")
    before = session.tool("inspect_document")["palette"]
    changed = session.tool(
        "set_palette",
        {
            "entries": [
                {"index": 4, "r": 1, "g": 2, "b": 3, "a": 4},
                {"index": 5, "r": 9, "g": 8, "b": 7},
                {"index": 4, "r": 10, "g": 20, "b": 30, "a": 40},
            ]
        },
    )
    if changed["changed"] != 2:
        raise SystemExit(f"batch changed {changed['changed']} slots, want 2")
    palette = session.tool("inspect_document")["palette"]
    if palette[4] != "#0a141e28" or palette[5] != "#090807ff":
        raise SystemExit(f"batch palette mismatch: {palette[4]} {palette[5]}")
    session.tool("undo")
    restored = session.tool("inspect_document")
    if restored["palette"] != before or restored["canUndo"]:
        raise SystemExit("batch set_palette was not one undo step")
    one = session.tool("set_palette", {"index": 1, "r": 255, "g": 0, "b": 0})
    if one.get("color") != "#ff0000ff":
        raise SystemExit(f"single set_palette returned {one}")
    session.tool("undo")


def check_merge(session, tmp):
    session.tool("new_document")
    session.tool(
        "fill_box",
        {"x0": 0, "y0": 0, "z0": 0, "x1": 1, "y1": 0, "z1": 0, "palette": 1},
    )
    plain = session.tool("export_mesh", {"path": str(tmp / "plain.glb")})
    merged = session.tool(
        "export_mesh", {"path": str(tmp / "merged.glb"), "merge": True}
    )
    if plain["triangles"] != 20 or merged["triangles"] != 12:
        raise SystemExit(
            f"merge triangles plain={plain['triangles']} merged={merged['triangles']}, "
            "want 20 and 12"
        )
    if not merged["merged"] or plain["merged"]:
        raise SystemExit("merge flag was not reported")
    session.tool("new_document")
    session.tool("set_voxel", {"x": 0, "y": 0, "z": 0, "palette": 1})
    session.tool("set_voxel", {"x": 1, "y": 0, "z": 0, "palette": 2})
    split = session.tool(
        "export_mesh", {"path": str(tmp / "split.glb"), "merge": True}
    )
    if split["triangles"] != 20:
        raise SystemExit(
            f"different colors merged to {split['triangles']} triangles, want 20"
        )


def glb_triangles(path):
    data = Path(path).read_bytes()
    if data[:4] != b"glTF":
        raise SystemExit(f"{path} is not a glb")
    off = 12
    json_len = struct.unpack_from("<I", data, off)[0]
    meta = json.loads(data[off + 8 : off + 8 + json_len])
    off += 8 + json_len
    bin_len = struct.unpack_from("<I", data, off)[0]
    blob = data[off + 8 : off + 8 + bin_len]

    def view_bytes(accessor):
        view = meta["bufferViews"][accessor["bufferView"]]
        start = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
        return start

    pos = meta["accessors"][0]
    count = pos["count"]
    start = view_bytes(pos)
    floats = struct.unpack_from("<" + "f" * (count * 3), blob, start)
    verts = []
    for i in range(0, count * 3, 3):
        # glTF (gx, gz, -gy) → grid (gx, gy, gz)
        verts.append(
            (round(floats[i]), round(-floats[i + 2]), round(floats[i + 1]))
        )
    idx = meta["accessors"][3]
    istart = view_bytes(idx)
    n = idx["count"]
    if idx["componentType"] == 5125:
        indices = struct.unpack_from("<" + "I" * n, blob, istart)
    elif idx["componentType"] == 5123:
        indices = struct.unpack_from("<" + "H" * n, blob, istart)
    else:
        raise SystemExit(f"unexpected index type {idx['componentType']}")
    tris = []
    for i in range(0, n, 3):
        tris.append((indices[i], indices[i + 1], indices[i + 2]))
    return verts, tris


def on_open_segment(a, b, v):
    ab = (b[0] - a[0], b[1] - a[1], b[2] - a[2])
    av = (v[0] - a[0], v[1] - a[1], v[2] - a[2])
    cross = (
        ab[1] * av[2] - ab[2] * av[1],
        ab[2] * av[0] - ab[0] * av[2],
        ab[0] * av[1] - ab[1] * av[0],
    )
    if cross != (0, 0, 0):
        return False
    dot = ab[0] * av[0] + ab[1] * av[1] + ab[2] * av[2]
    ab2 = ab[0] * ab[0] + ab[1] * ab[1] + ab[2] * ab[2]
    return 0 < dot < ab2


def check_junctions(session, tmp):
    # Three voxels in a row and one sitting on the middle. The merged top
    # is one long quad; the upper voxel's corners land mid-edge.
    session.tool("new_document")
    session.tool(
        "set_voxels",
        {
            "cells": [
                {"x": 0, "y": 0, "z": 0, "palette": 1},
                {"x": 1, "y": 0, "z": 0, "palette": 1},
                {"x": 2, "y": 0, "z": 0, "palette": 1},
                {"x": 1, "y": 0, "z": 1, "palette": 2},
            ]
        },
    )
    session.tool("export_mesh", {"path": str(tmp / "bank.glb")})
    session.tool("export_mesh", {"path": str(tmp / "bank-merge.glb"), "merge": True})
    verts, tris = glb_triangles(tmp / "bank-merge.glb")
    points = set(verts)
    for tri in tris:
        for edge in ((0, 1), (1, 2), (2, 0)):
            a = verts[tri[edge[0]]]
            b = verts[tri[edge[1]]]
            for v in points:
                if v != a and v != b and on_open_segment(a, b, v):
                    raise SystemExit(f"T-junction: {v} lies on {a}–{b}")


def check_camera(session, tmp):
    session.tool("new_document")
    session.tool(
        "set_voxels",
        {
            "cells": [
                {"x": 0, "y": 0, "z": 0, "palette": 1},
                {"x": 1, "y": 0, "z": 0, "palette": 1},
                {"x": 2, "y": 0, "z": 0, "palette": 1},
                {"x": 0, "y": 1, "z": 0, "palette": 1},
            ]
        },
    )
    common = {
        "width": 64,
        "height": 64,
        "samples": 4,
        "bounces": 1,
        "seed": 1,
        "denoise": False,
    }
    session.tool("render", {"path": str(tmp / "yaw0.png"), "yaw": 0, **common})
    session.tool("render", {"path": str(tmp / "yaw180.png"), "yaw": 180, **common})
    if png_pixels(tmp / "yaw0.png") == png_pixels(tmp / "yaw180.png"):
        raise SystemExit("yaw 0 and yaw 180 rendered the same image")
    session.tool(
        "render", {"path": str(tmp / "down.png"), "pitch": 90, **common}
    )
    if png_pixels(tmp / "down.png") == png_pixels(tmp / "yaw0.png"):
        raise SystemExit("pitch 90 matched the side view")


def save_box(session, path, palette, color):
    session.tool("new_document")
    session.tool(
        "set_palette",
        {"index": palette, "r": color[0], "g": color[1], "b": color[2]},
    )
    fill(session, palette)
    session.tool("save_file", {"path": str(path)})


def render(session, vox, png):
    opened = session.tool("open_file", {"path": str(vox)})
    info = session.tool("inspect_document")
    if info["path"] != str(vox):
        raise SystemExit(f"inspect path {info['path']} != {vox}")
    if info["voxels"] != opened["voxels"]:
        raise SystemExit("inspect voxel count does not match open_file")
    session.tool(
        "render",
        {
            "path": str(png),
            "width": 64,
            "height": 64,
            "samples": 4,
            "bounces": 1,
            "seed": 1,
        },
    )
    return png_pixels(png)


def check_reload(session, tmp):
    solid = tmp / "solid.vox"
    holes = tmp / "holes.vox"
    red = tmp / "red.vox"
    blue = tmp / "blue.vox"
    session.tool("new_document")
    fill(session, 1)
    session.tool("save_file", {"path": str(solid)})
    session.tool("new_document")
    cells = [
        {"x": x, "y": y, "z": z, "palette": 1}
        for x in range(8)
        for y in range(8)
        for z in range(8)
        if (x + y + z) % 2 == 0
    ]
    session.tool("set_voxels", {"cells": cells})
    session.tool("save_file", {"path": str(holes)})
    save_box(session, red, 1, (255, 0, 0))
    save_box(session, blue, 1, (0, 0, 255))

    solid_px = render(session, solid, tmp / "solid.png")
    holes_px = render(session, holes, tmp / "holes.png")
    if solid_px == holes_px:
        raise SystemExit("render after open_file reused the previous geometry")
    red_px = render(session, red, tmp / "red.png")
    blue_px = render(session, blue, tmp / "blue.png")
    if red_px == blue_px:
        raise SystemExit("render after open_file reused the previous palette")


if __name__ == "__main__":
    main()
