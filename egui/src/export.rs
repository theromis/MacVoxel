//! glTF 2.0 binary (.glb) of exposed faces.
//!
//! Coplanar faces of one palette slot become one rectangle. Translations
//! are baked into the vertices. Positions are glTF Y-up `(x, z, -y)`.
//! `COLOR_0` is the palette color converted from sRGB to linear.

use std::collections::BTreeMap;
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
        let shift = [
            object.translation.0 as f32,
            object.translation.1 as f32,
            object.translation.2 as f32,
        ];
        for quad in merged_quads(&object.cells) {
            let rgba = session.palette[quad.slot as usize];
            let color = [
                linear(rgba[0]),
                linear(rgba[1]),
                linear(rgba[2]),
                rgba[3] as f32 / 255.0,
            ];
            let base = (built.positions.len() / 3) as u32;
            let normal = y_up(NORMALS[quad.face]);
            for corner in quad_corners(quad.face, quad.cell, quad.w, quad.h) {
                let point = y_up([
                    corner[0] as f32 + shift[0],
                    corner[1] as f32 + shift[1],
                    corner[2] as f32 + shift[2],
                ]);
                for axis in 0..3 {
                    built.min[axis] = built.min[axis].min(point[axis]);
                    built.max[axis] = built.max[axis].max(point[axis]);
                    built.positions.push(point[axis]);
                    built.normals.push(normal[axis]);
                }
                built.colors.extend_from_slice(&color);
            }
            built
                .indices
                .extend_from_slice(&[base, base + 1, base + 2, base, base + 2, base + 3]);
        }
    }
    if built.positions.is_empty() {
        built.min = [0.0; 3];
        built.max = [0.0; 3];
    }
    built
}

struct GreedyQuad {
    face: usize,
    cell: Cell,
    w: i32,
    h: i32,
    slot: u8,
}

/// Plane axis, then the two in-plane axes. Width grows along `u`.
fn face_axes(face: usize) -> (usize, usize, usize) {
    match face {
        0 | 1 => (0, 1, 2),
        2 | 3 => (1, 0, 2),
        _ => (2, 0, 1),
    }
}

fn axis_of(cell: Cell, axis: usize) -> i32 {
    [cell.0, cell.1, cell.2][axis]
}

fn cell_on(face: usize, plane: i32, u: i32, v: i32) -> Cell {
    let (plane_axis, u_axis, v_axis) = face_axes(face);
    let mut coords = [0; 3];
    coords[plane_axis] = plane;
    coords[u_axis] = u;
    coords[v_axis] = v;
    (coords[0], coords[1], coords[2])
}

/// Exposed faces, greedy-merged. Scan order is `(v, u)`, so an L splits
/// the same way every time. `w` and `h` are in voxels.
fn merged_quads(cells: &std::collections::HashMap<Cell, u8>) -> Vec<GreedyQuad> {
    let mut slices: BTreeMap<(u8, i32), BTreeMap<(i32, i32), u8>> = BTreeMap::new();
    for (cell, slot) in cells {
        if *slot == 0 {
            continue;
        }
        for face in 0..6 {
            let offset = OFFSETS[face];
            let neighbor = (cell.0 + offset.0, cell.1 + offset.1, cell.2 + offset.2);
            if cells.contains_key(&neighbor) {
                continue;
            }
            let (plane_axis, u_axis, v_axis) = face_axes(face);
            slices
                .entry((face as u8, axis_of(*cell, plane_axis)))
                .or_default()
                .insert((axis_of(*cell, v_axis), axis_of(*cell, u_axis)), *slot);
        }
    }
    let mut merged = Vec::new();
    for ((face, plane), mask) in &mut slices {
        let keys: Vec<(i32, i32)> = mask.keys().copied().collect();
        for (v, u) in keys {
            let Some(slot) = mask.get(&(v, u)).copied() else {
                continue;
            };
            let mut w = 1;
            while mask.get(&(v, u + w)).copied() == Some(slot) {
                w += 1;
            }
            let mut h = 1;
            loop {
                let row = (0..w).all(|i| mask.get(&(v + h, u + i)).copied() == Some(slot));
                if !row {
                    break;
                }
                h += 1;
            }
            for j in 0..h {
                for i in 0..w {
                    mask.remove(&(v + j, u + i));
                }
            }
            merged.push(GreedyQuad {
                face: *face as usize,
                cell: cell_on(*face as usize, *plane, u, v),
                w,
                h,
                slot,
            });
        }
    }
    merged
}

/// Corners of a `w` by `h` rectangle, CCW from outside. A unit face is
/// [`QUADS`]; a longer side replaces that `1` with the rectangle size.
fn quad_corners(face: usize, cell: Cell, w: i32, h: i32) -> [[i32; 3]; 4] {
    let (_, u_axis, v_axis) = face_axes(face);
    let mut corners = [[0; 3]; 4];
    for (i, unit) in QUADS[face].iter().enumerate() {
        let mut point = [unit[0] as i32, unit[1] as i32, unit[2] as i32];
        if point[u_axis] == 1 {
            point[u_axis] = w;
        }
        if point[v_axis] == 1 {
            point[v_axis] = h;
        }
        corners[i] = [cell.0 + point[0], cell.1 + point[1], cell.2 + point[2]];
    }
    corners
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
/// and does not create the file. Coplanar faces of one color are one quad.
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
        let built = build(&session);
        let positions: Vec<[f32; 3]> = built
            .positions
            .chunks(3)
            .map(|chunk| [chunk[0], chunk[1], chunk[2]])
            .collect();
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
    fn unit_rectangle_matches_the_face_winding() {
        for face in 0..6 {
            let corners = quad_corners(face, (3, 4, 5), 1, 1);
            for (i, corner) in corners.iter().enumerate() {
                assert_eq!(corner[0], 3 + QUADS[face][i][0] as i32);
                assert_eq!(corner[1], 4 + QUADS[face][i][1] as i32);
                assert_eq!(corner[2], 5 + QUADS[face][i][2] as i32);
            }
        }
    }

    #[test]
    fn greedy_merges_a_row_of_one_color() {
        let mut session = Session::new();
        session.objects[0].cells.clear();
        session.objects[0].cells.insert((0, 0, 0), 1);
        session.objects[0].cells.insert((1, 0, 0), 1);
        assert_eq!(build(&session).indices.len() / 6, 6);
    }

    #[test]
    fn different_colors_stay_split() {
        let mut session = Session::new();
        session.objects[0].cells.clear();
        session.objects[0].cells.insert((0, 0, 0), 1);
        session.objects[0].cells.insert((1, 0, 0), 2);
        assert_eq!(build(&session).indices.len() / 6, 10);
    }

    #[test]
    fn empty_scene_is_refused() {
        let mut session = Session::new();
        session.objects[0].cells.clear();
        let err = export_glb(&session, Path::new("/tmp/macvoxel-egui-empty.glb")).unwrap_err();
        assert!(err.contains("Nothing"));
    }
}
