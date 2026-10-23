//! CPU ports of the shape, face, generator, and foliage operations.
//!
//! The Swift app runs these as Metal kernels. Here each one enumerates
//! cells so the egui session can stamp them onto the same `HashMap` the
//! brush already edits.

use std::collections::{HashMap, HashSet, VecDeque};

use crate::state::{Axis, Cell, GeneratorKind};

pub fn bresenham(a: Cell, b: Cell) -> Vec<Cell> {
    let (mut x, mut y, mut z) = a;
    let dx = (b.0 - a.0).abs();
    let dy = (b.1 - a.1).abs();
    let dz = (b.2 - a.2).abs();
    let sx = if a.0 < b.0 { 1 } else { -1 };
    let sy = if a.1 < b.1 { 1 } else { -1 };
    let sz = if a.2 < b.2 { 1 } else { -1 };
    let dm = dx.max(dy).max(dz);
    let mut ex = dm / 2;
    let mut ey = dm / 2;
    let mut ez = dm / 2;
    let mut out = Vec::with_capacity(dm as usize + 1);
    out.push((x, y, z));
    for _ in 0..dm {
        ex -= dx;
        if ex < 0 {
            ex += dm;
            x += sx;
        }
        ey -= dy;
        if ey < 0 {
            ey += dm;
            y += sy;
        }
        ez -= dz;
        if ez < 0 {
            ez += dm;
            z += sz;
        }
        out.push((x, y, z));
    }
    out
}

pub fn circle(anchor: Cell, end: Cell, axis: i32, fill: bool, even: bool) -> Vec<Cell> {
    disc(anchor, end, axis, fill, even, true)
}

pub fn square(anchor: Cell, end: Cell, axis: i32, fill: bool, even: bool) -> Vec<Cell> {
    disc(anchor, end, axis, fill, even, false)
}

fn disc(anchor: Cell, end: Cell, axis: i32, fill: bool, even: bool, round: bool) -> Vec<Cell> {
    let (au, av) = project(axis, anchor);
    let (eu, ev) = project(axis, end);
    let du = eu - au;
    let dv = ev - av;
    let c = if even { 0.5 } else { 0.0 };
    let (radius, bound) = if round {
        let fdu = du as f32 - c;
        let fdv = dv as f32 - c;
        let radius2 = fdu * fdu + fdv * fdv;
        (radius2.sqrt(), radius2.sqrt().ceil() as i32 + 1)
    } else {
        let half = (du as f32 - c).abs().max((dv as f32 - c).abs());
        (half, half.ceil() as i32 + 1)
    };
    let radius2 = if round {
        let fdu = du as f32 - c;
        let fdv = dv as f32 - c;
        fdu * fdu + fdv * fdv
    } else {
        0.0
    };
    let half = if round { 0.0 } else { radius };
    let inside = |i: i32, j: i32| {
        let fi = i as f32 - c;
        let fj = j as f32 - c;
        if round {
            fi * fi + fj * fj <= radius2
        } else {
            fi.abs().max(fj.abs()) <= half
        }
    };
    let bound = bound.clamp(0, 256);
    let mut out = Vec::new();
    for j in -bound..=bound {
        for i in -bound..=bound {
            if !inside(i, j) {
                continue;
            }
            if !fill && inside(i + 1, j) && inside(i - 1, j) && inside(i, j + 1) && inside(i, j - 1)
            {
                continue;
            }
            out.push(offset(axis, anchor, i, j));
        }
    }
    out
}

pub fn cube(a: Cell, b: Cell, fill: bool) -> Vec<Cell> {
    let x0 = a.0.min(b.0);
    let x1 = a.0.max(b.0);
    let y0 = a.1.min(b.1);
    let y1 = a.1.max(b.1);
    let z0 = a.2.min(b.2);
    let z1 = a.2.max(b.2);
    let nx = x1 - x0 + 1;
    let ny = y1 - y0 + 1;
    let nz = z1 - z0 + 1;
    let thin = nx == 1 || ny == 1 || nz == 1;
    let mut out = Vec::new();
    for z in z0..=z1 {
        for y in y0..=y1 {
            for x in x0..=x1 {
                let shell = x == x0 || x == x1 || y == y0 || y == y1 || z == z0 || z == z1;
                if fill || thin || shell {
                    out.push((x, y, z));
                }
            }
        }
    }
    out
}

/// Exposed face connected to `seed`. `match_color == 0` accepts any
/// occupied cell. The walk stays inside the volume's in-plane bounds.
pub fn flood_face(
    cells: &HashMap<Cell, u8>,
    seed: Cell,
    axis: i32,
    sign: i32,
    match_color: u8,
    eight: bool,
) -> Vec<Cell> {
    let Some(&seed_slot) = cells.get(&seed) else {
        return Vec::new();
    };
    if match_color != 0 && seed_slot != match_color {
        return Vec::new();
    }
    let normal = axis_delta(axis, sign);
    if cells.contains_key(&add(seed, normal)) {
        return Vec::new();
    }
    let (u_axis, v_axis) = plane_axes(axis);
    let mut u_min = i32::MAX;
    let mut u_max = i32::MIN;
    let mut v_min = i32::MAX;
    let mut v_max = i32::MIN;
    for cell in cells.keys() {
        let u = coord(*cell, u_axis);
        let v = coord(*cell, v_axis);
        u_min = u_min.min(u);
        u_max = u_max.max(u);
        v_min = v_min.min(v);
        v_max = v_max.max(v);
    }
    let qualifies = |cell: Cell| {
        let Some(&slot) = cells.get(&cell) else {
            return false;
        };
        if match_color != 0 && slot != match_color {
            return false;
        }
        !cells.contains_key(&add(cell, normal))
    };
    let mut seen = HashSet::new();
    let mut queue = VecDeque::new();
    let mut out = Vec::new();
    queue.push_back(seed);
    seen.insert(seed);
    while let Some(cell) = queue.pop_front() {
        if !qualifies(cell) {
            continue;
        }
        out.push(cell);
        if out.len() >= 100_000 {
            break;
        }
        for (du, dv) in neighbors(eight) {
            let next = set_plane(cell, axis, u_axis, v_axis, du, dv);
            let u = coord(next, u_axis);
            let v = coord(next, v_axis);
            if u < u_min || u > u_max || v < v_min || v > v_max {
                continue;
            }
            if seen.insert(next) {
                queue.push_back(next);
            }
        }
    }
    out
}

/// Empty cells on the wall plane through `seed`, inside the inclusive
/// in-plane bounds. The seed must be empty. Stops at occupied cells.
pub fn flood_empty(
    cells: &HashMap<Cell, u8>,
    seed: Cell,
    axis: i32,
    u_min: i32,
    u_max: i32,
    v_min: i32,
    v_max: i32,
    eight: bool,
) -> Vec<Cell> {
    if cells.contains_key(&seed) {
        return Vec::new();
    }
    let (u_axis, v_axis) = plane_axes(axis);
    let u = coord(seed, u_axis);
    let v = coord(seed, v_axis);
    if u < u_min || u > u_max || v < v_min || v > v_max {
        return Vec::new();
    }
    let mut seen = HashSet::new();
    let mut queue = VecDeque::new();
    let mut out = Vec::new();
    queue.push_back(seed);
    seen.insert(seed);
    while let Some(cell) = queue.pop_front() {
        if cells.contains_key(&cell) {
            continue;
        }
        out.push(cell);
        if out.len() >= 100_000 {
            break;
        }
        for (du, dv) in neighbors(eight) {
            let next = set_plane(cell, axis, u_axis, v_axis, du, dv);
            let u = coord(next, u_axis);
            let v = coord(next, v_axis);
            if u < u_min || u > u_max || v < v_min || v > v_max {
                continue;
            }
            if seen.insert(next) {
                queue.push_back(next);
            }
        }
    }
    out
}

pub fn extrude(seeds: &[Cell], axis: i32, sign: i32, steps: i32, outward: bool) -> Vec<Cell> {
    if steps == 0 || seeds.is_empty() {
        return Vec::new();
    }
    let n = steps.unsigned_abs() as i32;
    let dir = if outward { sign } else { -sign };
    let mut out = Vec::with_capacity(seeds.len() * n as usize);
    let start = if outward { 1 } else { 0 };
    for k in start..start + n {
        let delta = axis_delta(axis, dir * k);
        for seed in seeds {
            out.push(add(*seed, delta));
        }
    }
    out
}

pub struct Gen {
    pub kind: GeneratorKind,
    pub axis: Axis,
    pub apex_at_max: bool,
    pub palette: u8,
    pub torus_tube: f32,
    pub helix_turns: f32,
    pub helix_radius: f32,
    pub helix_tube: f32,
    pub helix_cw: bool,
    pub noise_scale: f32,
    pub noise_threshold: f32,
    pub noise_octaves: i32,
    pub noise_seed: u32,
    pub perlin_lo: i32,
    pub perlin_hi: i32,
    pub tree_depth: i32,
    pub tree_wildness: f32,
    pub tree_trunk: f32,
    pub tree_leaf: i32,
    pub tree_seed: u32,
    pub conifer_tiers: i32,
    pub conifer_ragged: f32,
    pub conifer_clump: f32,
    pub conifer_trunk: f32,
    pub conifer_crown: f32,
    pub conifer_needle: i32,
    pub conifer_seed: u32,
}

impl Default for Gen {
    fn default() -> Self {
        Self {
            kind: GeneratorKind::Ellipsoid,
            axis: Axis::Y,
            apex_at_max: true,
            palette: 1,
            torus_tube: 0.3,
            helix_turns: 2.0,
            helix_radius: 0.75,
            helix_tube: 0.16,
            helix_cw: false,
            noise_scale: 8.0,
            noise_threshold: 0.5,
            noise_octaves: 4,
            noise_seed: 1,
            perlin_lo: 1,
            perlin_hi: 8,
            tree_depth: 3,
            tree_wildness: 0.35,
            tree_trunk: 0.45,
            tree_leaf: 1,
            tree_seed: 1,
            conifer_tiers: 3,
            conifer_ragged: 0.25,
            conifer_clump: 6.0,
            conifer_trunk: 0.4,
            conifer_crown: 0.5,
            conifer_needle: 1,
            conifer_seed: 1,
        }
    }
}

/// Largest generator box filled in one drag. Matches `fill_box`.
pub const MAX_GENERATOR_CELLS: i64 = 2_000_000;

/// Cells a generator would write inside the inclusive box. Empty when the
/// box is larger than [`MAX_GENERATOR_CELLS`].
pub fn generate(min: Cell, max: Cell, gen: &Gen) -> Vec<(Cell, u8)> {
    let nx = max.0 - min.0 + 1;
    let ny = max.1 - min.1 + 1;
    let nz = max.2 - min.2 + 1;
    if nx <= 0 || ny <= 0 || nz <= 0 {
        return Vec::new();
    }
    if nx as i64 * ny as i64 * nz as i64 > MAX_GENERATOR_CELLS {
        return Vec::new();
    }
    let mut out = Vec::new();
    for z in min.2..=max.2 {
        for y in min.1..=max.1 {
            for x in min.0..=max.0 {
                if let Some(slot) = gen_cell((x, y, z), min, max, gen) {
                    out.push(((x, y, z), slot));
                }
            }
        }
    }
    out
}

pub fn foliage(
    cells: &HashMap<Cell, u8>,
    center: Cell,
    offsets: &[Cell],
    seed_color: u8,
    density: f32,
    stroke_id: u32,
) -> Vec<Cell> {
    let mut out = Vec::new();
    for delta in offsets {
        let cell = add(center, *delta);
        if cells.contains_key(&cell) {
            continue;
        }
        let touches = NEIGHBORS_6
            .iter()
            .any(|n| cells.get(&add(cell, *n)) == Some(&seed_color));
        if !touches {
            continue;
        }
        if hash3(cell, stroke_id) < density {
            out.push(cell);
        }
    }
    out
}

fn gen_cell(cell: Cell, min: Cell, max: Cell, gen: &Gen) -> Option<u8> {
    let dims = [
        (max.0 - min.0 + 1) as f32,
        (max.1 - min.1 + 1) as f32,
        (max.2 - min.2 + 1) as f32,
    ];
    let lo = [min.0 as f32, min.1 as f32, min.2 as f32];
    let pos = [
        cell.0 as f32 + 0.5,
        cell.1 as f32 + 0.5,
        cell.2 as f32 + 0.5,
    ];
    let axis = match gen.axis {
        Axis::X => 0usize,
        Axis::Y => 1,
        Axis::Z => 2,
    };
    match gen.kind {
        GeneratorKind::Ellipsoid => {
            let center = [
                (2.0 * lo[0] + dims[0]) * 0.5,
                (2.0 * lo[1] + dims[1]) * 0.5,
                (2.0 * lo[2] + dims[2]) * 0.5,
            ];
            let mut dot = 0.0;
            for i in 0..3 {
                let n = (pos[i] - center[i]) / (dims[i] * 0.5);
                dot += n * n;
            }
            (dot <= 1.0).then_some(gen.palette)
        }
        GeneratorKind::Cylinder => {
            let (u, v) = plane_axes(axis as i32);
            let nu = norm_axis(pos, lo, dims, u);
            let nv = norm_axis(pos, lo, dims, v);
            (nu * nu + nv * nv <= 1.0).then_some(gen.palette)
        }
        GeneratorKind::Cone | GeneratorKind::Pyramid => {
            let (u, v) = plane_axes(axis as i32);
            let t = (pos[axis] - lo[axis]) / dims[axis];
            let r = if gen.apex_at_max { 1.0 - t } else { t };
            if r <= 0.0 {
                return None;
            }
            let nu = norm_axis(pos, lo, dims, u);
            let nv = norm_axis(pos, lo, dims, v);
            let inside = if gen.kind == GeneratorKind::Cone {
                nu * nu + nv * nv <= r * r
            } else {
                nu.abs().max(nv.abs()) <= r
            };
            inside.then_some(gen.palette)
        }
        GeneratorKind::Torus => {
            let tube = gen.torus_tube.clamp(0.0, 1.0);
            if tube <= 0.001 {
                return None;
            }
            let (u, v) = plane_axes(axis as i32);
            let na = (pos[axis] - (lo[axis] + dims[axis] * 0.5)) / (dims[axis] * 0.5);
            let nu = norm_axis(pos, lo, dims, u);
            let nv = norm_axis(pos, lo, dims, v);
            let radial = (nu * nu + nv * nv).sqrt();
            let dr = radial - (1.0 - tube);
            let er = dr / tube;
            (er * er + na * na <= 1.0).then_some(gen.palette)
        }
        GeneratorKind::Helix => helix_cell(pos, lo, dims, axis, gen),
        GeneratorKind::Perlin => perlin_cell(cell, gen),
        GeneratorKind::Tree => tree_cell(pos, lo, dims, axis, gen),
        GeneratorKind::Conifer => conifer_cell(pos, lo, dims, axis, gen),
    }
}

fn helix_cell(pos: [f32; 3], lo: [f32; 3], dims: [f32; 3], axis: usize, gen: &Gen) -> Option<u8> {
    let (u, v) = plane_axes(axis as i32);
    let radial_half = dims[u].min(dims[v]) * 0.5;
    let tube = (gen.helix_tube.clamp(0.02, 0.9) * radial_half).max(0.45);
    let radius = (radial_half - tube).max(0.0) * gen.helix_radius.clamp(0.0, 1.0);
    let axial_lo = lo[axis] + tube;
    let axial_span = (dims[axis] - 2.0 * tube).max(0.0);
    let center_u = lo[u] + dims[u] * 0.5;
    let center_v = lo[v] + dims[v] * 0.5;
    let turns = gen.helix_turns.max(0.05);
    let winding = if gen.helix_cw { -1.0 } else { 1.0 };
    let omega = winding * std::f32::consts::TAU * turns;
    let mut s = if axial_span > 1e-5 {
        ((pos[axis] - axial_lo) / axial_span).clamp(0.0, 1.0)
    } else {
        0.5
    };
    for _ in 0..5 {
        let theta = omega * s;
        let (st, ct) = theta.sin_cos();
        let q = [center_u, center_v, axial_lo + axial_span * s];
        let dq = [-radius * st * omega, radius * ct * omega, axial_span];
        let ddq = [
            -radius * ct * omega * omega,
            -radius * st * omega * omega,
            0.0,
        ];
        let p = [pos[u], pos[v], pos[axis]];
        let delta = [q[0] - p[0], q[1] - p[1], q[2] - p[2]];
        let first = delta[0] * dq[0] + delta[1] * dq[1] + delta[2] * dq[2];
        let second = dq[0] * dq[0]
            + dq[1] * dq[1]
            + dq[2] * dq[2]
            + delta[0] * ddq[0]
            + delta[1] * ddq[1]
            + delta[2] * ddq[2];
        if second.abs() < 1e-5 {
            break;
        }
        s = (s - first / second).clamp(0.0, 1.0);
    }
    let theta = omega * s;
    let (st, ct) = theta.sin_cos();
    let du = pos[u] - (center_u + radius * ct);
    let dv = pos[v] - (center_v + radius * st);
    let da = pos[axis] - (axial_lo + axial_span * s);
    (du * du + dv * dv + da * da <= tube * tube).then_some(gen.palette)
}

fn perlin_cell(cell: Cell, gen: &Gen) -> Option<u8> {
    let scale = gen.noise_scale.max(0.001);
    let octaves = gen.noise_octaves.clamp(1, 8) as u32;
    let mut p = [
        (cell.0 as f32 + 0.5) / scale,
        (cell.1 as f32 + 0.5) / scale,
        (cell.2 as f32 + 0.5) / scale,
    ];
    let mut total = 0.0;
    let mut amp = 1.0;
    let mut total_amp = 0.0;
    for octave in 0..octaves {
        total += amp * perlin3(p, gen.noise_seed.wrapping_add(octave * 1013));
        total_amp += amp;
        amp *= 0.5;
        p = [p[0] * 2.0, p[1] * 2.0, p[2] * 2.0];
    }
    let n = ((total / total_amp) * 0.5 + 0.5).clamp(0.0, 1.0);
    if n < gen.noise_threshold {
        return None;
    }
    let span = 1.0 - gen.noise_threshold;
    let t = if span > 1e-6 {
        (n - gen.noise_threshold) / span
    } else {
        0.0
    };
    let slot = gen.perlin_lo as f32 + (gen.perlin_hi as f32 - gen.perlin_lo as f32) * t;
    Some(slot.round().clamp(0.0, 255.0) as u8)
}

fn tree_cell(pos: [f32; 3], lo: [f32; 3], dims: [f32; 3], axis: usize, gen: &Gen) -> Option<u8> {
    const LENGTH_FALLOFF: f32 = 0.72;
    const MAX_HEIGHT: f32 = 1.0 / (1.0 - LENGTH_FALLOFF);
    let (u, v) = plane_axes(axis as i32);
    let fit = (dims[axis] / (MAX_HEIGHT * 1.05)).max(0.0001);
    let mut up = (pos[axis] - lo[axis]) / fit;
    if !gen.apex_at_max {
        up = dims[axis] / fit - up;
    }
    let side_a = (pos[u] - (lo[u] + dims[u] * 0.5)) / fit;
    let side_b = (pos[v] - (lo[v] + dims[v] * 0.5)) / fit;
    let p = [side_a, up, side_b];
    let (bark, leaf) = tree_de(
        p,
        gen.tree_depth.clamp(1, 5) as u32,
        gen.tree_wildness.clamp(0.0, 1.0),
        gen.tree_trunk.max(0.05),
        gen.tree_seed,
    );
    if leaf <= 0.0 && leaf <= bark {
        Some(gen.tree_leaf.clamp(1, 255) as u8)
    } else if bark <= 0.0 {
        Some(gen.palette)
    } else {
        None
    }
}

fn tree_de(p: [f32; 3], depth: u32, wild: f32, trunk: f32, seed: u32) -> (f32, f32) {
    const BASE_LEN: f32 = 1.0;
    const LEN_FALL: f32 = 0.72;
    const RAD_FALL: f32 = 0.78;
    let base_tilt = 0.45 + (0.85 - 0.45) * wild;
    let root = seed.wrapping_mul(2654435761).wrapping_add(1);
    let trunk_top = [0.0, BASE_LEN, 0.0];
    let mut bark = capsule(p, [0.0, 0.0, 0.0], trunk_top, trunk);
    let mut leaf = 1.0e10;
    fn walk(
        p: [f32; 3],
        parent: [f32; 3],
        dir: [f32; 3],
        len: f32,
        radius: f32,
        branch_seed: u32,
        level: u32,
        depth: u32,
        tilt: f32,
        wild: f32,
        bark: &mut f32,
        leaf: &mut f32,
    ) {
        if level > depth {
            return;
        }
        for digit in 0..3u32 {
            let child_seed = mix_seed(branch_seed, digit + 1);
            let (tip, new_dir, new_len) =
                grow_child(parent, dir, len, digit, child_seed, tilt, wild);
            let r = radius * RAD_FALL;
            let de = capsule(p, parent, tip, r);
            if level == depth {
                *leaf = leaf.min(de);
            } else {
                *bark = bark.min(de);
                walk(
                    p,
                    tip,
                    new_dir,
                    new_len,
                    r,
                    child_seed,
                    level + 1,
                    depth,
                    tilt,
                    wild,
                    bark,
                    leaf,
                );
            }
        }
    }
    if depth >= 1 {
        walk(
            p,
            trunk_top,
            [0.0, 1.0, 0.0],
            BASE_LEN * LEN_FALL / LEN_FALL,
            trunk,
            root,
            1,
            depth,
            base_tilt,
            wild,
            &mut bark,
            &mut leaf,
        );
    }
    // The first grow_child multiplies length by the falloff, and the trunk
    // length passed in is the full trunk so the first generation matches
    // `seg_len *= FALLOFF` from TREE_BASE_LENGTH.
    let _ = LEN_FALL;
    (bark, leaf)
}

fn grow_child(
    parent: [f32; 3],
    dir: [f32; 3],
    len: f32,
    digit: u32,
    seed: u32,
    base_tilt: f32,
    wild: f32,
) -> ([f32; 3], [f32; 3], f32) {
    let perp1 = perp(dir);
    let perp2 = cross(dir, perp1);
    let angle = (digit as f32 + 0.5) * (std::f32::consts::TAU / 3.0)
        + (tree_hash(seed.wrapping_add(13)) - 0.5) * wild * 0.7;
    let tilt = base_tilt * (1.0 + (tree_hash(seed.wrapping_add(29)) - 0.5) * wild * 0.5);
    let seg = len * 0.72;
    let (st, ct) = tilt.sin_cos();
    let (sa, ca) = angle.sin_cos();
    let new_dir = add3(
        scale3(dir, ct),
        scale3(add3(scale3(perp1, ca), scale3(perp2, sa)), st),
    );
    let tip = add3(parent, scale3(new_dir, seg));
    (tip, new_dir, seg)
}

fn conifer_cell(pos: [f32; 3], lo: [f32; 3], dims: [f32; 3], axis: usize, gen: &Gen) -> Option<u8> {
    let (u, v) = plane_axes(axis as i32);
    let t = (pos[axis] - lo[axis]) / dims[axis];
    let nu = norm_axis(pos, lo, dims, u);
    let nv = norm_axis(pos, lo, dims, v);
    let rad = (nu * nu + nv * nv).sqrt();
    let radial_half = 0.5 * dims[u].min(dims[v]);
    let voxel_rn = 1.0 / radial_half.max(1.0);
    let n = gen.conifer_tiers.clamp(2, 5) as f32;
    let mut envelope = 0.0_f32;
    if t >= 0.08 {
        let tf = (t - 0.08) / 0.92;
        let tier_h = 2.0 / n;
        for i in 0..n as u32 {
            let base_tf = i as f32 / n;
            let local = (tf - base_tf) / tier_h;
            if (0.0..=1.0).contains(&local) {
                envelope = envelope.max((1.0 - base_tf) * (1.0 - local));
            }
        }
    }
    let needle = gen.conifer_needle.clamp(1, 255) as u8;
    if envelope > 0.0 {
        let crown_amt = gen.conifer_crown.clamp(0.0, 1.0);
        let crown = smoothstep(0.6, 1.0, t) * crown_amt;
        let scale = gen.conifer_clump.max(1.0) * (1.0 + crown);
        let ragged = gen.conifer_ragged.clamp(0.0, 1.0) * (1.0 - 0.4 * crown);
        let theta = nv.atan2(nu);
        let ring = (radial_half / scale * 0.6).max(0.4);
        let np = [theta.cos() * ring, theta.sin() * ring, pos[axis] / scale];
        let nval = conifer_fbm(np, gen.conifer_seed);
        let n01 = (nval * 0.9 + 0.5).clamp(0.0, 1.0);
        let axis_fade = smoothstep(0.0, 3.0 * voxel_rn, rad);
        let r_eff = envelope - ragged * n01 * axis_fade;
        if rad <= r_eff {
            return Some(needle);
        }
    }
    let trunk_r0 = gen.conifer_trunk.clamp(0.05, 1.5) * 0.14;
    let trunk_rn = (trunk_r0 * (1.0 - t / 0.97)).max(voxel_rn);
    if t <= 0.97 && rad <= trunk_rn {
        Some(gen.palette)
    } else {
        None
    }
}

fn conifer_fbm(p: [f32; 3], seed: u32) -> f32 {
    perlin3(p, seed) * 0.7
        + perlin3(
            [p[0] * 2.3 + 11.0, p[1] * 2.3 + 11.0, p[2] * 2.3 + 11.0],
            seed ^ 0x68bc21eb,
        ) * 0.3
}

fn norm_axis(pos: [f32; 3], lo: [f32; 3], dims: [f32; 3], axis: usize) -> f32 {
    (pos[axis] - (lo[axis] + dims[axis] * 0.5)) / (dims[axis] * 0.5)
}

fn perlin3(p: [f32; 3], seed: u32) -> f32 {
    let pi = [
        p[0].floor() as i32,
        p[1].floor() as i32,
        p[2].floor() as i32,
    ];
    let pf = [
        p[0] - pi[0] as f32,
        p[1] - pi[1] as f32,
        p[2] - pi[2] as f32,
    ];
    let f = [fade(pf[0]), fade(pf[1]), fade(pf[2])];
    let n = |dx: i32, dy: i32, dz: i32| {
        let g = grad([pi[0] + dx, pi[1] + dy, pi[2] + dz], seed);
        let d = [pf[0] - dx as f32, pf[1] - dy as f32, pf[2] - dz as f32];
        g[0] * d[0] + g[1] * d[1] + g[2] * d[2]
    };
    let nx00 = lerp(n(0, 0, 0), n(1, 0, 0), f[0]);
    let nx10 = lerp(n(0, 1, 0), n(1, 1, 0), f[0]);
    let nx01 = lerp(n(0, 0, 1), n(1, 0, 1), f[0]);
    let nx11 = lerp(n(0, 1, 1), n(1, 1, 1), f[0]);
    let nxy0 = lerp(nx00, nx10, f[1]);
    let nxy1 = lerp(nx01, nx11, f[1]);
    lerp(nxy0, nxy1, f[2])
}

fn fade(t: f32) -> f32 {
    t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
}

fn lerp(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}

fn grad(c: [i32; 3], seed: u32) -> [f32; 3] {
    const GRADS: [[f32; 3]; 12] = [
        [1.0, 1.0, 0.0],
        [-1.0, 1.0, 0.0],
        [1.0, -1.0, 0.0],
        [-1.0, -1.0, 0.0],
        [1.0, 0.0, 1.0],
        [-1.0, 0.0, 1.0],
        [1.0, 0.0, -1.0],
        [-1.0, 0.0, -1.0],
        [0.0, 1.0, 1.0],
        [0.0, -1.0, 1.0],
        [0.0, 1.0, -1.0],
        [0.0, -1.0, -1.0],
    ];
    GRADS[(perlin_hash(c, seed) % 12) as usize]
}

fn perlin_hash(c: [i32; 3], seed: u32) -> u32 {
    let mut h = (c[0] as u32).wrapping_mul(1597334677);
    h = (h ^ (c[1] as u32).wrapping_mul(3812015801)).wrapping_mul(1597334677);
    h = (h ^ (c[2] as u32).wrapping_mul(2798796415)).wrapping_mul(1597334677);
    h = (h ^ seed).wrapping_mul(1597334677);
    h ^= h >> 16;
    h = h.wrapping_mul(2246822507);
    h ^= h >> 13;
    h
}

fn hash3(cell: Cell, stroke_id: u32) -> f32 {
    let mut v = [
        (cell.0 as u32)
            .wrapping_mul(1664525)
            .wrapping_add(1013904223),
        (cell.1 as u32)
            .wrapping_mul(1664525)
            .wrapping_add(1013904223),
        (cell.2 as u32)
            .wrapping_mul(1664525)
            .wrapping_add(1013904223),
    ];
    v[0] = v[0].wrapping_add(v[1].wrapping_mul(v[2]));
    v[1] = v[1].wrapping_add(v[2].wrapping_mul(v[0]));
    v[2] = v[2].wrapping_add(v[0].wrapping_mul(v[1]));
    v[0] ^= v[0] >> 16;
    v[1] ^= v[1] >> 16;
    v[2] ^= v[2] >> 16;
    v[0] = v[0].wrapping_add(v[1].wrapping_mul(v[2]));
    v[1] = v[1].wrapping_add(v[2].wrapping_mul(v[0]));
    v[2] = v[2].wrapping_add(v[0].wrapping_mul(v[1]));
    v[0] ^= stroke_id.wrapping_mul(2654435761);
    v[1] ^= stroke_id.wrapping_mul(1597334677);
    v[2] ^= stroke_id.wrapping_mul(374761393);
    let h = v[0] ^ v[1] ^ v[2];
    (h & 0x00ff_ffff) as f32 / (0x0100_0000 as f32)
}

fn capsule(p: [f32; 3], a: [f32; 3], b: [f32; 3], radius: f32) -> f32 {
    let ab = sub3(b, a);
    let ap = sub3(p, a);
    let ll = dot3(ab, ab);
    let t = if ll > 1e-6 {
        (dot3(ap, ab) / ll).clamp(0.0, 1.0)
    } else {
        0.0
    };
    let q = sub3(ap, scale3(ab, t));
    len3(q) - radius
}

fn perp(dir: [f32; 3]) -> [f32; 3] {
    let reference = if dir[0].abs() < 0.9 {
        [1.0, 0.0, 0.0]
    } else {
        [0.0, 0.0, 1.0]
    };
    norm3(cross(dir, reference))
}

fn tree_hash(n: u32) -> f32 {
    let mut n = (n ^ 61) ^ (n >> 16);
    n = n.wrapping_mul(9);
    n ^= n >> 4;
    n = n.wrapping_mul(0x27d4_eb2d);
    n ^= n >> 15;
    (n & 0x00ff_ffff) as f32 / (0x0100_0000 as f32)
}

fn mix_seed(a: u32, b: u32) -> u32 {
    a ^ (b
        .wrapping_add(0x9e37_79b9)
        .wrapping_add(a << 6)
        .wrapping_add(a >> 2))
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) -> f32 {
    let t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

fn project(axis: i32, cell: Cell) -> (i32, i32) {
    match axis {
        0 => (cell.1, cell.2),
        1 => (cell.0, cell.2),
        _ => (cell.0, cell.1),
    }
}

fn offset(axis: i32, anchor: Cell, i: i32, j: i32) -> Cell {
    match axis {
        0 => (anchor.0, anchor.1 + i, anchor.2 + j),
        1 => (anchor.0 + i, anchor.1, anchor.2 + j),
        _ => (anchor.0 + i, anchor.1 + j, anchor.2),
    }
}

pub(crate) fn plane_axes(axis: i32) -> (usize, usize) {
    if axis == 0 {
        (1, 2)
    } else if axis == 2 {
        (0, 1)
    } else {
        (0, 2)
    }
}

pub(crate) fn coord(cell: Cell, axis: usize) -> i32 {
    match axis {
        0 => cell.0,
        1 => cell.1,
        _ => cell.2,
    }
}

pub(crate) fn axis_delta(axis: i32, steps: i32) -> Cell {
    match axis {
        0 => (steps, 0, 0),
        1 => (0, steps, 0),
        _ => (0, 0, steps),
    }
}

fn set_plane(cell: Cell, axis: i32, u_axis: usize, v_axis: usize, du: i32, dv: i32) -> Cell {
    let mut next = cell;
    let u = coord(cell, u_axis) + du;
    let v = coord(cell, v_axis) + dv;
    next = put(next, u_axis, u);
    next = put(next, v_axis, v);
    let _ = axis;
    next
}

fn put(cell: Cell, axis: usize, value: i32) -> Cell {
    match axis {
        0 => (value, cell.1, cell.2),
        1 => (cell.0, value, cell.2),
        _ => (cell.0, cell.1, value),
    }
}

fn neighbors(eight: bool) -> Vec<(i32, i32)> {
    let mut n = vec![(1, 0), (-1, 0), (0, 1), (0, -1)];
    if eight {
        n.extend([(1, 1), (1, -1), (-1, 1), (-1, -1)]);
    }
    n
}

pub fn add(a: Cell, b: Cell) -> Cell {
    (a.0 + b.0, a.1 + b.1, a.2 + b.2)
}

const NEIGHBORS_6: [Cell; 6] = [
    (1, 0, 0),
    (-1, 0, 0),
    (0, 1, 0),
    (0, -1, 0),
    (0, 0, 1),
    (0, 0, -1),
];

fn add3(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}
fn sub3(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}
fn scale3(a: [f32; 3], s: f32) -> [f32; 3] {
    [a[0] * s, a[1] * s, a[2] * s]
}
fn dot3(a: [f32; 3], b: [f32; 3]) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
fn cross(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
fn len3(a: [f32; 3]) -> f32 {
    dot3(a, a).sqrt()
}
fn norm3(a: [f32; 3]) -> [f32; 3] {
    let len = len3(a);
    if len < 1e-8 {
        a
    } else {
        scale3(a, 1.0 / len)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_includes_both_ends() {
        let cells = bresenham((0, 0, 0), (3, 0, 0));
        assert_eq!(cells.first(), Some(&(0, 0, 0)));
        assert_eq!(cells.last(), Some(&(3, 0, 0)));
        assert_eq!(cells.len(), 4);
    }

    #[test]
    fn hollow_box_skips_the_center() {
        let cells = cube((0, 0, 0), (2, 2, 2), false);
        assert!(!cells.contains(&(1, 1, 1)));
        assert!(cells.contains(&(0, 0, 0)));
        assert!(cells.contains(&(1, 1, 0)));
    }

    #[test]
    fn ellipsoid_fills_the_center_and_not_the_corner() {
        let gen = Gen {
            kind: GeneratorKind::Ellipsoid,
            axis: Axis::Y,
            apex_at_max: true,
            palette: 4,
            torus_tube: 0.3,
            helix_turns: 2.0,
            helix_radius: 0.75,
            helix_tube: 0.16,
            helix_cw: false,
            noise_scale: 8.0,
            noise_threshold: 0.5,
            noise_octaves: 4,
            noise_seed: 1,
            perlin_lo: 1,
            perlin_hi: 8,
            tree_depth: 3,
            tree_wildness: 0.35,
            tree_trunk: 0.45,
            tree_leaf: 1,
            tree_seed: 1,
            conifer_tiers: 3,
            conifer_ragged: 0.25,
            conifer_clump: 6.0,
            conifer_trunk: 0.4,
            conifer_crown: 0.5,
            conifer_needle: 1,
            conifer_seed: 1,
        };
        let cells = generate((0, 0, 0), (2, 2, 2), &gen);
        assert!(cells.contains(&((1, 1, 1), 4)));
        assert!(!cells.iter().any(|(cell, _)| *cell == (0, 0, 0)));
    }

    #[test]
    fn flood_stops_at_a_different_color() {
        let mut cells = HashMap::new();
        cells.insert((0, 0, 0), 1);
        cells.insert((1, 0, 0), 1);
        cells.insert((2, 0, 0), 2);
        let face = flood_face(&cells, (0, 0, 0), 2, 1, 1, false);
        assert_eq!(face.len(), 2);
    }

    #[test]
    fn flood_empty_stays_on_the_plane_and_skips_solid_cells() {
        let mut cells = HashMap::new();
        cells.insert((0, 0, 0), 1);
        cells.insert((1, 0, 0), 1);
        let got = flood_empty(&cells, (0, 1, 0), 2, 0, 1, 0, 1, false);
        assert!(got.contains(&(0, 1, 0)));
        assert!(got.contains(&(1, 1, 0)));
        assert!(!got.contains(&(0, 0, 0)));
        assert_eq!(got.len(), 2);
    }

    #[test]
    fn generator_fills_past_two_hundred_thousand_cells() {
        let mut gen = Gen::default();
        gen.palette = 4;
        // 60 × 60 × 56 = 201600, above the old cap and under 2_000_000.
        let cells = generate((0, 0, 0), (59, 59, 55), &gen);
        assert!(cells
            .iter()
            .any(|(cell, slot)| *cell == (30, 30, 28) && *slot == 4));
    }

    #[test]
    fn generator_refuses_more_than_two_million_cells() {
        let gen = Gen::default();
        // 126³ = 2_000_376.
        assert!(generate((0, 0, 0), (125, 125, 125), &gen).is_empty());
    }
}
