//! Document operations shared by the headless MCP session and the window's
//! control port. Screenshots are not applied here: only a live window can
//! take one.

use std::path::Path;

use serde_json::{json, Map, Value};

use crate::state::Session;

pub const NO_WINDOW: &str = "No window. Start the editor with `macvoxel-egui --control PORT`, then `macvoxel-egui mcp --connect 127.0.0.1:PORT`. Add `--launch` to open the window.";

fn render_scene(session: &mut Session, params: &Value) -> Result<Value, String> {
    let path = req_str(params, "path")?;
    if path.is_empty() {
        return Err("path is empty".into());
    }
    let width = opt_i32_range(params, "width", 256, 1, 1024)?;
    let height = opt_i32_range(params, "height", 256, 1, 1024)?;
    let samples = opt_i32_range(params, "samples", 16, 1, 128)?;
    let bounces = opt_i32_range(params, "bounces", 4, 0, 8)?;
    let seed = opt_i32_range(params, "seed", 1, 0, i32::MAX)?;
    let denoise = opt_bool(params, "denoise")?.unwrap_or(true);
    let yaw = opt_f64(params, "yaw")?;
    let pitch = opt_f64(params, "pitch")?;
    let distance = opt_f64(params, "distance")?;
    if let Some(pitch) = pitch {
        if !(-90.0..=90.0).contains(&pitch) {
            return Err("pitch is out of range".into());
        }
    }
    if let Some(distance) = distance {
        if !(distance > 0.0) || distance > 100.0 {
            return Err("distance is out of range".into());
        }
    }
    let voxels = session
        .objects
        .iter()
        .filter(|object| !object.hidden)
        .fold(0usize, |count, object| {
            count + object.cells.values().filter(|slot| **slot != 0).count()
        });
    if voxels == 0 {
        return Err("document has no voxels".into());
    }

    let saved_yaw = session.yaw;
    let saved_pitch = session.pitch;
    let saved_distance = session.distance;
    let saved_target = session.target;
    let saved_bounces = session.max_bounces;
    let saved_aces = session.aces;
    let saved_denoise = session.denoise;
    session.frame_camera();
    session.yaw = (yaw.unwrap_or(30.0) as f32).to_radians();
    session.pitch = (pitch.unwrap_or(25.0) as f32).to_radians();
    if let Some(scale) = distance {
        session.distance *= scale as f32;
    }
    session.max_bounces = bounces;
    session.aces = true;
    session.denoise = denoise;
    let image = crate::trace::render_still(
        session,
        width as u32,
        height as u32,
        samples as u32,
        seed as u32,
    );
    let written = crate::trace::write_png(Path::new(&path), &image, session);
    session.yaw = saved_yaw;
    session.pitch = saved_pitch;
    session.distance = saved_distance;
    session.target = saved_target;
    session.max_bounces = saved_bounces;
    session.aces = saved_aces;
    session.denoise = saved_denoise;
    written?;
    Ok(json!({
        "path": path,
        "width": width,
        "height": height,
        "samples": samples
    }))
}

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
            let voxels: usize = session
                .objects
                .iter()
                .map(|object| object.cells.values().filter(|slot| **slot != 0).count())
                .sum();
            let objects = session
                .objects
                .iter()
                .filter(|object| object.cells.values().any(|slot| *slot != 0))
                .count();
            Ok(json!({"path": path, "voxels": voxels, "objects": objects}))
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
        "object.add" => {
            let name = opt_str(&params, "name")?;
            let position = opt_ivec3(&params, "position")?.unwrap_or([0, 0, 0]);
            let size = opt_ivec3(&params, "size")?;
            let make_active = opt_bool(&params, "make_active")?.unwrap_or(true);
            let index = session.add_object(name.as_deref(), position, size, make_active)?;
            Ok(json!({
                "index": index,
                "name": session.objects[index].name,
                "position": position,
                "activeObject": session.selected,
            }))
        }
        "object.set" => {
            let index = object_index(&params, session)?;
            let name = opt_str(&params, "name")?;
            let position = opt_ivec3(&params, "position")?;
            let hidden = opt_bool(&params, "hidden")?;
            session.set_object(index, name.as_deref(), position, hidden)?;
            let object = &session.objects[index];
            Ok(json!({
                "index": index,
                "name": object.name,
                "position": [object.translation.0, object.translation.1, object.translation.2],
                "hidden": object.hidden,
            }))
        }
        "object.remove" => {
            let index = object_index(&params, session)?;
            let count = session.objects.len();
            session.remove_object(index)?;
            let shifted = index + 1 < count;
            let mut body = json!({
                "removed": index,
                "objectCount": session.objects.len(),
                "activeObject": session.selected,
                "indicesShifted": shifted,
            });
            if shifted {
                body["note"] = json!(format!("object indices after {index} decreased by 1"));
            }
            Ok(body)
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
        "rig.add" => {
            let name = req_str(&params, "name")?;
            let parent = opt_str(&params, "parent")?;
            let pivot = req_vec3(&params, "pivot")?;
            let rotation = opt_vec4(&params, "rotation")?;
            session.add_bone(&name, parent.as_deref(), pivot, rotation)?;
            Ok(json!({"name": name, "count": session.skeleton.bones.len()}))
        }
        "rig.set" => {
            let name = req_str(&params, "name")?;
            let parent = parent_update(&params)?;
            let pivot = opt_vec3(&params, "pivot")?;
            let rotation = opt_vec4(&params, "rotation")?;
            let rename = opt_str(&params, "rename")?;
            session.set_bone(&name, parent, pivot, rotation, rename.as_deref())?;
            let current = rename.unwrap_or(name);
            Ok(json!({"name": current}))
        }
        "rig.remove" => {
            let name = req_str(&params, "name")?;
            session.remove_bone(&name)?;
            Ok(json!({"removed": name}))
        }
        "rig.bind" => {
            let index = req_i32(&params, "index")?;
            if index < 0 {
                return Err(format!(
                    "object index {index} is out of range ({} objects)",
                    session.objects.len()
                ));
            }
            let bone = bind_name(&params)?;
            session.bind_object(index as usize, bone.as_deref())?;
            Ok(json!({"index": index, "bone": bone}))
        }
        "rig.list" => Ok(bones_json(session)),
        "render" => render_scene(session, &params),
        "script.set" => {
            let index = script_index(session, &params)?;
            let source = req_str(&params, "source")?;
            session.set_script(index, &source)?;
            Ok(script_json(session, index))
        }
        "script.get" => {
            let index = script_index(session, &params)?;
            Ok(script_json(session, index))
        }
        "script.params" => {
            let index = script_index(session, &params)?;
            let values = params
                .get("values")
                .and_then(Value::as_object)
                .ok_or("values must be an object")?;
            let mut updates = Vec::new();
            for (name, value) in values {
                let Some(spec) = session.objects[index]
                    .script
                    .params
                    .iter()
                    .find(|param| param.name == *name)
                else {
                    return Err(format!("unknown parameter `{name}`"));
                };
                let parsed = crate::script::parse_param(&spec.value, value)
                    .map_err(|err| format!("`{name}`: {err}"))?;
                updates.push((name.clone(), parsed));
            }
            session.set_script_params(index, &updates)?;
            Ok(serde_json::json!({
                "params": session.objects[index]
                    .script
                    .params
                    .iter()
                    .map(crate::script::param_json)
                    .collect::<Vec<_>>()
            }))
        }
        "script.params.list" => {
            let index = script_index(session, &params)?;
            Ok(serde_json::json!({
                "params": session.objects[index]
                    .script
                    .params
                    .iter()
                    .map(crate::script::param_json)
                    .collect::<Vec<_>>()
            }))
        }
        "script.regenerate" => {
            let index = script_index(session, &params)?;
            session.regenerate_script(index)?;
            Ok(serde_json::json!({
                "object": index,
                "voxels": session.objects[index].cells.len(),
                "objects": session.objects.len(),
            }))
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
    ("palette.set", "index, r, g, b, a?, motion?, motion_amount? | entries", "Replace one slot, or many, as one undo step"),
    ("object.set_active", "index", "Edit a different object. Voxel coordinates stay local to it"),
    ("object.add", "name?, position?, size?, make_active?", "Empty object at a world position. Active unless make_active is false"),
    ("object.set", "index, name?, position?, hidden?", "Rename, move, or hide. position is world voxels; local cells stay put"),
    ("object.remove", "index", "Remove an object and its voxels. Later indices shift. The last object stays"),
    ("edit.undo", "", "Undo the last edit"),
    ("edit.redo", "", "Redo the last undone edit"),
    (
        "render",
        "path, width?, height?, samples?, bounces?, seed?, denoise?, yaw?, pitch?, distance?",
        "Path-trace the scene to a PNG. width and height default to 256 (1..1024). samples defaults to 16 (1..128). bounces defaults to 4 (0..8). denoise defaults to true. yaw 30 and pitch 25 degrees frame the scene when omitted.",
    ),
    (
        "mesh.export",
        "path, merge?, vertexColors?",
        "Write a glTF 2.0 .glb of every object. merge defaults to false. vertexColors defaults to false (palette texture). A skeleton writes a rigid skin.",
    ),
    (
        "script.set",
        "source, object?",
        "Store a script on an object and read its parameters. One undo step. A script that fails to run is kept, and the voxels stay as they were. The error includes the script line.",
    ),
    (
        "script.get",
        "object?",
        "Script source, auto flag, and parameters. object defaults to the active object.",
    ),
    (
        "script.params",
        "values, object?",
        "Set parameter values by name. One undo step. Does not run the script.",
    ),
    (
        "script.params.list",
        "object?",
        "Parameters declared by the last successful run.",
    ),
    (
        "script.regenerate",
        "object?",
        "Run the script and replace the objects it writes. One undo step. A limit or runtime error leaves the document as it was and includes the script line.",
    ),
    ("rig.add", "name, pivot, parent?, rotation?", "Add a bone. rotation is [x, y, z, w]"),
    ("rig.set", "name, parent?, pivot?, rotation?, rename?", "Change a bone. parent null makes a root"),
    ("rig.remove", "name", "Delete a bone. Objects bound to it become unbound"),
    ("rig.bind", "index, bone", "Bind an object. bone null unbinds"),
    ("rig.list", "", "Bones with parent, pivot, rotation, and bound objects"),
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
                "position": [object.translation.0, object.translation.1, object.translation.2],
                "translation": [object.translation.0, object.translation.1, object.translation.2],
                "bone": object.bone,
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
        "bones": bone_rows(session),
        "palette": (0..256).map(|i| hex_color(session.palette[i])).collect::<Vec<_>>(),
        "motion": (0..256).map(|i| {
            let material = session.materials[i];
            json!({"kind": material.motion.as_str(), "amount": material.motion_amount})
        }).collect::<Vec<_>>(),
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

fn script_index(session: &Session, params: &Value) -> Result<usize, String> {
    match params.get("object") {
        None | Some(Value::Null) => Ok(session
            .selected
            .min(session.objects.len().saturating_sub(1))),
        Some(value) => {
            let index = value.as_i64().ok_or("object must be an integer")?;
            if index < 0 || index as usize >= session.objects.len() {
                return Err(format!(
                    "object index {index} is out of range ({} objects)",
                    session.objects.len()
                ));
            }
            Ok(index as usize)
        }
    }
}

fn script_json(session: &Session, index: usize) -> Value {
    let script = &session.objects[index].script;
    json!({
        "object": index,
        "source": script.source,
        "auto": script.auto,
        "params": script.params.iter().map(crate::script::param_json).collect::<Vec<_>>(),
    })
}

fn palette_slots(params: &Value) -> Result<Vec<crate::state::PaletteChange>, String> {
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

fn one_slot(value: &Value) -> Result<crate::state::PaletteChange, String> {
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
    let motion = match value.get("motion") {
        None => None,
        Some(found) => {
            let text = found.as_str().ok_or("motion must be none, sway, or bob")?;
            Some(crate::state::Motion::parse(text).ok_or("motion must be none, sway, or bob")?)
        }
    };
    let amount = match opt_f64(value, "motion_amount")? {
        None => None,
        Some(number) => {
            if !(0.0..=4.0).contains(&number) {
                return Err("motion_amount is out of range".into());
            }
            Some(number as f32)
        }
    };
    Ok(crate::state::PaletteChange {
        index: index as u8,
        rgba: [r, g, b, a],
        motion,
        amount,
    })
}

fn byte(value: &Value, key: &str) -> Result<u8, String> {
    let n = req_i32(value, key)?;
    u8::try_from(n).map_err(|_| format!("{key} must be 0..255"))
}

pub fn req_str(value: &Value, key: &str) -> Result<String, String> {
    opt_str(value, key)?.ok_or_else(|| format!("missing string {key}"))
}

fn opt_i32_range(value: &Value, key: &str, fallback: i32, lo: i32, hi: i32) -> Result<i32, String> {
    match value.get(key) {
        None => Ok(fallback),
        Some(found) => {
            let Some(number) = as_i32(found) else {
                return Err(format!("{key} is out of range"));
            };
            if number < lo || number > hi {
                return Err(format!("{key} is out of range"));
            }
            Ok(number)
        }
    }
}

fn opt_f64(value: &Value, key: &str) -> Result<Option<f64>, String> {
    match value.get(key) {
        None => Ok(None),
        Some(found) => {
            let Some(number) = found.as_f64() else {
                return Err(format!("{key} must be a number"));
            };
            if !number.is_finite() {
                return Err(format!("{key} must be a number"));
            }
            Ok(Some(number))
        }
    }
}

fn object_index(params: &Value, session: &Session) -> Result<usize, String> {
    let index = req_i32(params, "index")?;
    if index < 0 || index as usize >= session.objects.len() {
        return Err(format!(
            "object index {index} is out of range ({} objects)",
            session.objects.len()
        ));
    }
    Ok(index as usize)
}

fn opt_ivec3(value: &Value, key: &str) -> Result<Option<[i32; 3]>, String> {
    match value.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(found) => Ok(Some(ivec3(found, key)?)),
    }
}

fn ivec3(value: &Value, key: &str) -> Result<[i32; 3], String> {
    let items = value
        .as_array()
        .ok_or_else(|| format!("{key} must be [x, y, z]"))?;
    if items.len() != 3 {
        return Err(format!("{key} must be [x, y, z]"));
    }
    let mut out = [0; 3];
    for (axis, item) in items.iter().enumerate() {
        let number = if let Some(number) = item.as_i64() {
            number
        } else if let Some(number) = item.as_f64() {
            if !number.is_finite() || number.fract() != 0.0 {
                return Err(format!("{key} must be integer voxel coordinates"));
            }
            number as i64
        } else {
            return Err(format!("{key} must be integer voxel coordinates"));
        };
        out[axis] = i32::try_from(number).map_err(|_| format!("{key} is out of range"))?;
    }
    Ok(out)
}

fn opt_bool(value: &Value, key: &str) -> Result<Option<bool>, String> {
    match value.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(flag)) => Ok(Some(*flag)),
        Some(_) => Err(format!("{key} must be a boolean")),
    }
}

fn bones_json(session: &Session) -> Value {
    json!({"bones": bone_rows(session)})
}

fn bone_rows(session: &Session) -> Vec<Value> {
    session
        .skeleton
        .bones
        .iter()
        .map(|bone| {
            let objects: Vec<usize> = session
                .objects
                .iter()
                .enumerate()
                .filter(|(_, object)| object.bone.as_deref() == Some(bone.name.as_str()))
                .map(|(index, _)| index)
                .collect();
            json!({
                "name": bone.name,
                "parent": bone.parent,
                "pivot": bone.pivot,
                "rotation": bone.rotation,
                "objects": objects,
            })
        })
        .collect()
}

fn parent_update(value: &Value) -> Result<Option<Option<String>>, String> {
    match value.get("parent") {
        None => Ok(None),
        Some(Value::Null) => Ok(Some(None)),
        Some(Value::String(text)) => Ok(Some(Some(text.clone()))),
        Some(_) => Err("parent must be a bone name or null".into()),
    }
}

fn bind_name(value: &Value) -> Result<Option<String>, String> {
    match value.get("bone") {
        None => Err("missing bone".into()),
        Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.clone())),
        Some(_) => Err("bone must be a name or null".into()),
    }
}

fn req_vec3(value: &Value, key: &str) -> Result<[f32; 3], String> {
    let found = value.get(key).ok_or_else(|| format!("missing {key}"))?;
    as_vec(found, 3)
        .ok_or_else(|| format!("{key} must be [x, y, z]"))
        .map(|v| [v[0], v[1], v[2]])
}

fn opt_vec3(value: &Value, key: &str) -> Result<Option<[f32; 3]>, String> {
    match value.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(found) => as_vec(found, 3)
            .map(|v| Some([v[0], v[1], v[2]]))
            .ok_or_else(|| format!("{key} must be [x, y, z]")),
    }
}

fn opt_vec4(value: &Value, key: &str) -> Result<Option<[f32; 4]>, String> {
    match value.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(found) => as_vec(found, 4)
            .map(|v| Some([v[0], v[1], v[2], v[3]]))
            .ok_or_else(|| format!("{key} must be [x, y, z, w]")),
    }
}

fn as_vec(value: &Value, len: usize) -> Option<Vec<f32>> {
    let array = value.as_array()?;
    if array.len() != len {
        return None;
    }
    array
        .iter()
        .map(|item| {
            let number = item.as_f64()?;
            let number = number as f32;
            number.is_finite().then_some(number)
        })
        .collect()
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
#[path = "../tests/remote.rs"]
mod tests;
