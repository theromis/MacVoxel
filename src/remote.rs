//! Document operations shared by the headless MCP session and the window's
//! control port. Screenshots are not applied here: only a live window can
//! take one.

use std::path::Path;

use serde_json::{json, Map, Value};

use crate::state::Session;

pub const NO_WINDOW: &str = "No window. Start the editor with `macvoxel-egui --control PORT`, then `macvoxel-egui mcp --connect 127.0.0.1:PORT`. Add `--launch` to open the window.";

pub fn apply(session: &mut Session, method: &str, params: &Value) -> Result<Value, String> {
    let params = if params.is_null() {
        Value::Object(Map::new())
    } else {
        params.clone()
    };
    match method {
        "document.new" => {
            session.replace_empty();
            Ok(json!({"ok": true}))
        }
        "document.open" => {
            let path = req_str(&params, "path")?;
            session.open_vox(Path::new(&path))?;
            Ok(inspect(session))
        }
        "document.save" => {
            let path = match opt_str(&params, "path")? {
                Some(path) => path,
                None => session
                    .path
                    .as_ref()
                    .map(|p| p.display().to_string())
                    .ok_or_else(|| "document has no path; pass path".to_string())?,
            };
            session.write_vox(Path::new(&path))?;
            Ok(json!({"path": path, "voxels": session.voxel_count()}))
        }
        "document.inspect" => Ok(inspect(session)),
        "voxel.get" => {
            let (x, y, z) = xyz(&params)?;
            let palette = session.active().cells.get(&(x, y, z)).copied().unwrap_or(0);
            Ok(json!({"x": x, "y": y, "z": z, "palette": palette}))
        }
        "voxel.set" => {
            let (x, y, z) = xyz(&params)?;
            let palette = req_i32(&params, "palette")?;
            let changed = session.write_cells(&[(x, y, z, palette)])?;
            Ok(json!({"x": x, "y": y, "z": z, "palette": palette, "changed": changed}))
        }
        "voxel.set_many" => {
            let cells = params
                .get("cells")
                .and_then(Value::as_array)
                .ok_or("missing array cells")?;
            if cells.len() > 200_000 {
                return Err("too many cells (limit 200000)".into());
            }
            let mut writes = Vec::with_capacity(cells.len());
            for cell in cells {
                writes.push(read_cell(cell)?);
            }
            let changed = session.write_cells(&writes)?;
            Ok(json!({"changed": changed, "voxels": session.voxel_count()}))
        }
        "voxel.fill" => {
            let (x0, y0, z0, x1, y1, z1) = box_corners(&params)?;
            let palette = req_i32(&params, "palette")?;
            let nx = i64::from(x1 - x0) + 1;
            let ny = i64::from(y1 - y0) + 1;
            let nz = i64::from(z1 - z0) + 1;
            let count = nx * ny * nz;
            if count > 2_000_000 {
                return Err("box is larger than 2000000 cells".into());
            }
            let mut writes = Vec::with_capacity(count as usize);
            for z in z0..=z1 {
                for y in y0..=y1 {
                    for x in x0..=x1 {
                        writes.push((x, y, z, palette));
                    }
                }
            }
            let changed = session.write_cells(&writes)?;
            Ok(json!({"changed": changed, "voxels": session.voxel_count()}))
        }
        "voxel.get_box" => {
            let (x0, y0, z0, x1, y1, z1) = box_corners(&params)?;
            let mut cells = Vec::new();
            for (&(x, y, z), &palette) in &session.active().cells {
                if (x0..=x1).contains(&x) && (y0..=y1).contains(&y) && (z0..=z1).contains(&z) {
                    cells.push(json!({"x": x, "y": y, "z": z, "palette": palette}));
                }
            }
            if cells.len() > 100_000 {
                return Err("too many cells (limit 100000)".into());
            }
            cells.sort_by_key(|cell| {
                (
                    cell["x"].as_i64().unwrap_or(0),
                    cell["y"].as_i64().unwrap_or(0),
                    cell["z"].as_i64().unwrap_or(0),
                )
            });
            Ok(json!({"cells": cells}))
        }
        "palette.set" => {
            let slots = palette_slots(&params)?;
            let changed = session.write_palette(&slots);
            Ok(json!({"changed": changed}))
        }
        "object.set_active" => {
            let index = req_i32(&params, "index")?;
            if index < 0 || index as usize >= session.objects.len() {
                return Err(format!(
                    "object index {index} is out of range ({} objects)",
                    session.objects.len()
                ));
            }
            session.select_object(index as usize);
            Ok(json!({"activeObject": session.selected}))
        }
        "edit.undo" => {
            if !session.can_undo() {
                return Err("nothing to undo".into());
            }
            session.undo();
            Ok(json!({"canUndo": session.can_undo(), "canRedo": session.can_redo()}))
        }
        "edit.redo" => {
            if !session.can_redo() {
                return Err("nothing to redo".into());
            }
            session.redo();
            Ok(json!({"canUndo": session.can_undo(), "canRedo": session.can_redo()}))
        }
        "mesh.export" => {
            let path = req_str(&params, "path")?;
            let merge = opt_bool(&params, "merge")?.unwrap_or(false);
            let vertex_colors = opt_bool(&params, "vertexColors")?.unwrap_or(false);
            let quads = crate::export::export_with(
                session,
                Path::new(&path),
                &crate::export::MeshExport {
                    vertex_colors,
                    merge,
                },
            )?;
            Ok(json!({
                "path": path,
                "quads": quads,
                "merge": merge,
                "vertexColors": vertex_colors
            }))
        }
        "ui.screenshot" | "ui.inspect" | "ui.click" => Err(NO_WINDOW.into()),
        "control.methods" => Ok(Value::Array(
            METHODS
                .iter()
                .map(|(method, params, description)| {
                    json!({"method": method, "params": params, "description": description})
                })
                .collect(),
        )),
        "ping" => Ok(json!("pong")),
        other => Err(format!(
            "unknown method `{other}`; `control.methods` lists them"
        )),
    }
}

const METHODS: &[(&str, &str, &str)] = &[
    ("document.new", "", "Empty document, default palette"),
    ("document.open", "path", "Open a .vox, replacing the session"),
    ("document.save", "path?", "Write every non-empty object. path overwrites the open file when omitted"),
    ("document.inspect", "", "Path, counts, bounds, objects, palette"),
    ("voxel.get", "x, y, z", "Palette index of one local cell. 0 is empty"),
    ("voxel.set", "x, y, z, palette", "Write one cell. One undo step"),
    ("voxel.set_many", "cells", "Write up to 200000 cells as one undo step"),
    ("voxel.fill", "x0, y0, z0, x1, y1, z1, palette", "Fill an inclusive box, at most 2000000 cells"),
    ("voxel.get_box", "x0, y0, z0, x1, y1, z1", "Non-empty cells inside an inclusive box, at most 100000"),
    ("palette.set", "index, r, g, b, a? | entries", "Replace one slot, or many, as one undo step"),
    ("object.set_active", "index", "Edit a different object"),
    ("edit.undo", "", "Undo the last edit"),
    ("edit.redo", "", "Redo the last undone edit"),
    (
        "mesh.export",
        "path, merge?, vertexColors?",
        "Write a glTF 2.0 .glb of every object. merge defaults to false. vertexColors defaults to false (palette texture).",
    ),
    (
        "ui.screenshot",
        "region?, x?, y?, width?, height?, path?",
        "PNG of the window, the viewport, or a rectangle in window points. Requires the open editor.",
    ),
    (
        "ui.inspect",
        "",
        "Controls from the previous frame, plus tool, mode, and status. Requires the open editor.",
    ),
    (
        "ui.click",
        "x, y",
        "Click a registered control or stamp the viewport. Requires the open editor.",
    ),
    ("control.methods", "", "Methods this server answers"),
    ("ping", "", "Replies \"pong\""),
];

fn inspect(session: &Session) -> Value {
    let objects: Vec<Value> = session
        .objects
        .iter()
        .enumerate()
        .map(|(index, object)| {
            json!({
                "index": index,
                "name": object.name,
                "hidden": object.hidden,
                "active": index == session.selected,
                "model": index,
                "voxels": object.cells.len(),
                "bounds": bounds_json(object.cells.keys().copied()),
                "translation": [object.translation.0, object.translation.1, object.translation.2],
            })
        })
        .collect();
    let voxels: usize = session
        .objects
        .iter()
        .map(|object| object.cells.len())
        .sum();
    json!({
        "path": session.path.as_ref().map(|p| p.display().to_string()),
        "activeObject": session.selected,
        "objectCount": session.objects.len(),
        "voxels": voxels,
        "bounds": bounds_json(session.world_bounds().into_iter().flat_map(|(min, max)| [min, max])),
        "activeBounds": bounds_json(session.active().cells.keys().copied()),
        "unsynced": false,
        "canUndo": session.can_undo(),
        "canRedo": session.can_redo(),
        "objects": objects,
        "palette": (0..256).map(|i| hex_color(session.palette[i])).collect::<Vec<_>>(),
    })
}

fn bounds_json(cells: impl IntoIterator<Item = crate::state::Cell>) -> Value {
    let mut iter = cells.into_iter();
    let Some(first) = iter.next() else {
        return Value::Null;
    };
    let mut min = first;
    let mut max = first;
    for cell in iter {
        min.0 = min.0.min(cell.0);
        min.1 = min.1.min(cell.1);
        min.2 = min.2.min(cell.2);
        max.0 = max.0.max(cell.0);
        max.1 = max.1.max(cell.1);
        max.2 = max.2.max(cell.2);
    }
    json!({"min": [min.0, min.1, min.2], "max": [max.0, max.1, max.2]})
}

fn hex_color(rgba: [u8; 4]) -> String {
    format!(
        "#{:02x}{:02x}{:02x}{:02x}",
        rgba[0], rgba[1], rgba[2], rgba[3]
    )
}

fn xyz(params: &Value) -> Result<(i32, i32, i32), String> {
    Ok((
        req_i32(params, "x")?,
        req_i32(params, "y")?,
        req_i32(params, "z")?,
    ))
}

fn box_corners(params: &Value) -> Result<(i32, i32, i32, i32, i32, i32), String> {
    let x0 = req_i32(params, "x0")?;
    let y0 = req_i32(params, "y0")?;
    let z0 = req_i32(params, "z0")?;
    let x1 = req_i32(params, "x1")?;
    let y1 = req_i32(params, "y1")?;
    let z1 = req_i32(params, "z1")?;
    Ok((
        x0.min(x1),
        y0.min(y1),
        z0.min(z1),
        x0.max(x1),
        y0.max(y1),
        z0.max(z1),
    ))
}

fn read_cell(value: &Value) -> Result<(i32, i32, i32, i32), String> {
    if let Some(arr) = value.as_array() {
        if arr.len() != 4 {
            return Err("cell array must be [x, y, z, palette]".into());
        }
        return Ok((
            as_i32(&arr[0]).ok_or("cell x must be an integer")?,
            as_i32(&arr[1]).ok_or("cell y must be an integer")?,
            as_i32(&arr[2]).ok_or("cell z must be an integer")?,
            as_i32(&arr[3]).ok_or("cell palette must be an integer")?,
        ));
    }
    Ok((
        req_i32(value, "x")?,
        req_i32(value, "y")?,
        req_i32(value, "z")?,
        req_i32(value, "palette")?,
    ))
}

fn palette_slots(params: &Value) -> Result<Vec<(u8, [u8; 4])>, String> {
    let one = params.get("index").is_some();
    let many = params.get("entries").is_some();
    if one == many {
        return Err("pass index, r, g, b or entries, not both".into());
    }
    if one {
        return Ok(vec![one_slot(params)?]);
    }
    let entries = params
        .get("entries")
        .and_then(Value::as_array)
        .ok_or("entries must be an array")?;
    if entries.len() > 256 {
        return Err("too many palette entries (limit 256)".into());
    }
    let mut slots = Vec::with_capacity(entries.len());
    for entry in entries {
        slots.push(one_slot(entry)?);
    }
    Ok(slots)
}

fn one_slot(value: &Value) -> Result<(u8, [u8; 4]), String> {
    let index = req_i32(value, "index")?;
    if !(0..=255).contains(&index) {
        return Err("palette index must be 0..255".into());
    }
    let r = byte(value, "r")?;
    let g = byte(value, "g")?;
    let b = byte(value, "b")?;
    let a = match value.get("a") {
        None => 255,
        Some(_) => byte(value, "a")?,
    };
    Ok((index as u8, [r, g, b, a]))
}

fn byte(value: &Value, key: &str) -> Result<u8, String> {
    let n = req_i32(value, key)?;
    u8::try_from(n).map_err(|_| format!("{key} must be 0..255"))
}

pub fn req_str(value: &Value, key: &str) -> Result<String, String> {
    opt_str(value, key)?.ok_or_else(|| format!("missing string {key}"))
}

fn opt_bool(value: &Value, key: &str) -> Result<Option<bool>, String> {
    match value.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(flag)) => Ok(Some(*flag)),
        Some(_) => Err(format!("{key} must be a boolean")),
    }
}

pub fn opt_str(value: &Value, key: &str) -> Result<Option<String>, String> {
    match value.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.clone())),
        Some(_) => Err(format!("{key} must be a string")),
    }
}

pub fn req_i32(value: &Value, key: &str) -> Result<i32, String> {
    let found = value
        .get(key)
        .ok_or_else(|| format!("missing integer {key}"))?;
    as_i32(found).ok_or_else(|| format!("{key} must be an integer"))
}

fn as_i32(value: &Value) -> Option<i32> {
    let number = value.as_i64().or_else(|| {
        let f = value.as_f64()?;
        (f.fract() == 0.0).then_some(f as i64)
    })?;
    i32::try_from(number).ok()
}

/// Crop `pixels` (row-major RGBA, `width` wide) to an inclusive-exclusive
/// pixel rectangle and encode a PNG. `None` keeps the whole image.
pub fn png_region(
    pixels: &[[u8; 4]],
    width: usize,
    height: usize,
    region: Option<(i32, i32, i32, i32)>,
) -> Result<(Vec<u8>, u32, u32), String> {
    if pixels.len() != width.saturating_mul(height) || width == 0 || height == 0 {
        return Err("screenshot is empty".into());
    }
    let (x, y, w, h) = region.unwrap_or((0, 0, width as i32, height as i32));
    if w <= 0 || h <= 0 {
        return Err("screenshot region is empty".into());
    }
    if x < 0 || y < 0 || x as usize + w as usize > width || y as usize + h as usize > height {
        return Err(format!(
            "region {x},{y} {w}x{h} is outside the {width}x{height} window"
        ));
    }
    let mut rgba = Vec::with_capacity((w as usize) * (h as usize) * 4);
    for row in y..y + h {
        let start = (row as usize) * width + x as usize;
        for pixel in &pixels[start..start + w as usize] {
            rgba.extend_from_slice(pixel);
        }
    }
    let mut out = Vec::new();
    let mut encoder = png::Encoder::new(&mut out, w as u32, h as u32);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().map_err(|e| format!("png: {e}"))?;
    writer
        .write_image_data(&rgba)
        .map_err(|e| format!("png: {e}"))?;
    drop(writer);
    Ok((out, w as u32, h as u32))
}

pub fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    let mut i = 0;
    while i + 3 <= bytes.len() {
        let n =
            (u32::from(bytes[i]) << 16) | (u32::from(bytes[i + 1]) << 8) | u32::from(bytes[i + 2]);
        out.push(TABLE[((n >> 18) & 63) as usize] as char);
        out.push(TABLE[((n >> 12) & 63) as usize] as char);
        out.push(TABLE[((n >> 6) & 63) as usize] as char);
        out.push(TABLE[(n & 63) as usize] as char);
        i += 3;
    }
    if i < bytes.len() {
        let left = bytes.len() - i;
        let b0 = u32::from(bytes[i]);
        let b1 = if left == 2 {
            u32::from(bytes[i + 1])
        } else {
            0
        };
        let n = (b0 << 16) | (b1 << 8);
        out.push(TABLE[((n >> 18) & 63) as usize] as char);
        out.push(TABLE[((n >> 12) & 63) as usize] as char);
        if left == 2 {
            out.push(TABLE[((n >> 6) & 63) as usize] as char);
            out.push('=');
        } else {
            out.push('=');
            out.push('=');
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_voxel_undoes_and_a_region_png_crops() {
        let mut session = Session::new();
        session.replace_empty();
        apply(
            &mut session,
            "voxel.set",
            &json!({"x": 1, "y": 2, "z": 3, "palette": 4}),
        )
        .unwrap();
        let got = apply(&mut session, "voxel.get", &json!({"x": 1, "y": 2, "z": 3})).unwrap();
        assert_eq!(got["palette"], 4);
        apply(&mut session, "edit.undo", &json!({})).unwrap();
        let got = apply(&mut session, "voxel.get", &json!({"x": 1, "y": 2, "z": 3})).unwrap();
        assert_eq!(got["palette"], 0);
        let err = apply(&mut session, "ui.screenshot", &json!({})).unwrap_err();
        assert!(err.contains("--control"));

        let pixels = [
            [255, 0, 0, 255],
            [0, 255, 0, 255],
            [0, 0, 255, 255],
            [1, 2, 3, 4],
        ];
        let (png, w, h) = png_region(&pixels, 2, 2, Some((1, 0, 1, 2))).unwrap();
        assert_eq!((w, h), (1, 2));
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
    }

    #[test]
    fn export_mesh_writes_a_palette_texture() {
        let mut session = Session::new();
        session.replace_empty();
        apply(
            &mut session,
            "voxel.set",
            &json!({"x": 0, "y": 0, "z": 0, "palette": 4}),
        )
        .unwrap();
        apply(
            &mut session,
            "voxel.set",
            &json!({"x": 1, "y": 0, "z": 0, "palette": 4}),
        )
        .unwrap();
        let path = std::env::temp_dir().join("macvoxel-egui-mcp-export.glb");
        let got = apply(
            &mut session,
            "mesh.export",
            &json!({"path": path.display().to_string()}),
        )
        .unwrap();
        assert_eq!(got["quads"], 10);
        assert_eq!(got["merge"], false);
        assert_eq!(got["vertexColors"], false);
        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(&bytes[..4], b"glTF");
        let json_len = u32::from_le_bytes(bytes[12..16].try_into().unwrap()) as usize;
        let json = &bytes[20..20 + json_len];
        assert!(json.windows(10).any(|window| window == b"TEXCOORD_0"));
        let merged = apply(
            &mut session,
            "mesh.export",
            &json!({"path": path.display().to_string(), "merge": true}),
        )
        .unwrap();
        assert_eq!(merged["quads"], 6);
        let _ = std::fs::remove_file(path);
    }
}
