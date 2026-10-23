//! Exposed-face meshes, split into 16³ chunks.
//!
//! A chunk is rebuilt only when its own cells change or a neighbor's
//! occupancy changes (a shared face appears or disappears). Camera motion
//! does not touch this data.

use std::collections::{HashMap, HashSet};

use crate::state::Cell;

pub const CHUNK: i32 = 16;

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct Vert {
    pub pos: [f32; 3],
    pub normal: [f32; 3],
    pub color: [f32; 3],
}

const _: () = assert!(std::mem::size_of::<Vert>() == 36);

#[derive(Clone, Default)]
pub struct Mesh {
    pub verts: Vec<Vert>,
    pub indices: Vec<u32>,
}

impl Mesh {
    #[cfg(test)]
    fn face_count(&self) -> usize {
        self.indices.len() / 6
    }

    pub fn is_empty(&self) -> bool {
        self.indices.is_empty()
    }
}

pub fn chunk_key(cell: Cell) -> (i32, i32, i32) {
    (
        cell.0.div_euclid(CHUNK),
        cell.1.div_euclid(CHUNK),
        cell.2.div_euclid(CHUNK),
    )
}

/// Order-independent fingerprint of one chunk, including the sRGB color
/// baked into each vertex. A palette edit changes the hash of every chunk
/// that uses the edited slot.
pub fn occupancy_hash(cells: &[(Cell, [u8; 3])]) -> u64 {
    let mut sum = cells.len() as u64;
    let mut xor = 0u64;
    for (cell, rgb) in cells {
        let h = mix(cell.0, cell.1, cell.2, *rgb);
        sum = sum.wrapping_add(h);
        xor ^= h;
    }
    sum ^ xor.rotate_left(1)
}

fn mix(x: i32, y: i32, z: i32, rgb: [u8; 3]) -> u64 {
    let mut h = (x as u64).wrapping_mul(0x9E37_79B1_85EB_CA87)
        ^ (y as u64).wrapping_mul(0xC2B2_AE3D_27D4_EB4F)
        ^ (z as u64).wrapping_mul(0x1656_67B1_9E37_79F9)
        ^ ((rgb[0] as u64) << 16)
        ^ ((rgb[1] as u64) << 8)
        ^ (rgb[2] as u64);
    h ^= h >> 33;
    h = h.wrapping_mul(0xff51_afd7_ed55_8ccd);
    h ^= h >> 33;
    h
}

/// Faces of `chunk` that are not covered by a neighbor in `cells`.
pub fn mesh_chunk(
    cells: &HashMap<Cell, u8>,
    chunk: (i32, i32, i32),
    color: impl Fn(u8) -> [u8; 3],
) -> Mesh {
    let mut listed = Vec::new();
    for (&cell, &slot) in cells {
        if chunk_key(cell) == chunk {
            listed.push((cell, color(slot)));
        }
    }
    let mut mesh = Mesh::default();
    for (cell, rgb) in &listed {
        for face in 0..6 {
            let (dx, dy, dz) = OFFSETS[face];
            let neighbor = (cell.0 + dx, cell.1 + dy, cell.2 + dz);
            if cells.contains_key(&neighbor) {
                continue;
            }
            push_quad(&mut mesh, *cell, face, *rgb, 0.0);
        }
    }
    mesh
}

/// Boundary of a selection: faces that touch air or an unselected cell.
pub fn selection_shell(cells: &HashMap<Cell, u8>, picked: &HashSet<Cell>) -> Mesh {
    let mut mesh = Mesh::default();
    for cell in picked {
        if !cells.contains_key(cell) {
            continue;
        }
        for face in 0..6 {
            let (dx, dy, dz) = OFFSETS[face];
            let neighbor = (cell.0 + dx, cell.1 + dy, cell.2 + dz);
            if picked.contains(&neighbor) {
                continue;
            }
            push_quad(&mut mesh, *cell, face, [255, 214, 90], 0.03);
        }
    }
    mesh
}

pub fn highlight(cell: Cell, normal: Cell) -> Option<Mesh> {
    let face = OFFSETS.iter().position(|o| *o == normal)?;
    let mut mesh = Mesh::default();
    push_quad(&mut mesh, cell, face, [255, 214, 90], 0.04);
    Some(mesh)
}

pub fn ground_grid(min: Cell, max: Cell) -> Mesh {
    let mut mesh = Mesh::default();
    // Sit just under the bottom faces so the grid does not z-fight them.
    let z = min.2 as f32 - 0.02;
    let x0 = min.0 as f32 - 2.0;
    let x1 = max.0 as f32 + 3.0;
    let y0 = min.1 as f32 - 2.0;
    let y1 = max.1 as f32 + 3.0;
    let color = [46, 50, 58];
    let steps = 12;
    let dx = (x1 - x0) / steps as f32;
    let dy = (y1 - y0) / steps as f32;
    for i in 0..=steps {
        let x = x0 + dx * i as f32;
        push_ribbon(&mut mesh, [x, y0, z], [x, y1, z], true, color);
        let y = y0 + dy * i as f32;
        push_ribbon(&mut mesh, [x0, y, z], [x1, y, z], false, color);
    }
    mesh
}

const OFFSETS: [(i32, i32, i32); 6] = [
    (1, 0, 0),
    (-1, 0, 0),
    (0, 1, 0),
    (0, -1, 0),
    (0, 0, 1),
    (0, 0, -1),
];

const NORMALS: [[f32; 3]; 6] = [
    [1.0, 0.0, 0.0],
    [-1.0, 0.0, 0.0],
    [0.0, 1.0, 0.0],
    [0.0, -1.0, 0.0],
    [0.0, 0.0, 1.0],
    [0.0, 0.0, -1.0],
];

/// Outward-facing quads, CCW when looked at from outside.
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

fn push_quad(mesh: &mut Mesh, cell: Cell, face: usize, rgb: [u8; 3], push: f32) {
    let base = mesh.verts.len() as u32;
    let color = [
        rgb[0] as f32 / 255.0,
        rgb[1] as f32 / 255.0,
        rgb[2] as f32 / 255.0,
    ];
    let normal = NORMALS[face];
    let origin = [cell.0 as f32, cell.1 as f32, cell.2 as f32];
    for corner in QUADS[face] {
        mesh.verts.push(Vert {
            pos: [
                origin[0] + corner[0] + normal[0] * push,
                origin[1] + corner[1] + normal[1] * push,
                origin[2] + corner[2] + normal[2] * push,
            ],
            normal,
            color,
        });
    }
    mesh.indices
        .extend([base, base + 1, base + 2, base, base + 2, base + 3]);
}

fn push_ribbon(mesh: &mut Mesh, a: [f32; 3], b: [f32; 3], along_y: bool, rgb: [u8; 3]) {
    let w = 0.025;
    let p = if along_y {
        [
            [a[0] - w, a[1], a[2]],
            [a[0] + w, a[1], a[2]],
            [b[0] + w, b[1], b[2]],
            [b[0] - w, b[1], b[2]],
        ]
    } else {
        [
            [a[0], a[1] - w, a[2]],
            [a[0], a[1] + w, a[2]],
            [b[0], b[1] + w, b[2]],
            [b[0], b[1] - w, b[2]],
        ]
    };
    let base = mesh.verts.len() as u32;
    let color = [
        rgb[0] as f32 / 255.0,
        rgb[1] as f32 / 255.0,
        rgb[2] as f32 / 255.0,
    ];
    for corner in p {
        mesh.verts.push(Vert {
            pos: corner,
            normal: [0.0, 0.0, 1.0],
            color,
        });
    }
    mesh.indices
        .extend([base, base + 1, base + 2, base, base + 2, base + 3]);
}

/// Chunks whose occupancy changed, plus their six neighbors so a face that
/// used to be exposed on the other side of the boundary is rebuilt too.
pub fn dirty_chunks(
    previous: &HashMap<(i32, i32, i32), u64>,
    next: &HashMap<(i32, i32, i32), u64>,
) -> Vec<(i32, i32, i32)> {
    let mut dirty = std::collections::HashSet::new();
    for (key, hash) in next {
        if previous.get(key) != Some(hash) {
            mark(&mut dirty, *key);
        }
    }
    for key in previous.keys() {
        if !next.contains_key(key) {
            mark(&mut dirty, *key);
        }
    }
    dirty.into_iter().collect()
}

fn mark(dirty: &mut std::collections::HashSet<(i32, i32, i32)>, key: (i32, i32, i32)) {
    dirty.insert(key);
    for (dx, dy, dz) in OFFSETS {
        dirty.insert((key.0 + dx, key.1 + dy, key.2 + dz));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn white(_: u8) -> [u8; 3] {
        [255, 255, 255]
    }

    #[test]
    fn selection_shell_drops_the_face_between_two_picked_cells() {
        let mut cells = HashMap::new();
        cells.insert((0, 0, 0), 1);
        cells.insert((1, 0, 0), 1);
        let mut picked = HashSet::new();
        picked.insert((0, 0, 0));
        picked.insert((1, 0, 0));
        assert_eq!(selection_shell(&cells, &picked).face_count(), 10);
    }

    #[test]
    fn one_voxel_has_six_faces() {
        let mut cells = HashMap::new();
        cells.insert((0, 0, 0), 1);
        let mesh = mesh_chunk(&cells, (0, 0, 0), white);
        assert_eq!(mesh.face_count(), 6);
    }

    #[test]
    fn neighbors_drop_the_shared_face_across_a_chunk_boundary() {
        let mut cells = HashMap::new();
        cells.insert((15, 0, 0), 1);
        cells.insert((16, 0, 0), 1);
        let a = mesh_chunk(&cells, chunk_key((15, 0, 0)), white);
        let b = mesh_chunk(&cells, chunk_key((16, 0, 0)), white);
        assert_eq!(a.face_count() + b.face_count(), 10);
    }

    #[test]
    fn negative_coordinates_stay_in_their_own_chunk() {
        assert_eq!(chunk_key((-1, 0, 0)), (-1, 0, 0));
        assert_eq!(chunk_key((-16, -17, 3)), (-1, -2, 0));
    }

    #[test]
    fn a_changed_chunk_dirties_its_neighbors() {
        let mut prev = HashMap::new();
        prev.insert((0, 0, 0), 1);
        let mut next = HashMap::new();
        next.insert((0, 0, 0), 2);
        let dirty = dirty_chunks(&prev, &next);
        assert!(dirty.contains(&(0, 0, 0)));
        assert!(dirty.contains(&(1, 0, 0)));
        assert!(dirty.contains(&(-1, 0, 0)));
        assert_eq!(dirty.len(), 7);
    }

    #[test]
    fn hash_ignores_insertion_order() {
        let a = occupancy_hash(&[((1, 2, 3), [9, 8, 7]), ((4, 5, 6), [1, 2, 3])]);
        let b = occupancy_hash(&[((4, 5, 6), [1, 2, 3]), ((1, 2, 3), [9, 8, 7])]);
        assert_eq!(a, b);
        let c = occupancy_hash(&[((1, 2, 3), [9, 8, 8]), ((4, 5, 6), [1, 2, 3])]);
        assert_ne!(a, c);
    }
}
