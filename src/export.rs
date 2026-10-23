//! glTF 2.0 binary (.glb) of exposed faces.
//!
//! Coplanar faces of one palette slot become one rectangle when merging is
//! on. Translations are baked into the vertices. Positions are glTF Y-up
//! `(x, z, -y)`. The default material is a 256-wide palette texture;
//! `vertex_colors` stores a linear `COLOR_0` instead.

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

/// How [`export_with`] writes palette colors.
pub struct MeshExport {
    /// `COLOR_0` on each vertex. Otherwise a palette texture and `TEXCOORD_0`.
    pub vertex_colors: bool,
    /// Greedy-merge coplanar faces that share a palette slot.
    pub merge: bool,
}

struct Built {
    positions: Vec<f32>,
    normals: Vec<f32>,
    /// Vertex colors (`VEC4`) or texture coordinates (`VEC2`).
    extra: Vec<f32>,
    indices: Vec<u32>,
    min: [f32; 3],
    max: [f32; 3],
    blend: bool,
}

fn encode(session: &Session, options: &MeshExport) -> Result<Vec<u8>, String> {
    let built = build_with(session, options);
    let quads = (built.indices.len() / 6) as u32;
    if quads == 0 {
        return Err("Nothing to export.".into());
    }
    let verts = (built.positions.len() / 3) as u32;
    let pos_bytes = built.positions.len() * 4;
    let nrm_bytes = built.normals.len() * 4;
    let extra_bytes = built.extra.len() * 4;
    let idx_bytes = built.indices.len() * 4;
    let png = if options.vertex_colors {
        Vec::new()
    } else {
        palette_png(&session.palette)?
    };
    let mut bin = Vec::with_capacity(pos_bytes + nrm_bytes + extra_bytes + idx_bytes + png.len());
    push_f32s(&mut bin, &built.positions);
    push_f32s(&mut bin, &built.normals);
    push_f32s(&mut bin, &built.extra);
    for index in &built.indices {
        bin.extend_from_slice(&index.to_le_bytes());
    }
    let image_off = bin.len();
    bin.extend_from_slice(&png);
    pad(&mut bin, 0);

    let nrm_off = pos_bytes;
    let extra_off = nrm_off + nrm_bytes;
    let idx_off = extra_off + extra_bytes;
    let color_name = if options.vertex_colors {
        "COLOR_0"
    } else {
        "TEXCOORD_0"
    };
    let extra_type = if options.vertex_colors {
        "VEC4"
    } else {
        "VEC2"
    };
    let alpha = if built.blend { "BLEND" } else { "OPAQUE" };
    let material_name = if options.vertex_colors {
        "voxel-vertex-color"
    } else {
        "voxel-palette"
    };
    let mut material = json!({
        "name": material_name,
        "pbrMetallicRoughness": {
            "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
            "metallicFactor": 0.0,
            "roughnessFactor": 1.0
        },
        "alphaMode": alpha
    });
    if !options.vertex_colors {
        material["pbrMetallicRoughness"]["baseColorTexture"] = json!({"index": 0});
    }
    let mut attributes = serde_json::Map::new();
    attributes.insert("POSITION".into(), json!(0));
    attributes.insert("NORMAL".into(), json!(1));
    attributes.insert(color_name.into(), json!(2));
    let mut root = json!({
        "asset": {"version": "2.0", "generator": "MacVoxel"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "voxels", "mesh": 0}],
        "materials": [material],
        "meshes": [{
            "name": "voxels",
            "primitives": [{
                "attributes": attributes,
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
            {"bufferView": 2, "componentType": 5126, "count": verts, "type": extra_type},
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
            {"buffer": 0, "byteOffset": extra_off, "byteLength": extra_bytes, "target": 34962},
            {"buffer": 0, "byteOffset": idx_off, "byteLength": idx_bytes, "target": 34963}
        ],
        "buffers": [{"byteLength": bin.len()}]
    });
    if !options.vertex_colors {
        root["textures"] = json!([{"sampler": 0, "source": 0}]);
        root["samplers"] = json!([{
            "magFilter": 9728,
            "minFilter": 9728,
            "wrapS": 33071,
            "wrapT": 33071
        }]);
        root["images"] = json!([{"bufferView": 4, "mimeType": "image/png"}]);
        root["bufferViews"]
            .as_array_mut()
            .expect("buffer views")
            .push(json!({
                "buffer": 0,
                "byteOffset": image_off,
                "byteLength": png.len()
            }));
    }
    let json = root;
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

#[cfg(test)]
fn build(session: &Session) -> Built {
    build_with(
        session,
        &MeshExport {
            vertex_colors: false,
            merge: true,
        },
    )
}

fn build_with(session: &Session, options: &MeshExport) -> Built {
    let mut built = Built {
        positions: Vec::new(),
        normals: Vec::new(),
        extra: Vec::new(),
        indices: Vec::new(),
        min: [f32::MAX; 3],
        max: [f32::MIN; 3],
        blend: false,
    };
    let mut quads = Vec::new();
    for object in &session.objects {
        if object.hidden {
            continue;
        }
        for mut quad in merged_quads(&object.cells, options.merge) {
            quad.cell = (
                quad.cell.0 + object.translation.0,
                quad.cell.1 + object.translation.1,
                quad.cell.2 + object.translation.2,
            );
            quads.push(quad);
        }
    }
    if options.merge {
        quads = split_junctions(quads);
    }
    for quad in quads {
        let rgba = session.palette[quad.slot as usize];
        if rgba[3] != 255 {
            built.blend = true;
        }
        let color = [
            linear(rgba[0]),
            linear(rgba[1]),
            linear(rgba[2]),
            rgba[3] as f32 / 255.0,
        ];
        let uv = [(quad.slot as f32 + 0.5) / 256.0, 0.5];
        let base = (built.positions.len() / 3) as u32;
        let normal = y_up(NORMALS[quad.face]);
        for corner in quad_corners(quad.face, quad.cell, quad.w, quad.h) {
            let point = y_up([corner[0] as f32, corner[1] as f32, corner[2] as f32]);
            for axis in 0..3 {
                built.min[axis] = built.min[axis].min(point[axis]);
                built.max[axis] = built.max[axis].max(point[axis]);
                built.positions.push(point[axis]);
                built.normals.push(normal[axis]);
            }
            if options.vertex_colors {
                built.extra.extend_from_slice(&color);
            } else {
                built.extra.extend_from_slice(&uv);
            }
        }
        built
            .indices
            .extend_from_slice(&[base, base + 1, base + 2, base, base + 2, base + 3]);
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

/// Exposed faces. `merge` grows coplanar runs of one palette slot. Scan
/// order is `(v, u)`, so an L splits the same way every time. `w` and `h`
/// are in voxels.
fn merged_quads(cells: &std::collections::HashMap<Cell, u8>, merge: bool) -> Vec<GreedyQuad> {
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
            let mut h = 1;
            if merge {
                while mask.get(&(v, u + w)).copied() == Some(slot) {
                    w += 1;
                }
                loop {
                    let row = (0..w).all(|i| mask.get(&(v + h, u + i)).copied() == Some(slot));
                    if !row {
                        break;
                    }
                    h += 1;
                }
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

/// Geometric corner at the minimum `u` and `v` of a quad. Positive faces
/// sit on the far side of the cell, so that coordinate is one past `cell`.
fn split_origin(quad: &GreedyQuad) -> [i32; 3] {
    let (normal, _, _) = face_axes(quad.face);
    let mut origin = [quad.cell.0, quad.cell.1, quad.cell.2];
    if quad.face % 2 == 0 {
        origin[normal] += 1;
    }
    origin
}

/// Cut a quad where a corner of another face lands in an open edge.
///
/// A neighbour on the same oriented plane and the same palette slot is
/// left alone: greedy merge already made those one surface. A different
/// plane or a different slot still cuts, or the seam cracks. Each cut adds
/// vertices on the shared edge, so this repeats until a pass adds nothing.
fn split_junctions(quads: Vec<GreedyQuad>) -> Vec<GreedyQuad> {
    let limit = (quads.len() * 4).max(8);
    let mut quads = quads;
    for _ in 0..limit {
        let mut on_plane: BTreeMap<(usize, i32), Vec<([i32; 3], usize, u8)>> = BTreeMap::new();
        for quad in &quads {
            for corner in quad_corners(quad.face, quad.cell, quad.w, quad.h) {
                for axis in 0..3 {
                    on_plane
                        .entry((axis, corner[axis]))
                        .or_default()
                        .push((corner, quad.face, quad.slot));
                }
            }
        }
        let mut next = Vec::with_capacity(quads.len());
        let mut grew = false;
        for quad in &quads {
            let (normal, u_axis, v_axis) = face_axes(quad.face);
            let origin = split_origin(quad);
            let mut u_splits = vec![0, quad.w];
            let mut v_splits = vec![0, quad.h];
            if let Some(hits) = on_plane.get(&(normal, origin[normal])) {
                for (at, face, slot) in hits {
                    if *face == quad.face && *slot == quad.slot {
                        continue;
                    }
                    let u = at[u_axis] - origin[u_axis];
                    let v = at[v_axis] - origin[v_axis];
                    if u < 0 || u > quad.w || v < 0 || v > quad.h {
                        continue;
                    }
                    if (v == 0 || v == quad.h) && u > 0 && u < quad.w {
                        u_splits.push(u);
                    }
                    if (u == 0 || u == quad.w) && v > 0 && v < quad.h {
                        v_splits.push(v);
                    }
                }
            }
            u_splits.sort_unstable();
            u_splits.dedup();
            v_splits.sort_unstable();
            v_splits.dedup();
            if u_splits.len() > 2 || v_splits.len() > 2 {
                grew = true;
            }
            for pair_v in v_splits.windows(2) {
                for pair_u in u_splits.windows(2) {
                    let (u0, du) = (pair_u[0], pair_u[1] - pair_u[0]);
                    let (v0, dv) = (pair_v[0], pair_v[1] - pair_v[0]);
                    if du <= 0 || dv <= 0 {
                        continue;
                    }
                    let mut cell = origin;
                    cell[u_axis] += u0;
                    cell[v_axis] += v0;
                    if quad.face % 2 == 0 {
                        cell[normal] -= 1;
                    }
                    next.push(GreedyQuad {
                        face: quad.face,
                        cell: (cell[0], cell[1], cell[2]),
                        w: du,
                        h: dv,
                        slot: quad.slot,
                    });
                }
            }
        }
        quads = next;
        if !grew {
            break;
        }
    }
    quads
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

/// Palette texture, greedy-merged. The menu export uses this.
pub fn export_glb(session: &Session, path: &Path) -> Result<u32, String> {
    export_with(
        session,
        path,
        &MeshExport {
            vertex_colors: false,
            merge: true,
        },
    )
}

/// Write a `.glb` and return the quad count. An empty scene is an error
/// and does not create the file.
pub fn export_with(session: &Session, path: &Path, options: &MeshExport) -> Result<u32, String> {
    let built = build_with(session, options);
    let quads = (built.indices.len() / 6) as u32;
    if quads == 0 {
        return Err("Nothing to export.".into());
    }
    let bytes = encode(session, options)?;
    std::fs::write(path, &bytes)
        .map_err(|err| format!("Could not write {}: {err}", path.display()))?;
    Ok(quads)
}

/// 256×1 sRGB PNG. glTF samples `baseColorTexture` as sRGB, so the swatch
/// bytes are stored unchanged.
fn palette_png(palette: &[[u8; 4]; 256]) -> Result<Vec<u8>, String> {
    let mut pixels = Vec::with_capacity(256 * 4);
    for color in palette {
        pixels.extend_from_slice(color);
    }
    let mut buf = Vec::new();
    let mut encoder = png::Encoder::new(&mut buf, 256, 1);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_source_srgb(png::SrgbRenderingIntent::Perceptual);
    let mut writer = encoder
        .write_header()
        .map_err(|err| format!("palette image: {err}"))?;
    writer
        .write_image_data(&pixels)
        .map_err(|err| format!("palette image: {err}"))?;
    writer
        .finish()
        .map_err(|err| format!("palette image: {err}"))?;
    Ok(buf)
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
        assert!(json.windows(10).any(|window| window == b"TEXCOORD_0"));
        assert!(bytes
            .windows(8)
            .any(|window| window == [137, 80, 78, 71, 13, 10, 26, 10]));
        let u = (1.0_f32 + 0.5) / 256.0;
        assert!(built.extra.chunks(2).all(|uv| uv[0] == u && uv[1] == 0.5));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn vertex_colors_keep_a_linear_color_attribute() {
        let mut session = Session::new();
        session.objects[0].cells.clear();
        session.objects[0].cells.insert((0, 0, 0), 1);
        let path = std::env::temp_dir().join("macvoxel-egui-export-vertex.glb");
        export_with(
            &session,
            &path,
            &MeshExport {
                vertex_colors: true,
                merge: false,
            },
        )
        .unwrap();
        let bytes = std::fs::read(&path).unwrap();
        let json_len = u32::from_le_bytes(bytes[12..16].try_into().unwrap()) as usize;
        let json = &bytes[20..20 + json_len];
        assert!(json.windows(7).any(|window| window == b"COLOR_0"));
        assert!(!json.windows(10).any(|window| window == b"TEXCOORD_0"));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn unmerged_row_keeps_one_quad_per_face() {
        let mut session = Session::new();
        session.objects[0].cells.clear();
        session.objects[0].cells.insert((0, 0, 0), 1);
        session.objects[0].cells.insert((1, 0, 0), 1);
        let built = build_with(
            &session,
            &MeshExport {
                vertex_colors: false,
                merge: false,
            },
        );
        assert_eq!(built.indices.len() / 6, 10);
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
    fn a_different_slot_splits_the_long_edge() {
        let mut session = Session::new();
        session.objects[0].cells.clear();
        session.objects[0].cells.insert((0, 0, 0), 1);
        session.objects[0].cells.insert((1, 0, 0), 1);
        session.objects[0].cells.insert((2, 0, 0), 1);
        session.objects[0].cells.insert((2, 1, 0), 2);
        let merged = merged_quads(&session.objects[0].cells, true);
        let area = |quads: &[GreedyQuad]| {
            quads
                .iter()
                .filter(|quad| quad.face == 4 && quad.slot == 1)
                .map(|quad| quad.w * quad.h)
                .sum::<i32>()
        };
        assert!(merged
            .iter()
            .any(|quad| quad.face == 4 && quad.slot == 1 && quad.w == 3));
        assert_eq!(area(&merged), 3);
        let before = merged.len();
        let split = split_junctions(merged);
        assert!(split
            .iter()
            .filter(|quad| quad.face == 4 && quad.slot == 1)
            .all(|quad| quad.w < 3));
        assert_eq!(area(&split), 3);
        assert!(split.len() > before);
    }

    #[test]
    fn hidden_object_is_left_out_of_the_mesh() {
        let mut session = Session::new();
        session.objects[0].cells.clear();
        session.objects[0].cells.insert((0, 0, 0), 1);
        session.objects.push(crate::state::Volume {
            name: "Hidden".into(),
            cells: session.objects[0].cells.clone(),
            translation: (3, 0, 0),
            box_min: (0, 0, 0),
            dims: (0, 0, 0),
            rot: [[1, 0, 0], [0, 1, 0], [0, 0, 1]],
            pivot: (0, 0, 0),
            model_dims: (0, 0, 0),
            hidden: true,
            file: None,
        });
        assert_eq!(build(&session).indices.len() / 6, 6);
    }

    #[test]
    fn empty_scene_is_refused() {
        let mut session = Session::new();
        session.objects[0].cells.clear();
        let err = export_glb(&session, Path::new("/tmp/macvoxel-egui-empty.glb")).unwrap_err();
        assert!(err.contains("Nothing"));
    }
}
