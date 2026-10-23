//! glTF 2.0 binary (.glb) of exposed faces.
//!
//! One quad per exposed face of every object. Translations are baked into
//! the vertices. Positions are glTF Y-up `(x, z, -y)`. `COLOR_0` is the
//! palette color converted from sRGB to linear. Faces are not greedy-merged.

use std::path::Path;

use serde_json::json;

use crate::state::{Cell, Session};

const NORMALS: [[f32; 3]; 6] = [
    [1.0, 0.0, 0.0],
    [-1.0, 0.0, 0.0],
    [0.0, 1.0, 0.0],
    [0.0, -1.0, 0.0],
    [0.0, 0.0, 1.0],
    [0.0, 0.0, -1.0],
];

/// Outward-facing quads, CCW when looked at from outside. Same winding as
/// the viewport mesh.
const QUADS: [[[f32; 3]; 4]; 6] = [
    [
        [1.0, 0.0, 0.0],
        [1.0, 1.0, 0.0],
        [1.0, 1.0, 1.0],
        [1.0, 0.0, 1.0],
    ],
    [
        [0.0, 1.0, 0.0],
        [0.0, 0.0, 0.0],
        [0.0, 0.0, 1.0],
        [0.0, 1.0, 1.0],
    ],
    [
        [1.0, 1.0, 0.0],
        [0.0, 1.0, 0.0],
        [0.0, 1.0, 1.0],
        [1.0, 1.0, 1.0],
    ],
    [
        [0.0, 0.0, 0.0],
        [1.0, 0.0, 0.0],
        [1.0, 0.0, 1.0],
        [0.0, 0.0, 1.0],
    ],
    [
        [0.0, 0.0, 1.0],
        [1.0, 0.0, 1.0],
        [1.0, 1.0, 1.0],
        [0.0, 1.0, 1.0],
    ],
    [
        [0.0, 1.0, 0.0],
        [1.0, 1.0, 0.0],
        [1.0, 0.0, 0.0],
        [0.0, 0.0, 0.0],
    ],
];

const OFFSETS: [Cell; 6] = [
    (1, 0, 0),
    (-1, 0, 0),
    (0, 1, 0),
    (0, -1, 0),
    (0, 0, 1),
    (0, 0, -1),
];

struct Built {
    positions: Vec<f32>,
    normals: Vec<f32>,
    colors: Vec<f32>,
    indices: Vec<u32>,
    min: [f32; 3],
    max: [f32; 3],
}

/// glTF Y-up positions of every exposed corner. Used by the export test.
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) fn scene_positions(session: &Session) -> Vec<[f32; 3]> {
    let built = build(session);
    let mut out = Vec::with_capacity(built.positions.len() / 3);
    for chunk in built.positions.chunks(3) {
        out.push([chunk[0], chunk[1], chunk[2]]);
    }
    out
}

fn encode(session: &Session) -> Result<Vec<u8>, String> {
    let built = build(session);
    let quads = (built.indices.len() / 6) as u32;
    if quads == 0 {
        return Err("Nothing to export.".into());
    }
    let verts = (built.positions.len() / 3) as u32;
    let pos_bytes = built.positions.len() * 4;
    let nrm_bytes = built.normals.len() * 4;
    let col_bytes = built.colors.len() * 4;
    let idx_bytes = built.indices.len() * 4;
    let mut bin = Vec::with_capacity(pos_bytes + nrm_bytes + col_bytes + idx_bytes);
    push_f32s(&mut bin, &built.positions);
    push_f32s(&mut bin, &built.normals);
    push_f32s(&mut bin, &built.colors);
    for index in &built.indices {
        bin.extend_from_slice(&index.to_le_bytes());
    }
    pad(&mut bin, 0);

    let nrm_off = pos_bytes;
    let col_off = nrm_off + nrm_bytes;
    let idx_off = col_off + col_bytes;
    let json = json!({
        "asset": {"version": "2.0", "generator": "MacVoxel"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0}],
        "materials": [{
            "pbrMetallicRoughness": {
                "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
                "metallicFactor": 0.0,
                "roughnessFactor": 1.0
            }
        }],
        "meshes": [{
            "primitives": [{
                "attributes": {"POSITION": 0, "NORMAL": 1, "COLOR_0": 2},
                "indices": 3,
                "material": 0,
                "mode": 4
            }]
        }],
        "accessors": [
            {
                "bufferView": 0,
                "componentType": 5126,
                "count": verts,
                "type": "VEC3",
                "min": built.min,
                "max": built.max
            },
            {"bufferView": 1, "componentType": 5126, "count": verts, "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": verts, "type": "VEC4"},
            {
                "bufferView": 3,
                "componentType": 5125,
                "count": built.indices.len(),
                "type": "SCALAR"
            }
        ],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": pos_bytes, "target": 34962},
            {"buffer": 0, "byteOffset": nrm_off, "byteLength": nrm_bytes, "target": 34962},
            {"buffer": 0, "byteOffset": col_off, "byteLength": col_bytes, "target": 34962},
            {"buffer": 0, "byteOffset": idx_off, "byteLength": idx_bytes, "target": 34963}
        ],
        "buffers": [{"byteLength": bin.len()}]
    });
    let mut json_bytes = serde_json::to_vec(&json).map_err(|err| err.to_string())?;
    pad(&mut json_bytes, b' ');

    let total = 12 + 8 + json_bytes.len() + 8 + bin.len();
    let mut out = Vec::with_capacity(total);
    out.extend_from_slice(b"glTF");
    out.extend_from_slice(&2u32.to_le_bytes());
    out.extend_from_slice(&(total as u32).to_le_bytes());
    out.extend_from_slice(&(json_bytes.len() as u32).to_le_bytes());
    out.extend_from_slice(b"JSON");
    out.extend_from_slice(&json_bytes);
    out.extend_from_slice(&(bin.len() as u32).to_le_bytes());
    out.extend_from_slice(b"BIN\0");
    out.extend_from_slice(&bin);
    Ok(out)
}

fn build(session: &Session) -> Built {
    let mut built = Built {
        positions: Vec::new(),
        normals: Vec::new(),
        colors: Vec::new(),
        indices: Vec::new(),
        min: [f32::MAX; 3],
        max: [f32::MIN; 3],
    };
    for object in &session.objects {
        for (cell, slot) in &object.cells {
            let rgba = session.palette[*slot as usize];
            let color = [
                linear(rgba[0]),
                linear(rgba[1]),
                linear(rgba[2]),
                rgba[3] as f32 / 255.0,
            ];
            let origin = [
                (cell.0 + object.translation.0) as f32,
                (cell.1 + object.translation.1) as f32,
                (cell.2 + object.translation.2) as f32,
            ];
            for face in 0..6 {
                let offset = OFFSETS[face];
                let neighbor = (cell.0 + offset.0, cell.1 + offset.1, cell.2 + offset.2);
                if object.cells.contains_key(&neighbor) {
                    continue;
                }
                let base = (built.positions.len() / 3) as u32;
                let normal = y_up(NORMALS[face]);
                for corner in QUADS[face] {
                    let point = y_up([
                        origin[0] + corner[0],
                        origin[1] + corner[1],
                        origin[2] + corner[2],
                    ]);
                    for axis in 0..3 {
                        built.min[axis] = built.min[axis].min(point[axis]);
                        built.max[axis] = built.max[axis].max(point[axis]);
                        built.positions.push(point[axis]);
                        built.normals.push(normal[axis]);
                    }
                    built.colors.extend_from_slice(&color);
                }
                built.indices.extend_from_slice(&[
                    base,
                    base + 1,
                    base + 2,
                    base,
                    base + 2,
                    base + 3,
                ]);
            }
        }
    }
    if built.positions.is_empty() {
        built.min = [0.0; 3];
        built.max = [0.0; 3];
    }
    built
}

fn y_up(p: [f32; 3]) -> [f32; 3] {
    [p[0], p[2], -p[1]]
}

fn linear(channel: u8) -> f32 {
    let s = channel as f32 / 255.0;
    if s <= 0.04045 {
        s / 12.92
    } else {
        ((s + 0.055) / 1.055).powf(2.4)
    }
}

fn push_f32s(out: &mut Vec<u8>, values: &[f32]) {
    for value in values {
        out.extend_from_slice(&value.to_le_bytes());
    }
}

fn pad(buf: &mut Vec<u8>, fill: u8) {
    while buf.len() % 4 != 0 {
        buf.push(fill);
    }
}

/// Write a `.glb` and return the quad count. An empty scene is an error
/// and does not create the file. One quad per exposed face, vertex colors.
pub fn export_glb(session: &Session, path: &Path) -> Result<u32, String> {
    let built = build(session);
    let quads = (built.indices.len() / 6) as u32;
    if quads == 0 {
        return Err("Nothing to export.".into());
    }
    let bytes = encode(session)?;
    std::fs::write(path, &bytes)
        .map_err(|err| format!("Could not write {}: {err}", path.display()))?;
    Ok(quads)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::Session;

    #[test]
    fn translated_voxel_shifts_the_vertex_and_the_glb_starts_with_magic() {
        let mut session = Session::new();
        session.objects[0].cells.clear();
        session.objects[0].cells.insert((0, 0, 0), 1);
        session.objects[0].translation = (2, 0, 0);
        let positions = scene_positions(&session);
        assert!(positions.iter().all(|p| p[0] == 2.0 || p[0] == 3.0));
        assert!(positions.iter().any(|p| p[0] == 2.0));
        let path = std::env::temp_dir().join("macvoxel-egui-export.glb");
        let quads = export_glb(&session, &path).unwrap();
        assert_eq!(quads, 6);
        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(&bytes[..4], b"glTF");
        let json_len = u32::from_le_bytes(bytes[12..16].try_into().unwrap()) as usize;
        let json = &bytes[20..20 + json_len];
        assert!(json.windows(7).any(|window| window == b"COLOR_0"));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn empty_scene_is_refused() {
        let mut session = Session::new();
        session.objects[0].cells.clear();
        let err = export_glb(&session, Path::new("/tmp/macvoxel-egui-empty.glb")).unwrap_err();
        assert!(err.contains("Nothing"));
    }
}
