//! CPU path tracer for Render mode.
//!
//! The window prefers the wgpu compute tracer. This CPU path is the fallback
//! when a scene does not fit in one grid, and it is what the tests run.
//! The Metal shader stays in the Mac app. Open Image Denoise is not linked.

use std::collections::HashMap;

use glam::Vec3;

use crate::state::{GlassMode, Material, MaterialType, Session};

const FOV_Y: f32 = 50.0_f32.to_radians();
const MAX_STEPS: i32 = 384;

#[derive(Clone)]
pub struct Image {
    pub width: u32,
    pub height: u32,
    pub samples: u32,
    /// Next scanline of the sample being drawn. Wraps to zero when a sample finishes.
    row: u32,
    sum: Vec<[f32; 3]>,
    shown: Vec<[f32; 3]>,
    albedo: Vec<[f32; 3]>,
}

impl Image {
    pub fn new(width: u32, height: u32) -> Self {
        let n = (width as usize) * (height as usize);
        Self {
            width,
            height,
            samples: 0,
            row: 0,
            sum: vec![[0.0; 3]; n],
            shown: vec![[0.0; 3]; n],
            albedo: vec![[0.0; 3]; n],
        }
    }

    pub fn matches(&self, width: u32, height: u32) -> bool {
        self.width == width && self.height == height
    }

    pub fn row_progress(&self) -> u32 {
        self.row
    }
}

/// Changes when the picture must start over: voxels, camera, lights, materials, size.
pub fn frame_key(session: &Session, size: [u32; 2]) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    let mix = |hash: &mut u64, bits: u64| {
        *hash ^= bits;
        *hash = hash.wrapping_mul(0x100000001b3);
    };
    mix(&mut hash, session.mesh_epoch);
    mix(&mut hash, size[0] as u64);
    mix(&mut hash, size[1] as u64);
    mix(&mut hash, session.yaw.to_bits() as u64);
    mix(&mut hash, session.pitch.to_bits() as u64);
    mix(&mut hash, session.distance.to_bits() as u64);
    mix(&mut hash, session.target.x.to_bits() as u64);
    mix(&mut hash, session.target.y.to_bits() as u64);
    mix(&mut hash, session.target.z.to_bits() as u64);
    mix(&mut hash, session.max_bounces as u64);
    mix(&mut hash, session.stochastic_gi as u64);
    mix(&mut hash, session.aperture.to_bits() as u64);
    mix(&mut hash, session.focus_distance.to_bits() as u64);
    mix(&mut hash, session.sun_elevation.to_bits() as u64);
    mix(&mut hash, session.sun_azimuth.to_bits() as u64);
    mix(&mut hash, session.sun_disc.to_bits() as u64);
    mix(&mut hash, session.sun_intensity.to_bits() as u64);
    mix(&mut hash, session.sky_intensity.to_bits() as u64);
    mix(&mut hash, session.horizon_softness.to_bits() as u64);
    mix(&mut hash, session.indirect_clamp.to_bits() as u64);
    mix(&mut hash, session.ema_floor.to_bits() as u64);
    mix(&mut hash, session.nee_ris as u64);
    mix(&mut hash, session.power_weighted_nee as u64);
    mix(&mut hash, session.atmospheric_sky as u64);
    mix(
        &mut hash,
        match session.glass_mode {
            GlassMode::Probabilistic => 0,
            GlassMode::Absorption => 1,
        },
    );
    for (slot, material) in session.materials.iter().enumerate() {
        mix(&mut hash, slot as u64);
        mix(
            &mut hash,
            match material.ty {
                MaterialType::Diffuse => 0,
                MaterialType::Metal => 1,
                MaterialType::Emissive => 2,
                MaterialType::Glass => 3,
            },
        );
        mix(&mut hash, material.roughness.to_bits() as u64);
        mix(&mut hash, material.metallic.to_bits() as u64);
        mix(&mut hash, material.emission.to_bits() as u64);
        mix(&mut hash, material.emission_power as u64);
        mix(&mut hash, material.transparency.to_bits() as u64);
        mix(&mut hash, material.ior.to_bits() as u64);
    }
    for rgba in &session.palette {
        mix(&mut hash, u32::from_le_bytes(*rgba) as u64);
    }
    hash
}

/// Voxels, materials, and palette. The camera is not part of it, so an orbit
/// does not rebuild the grid.
pub fn scene_key(session: &Session) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    let mix = |hash: &mut u64, bits: u64| {
        *hash ^= bits;
        *hash = hash.wrapping_mul(0x100000001b3);
    };
    mix(&mut hash, session.mesh_epoch);
    for (slot, material) in session.materials.iter().enumerate() {
        mix(&mut hash, slot as u64);
        mix(
            &mut hash,
            match material.ty {
                MaterialType::Diffuse => 0,
                MaterialType::Metal => 1,
                MaterialType::Emissive => 2,
                MaterialType::Glass => 3,
            },
        );
        mix(&mut hash, material.roughness.to_bits() as u64);
        mix(&mut hash, material.metallic.to_bits() as u64);
        mix(&mut hash, material.emission.to_bits() as u64);
        mix(&mut hash, material.emission_power as u64);
        mix(&mut hash, material.transparency.to_bits() as u64);
        mix(&mut hash, material.ior.to_bits() as u64);
    }
    for rgba in &session.palette {
        mix(&mut hash, u32::from_le_bytes(*rgba) as u64);
    }
    hash
}

struct World {
    grid: Grid,
    lights: Vec<Light>,
    min: [i32; 3],
    max: [i32; 3],
    count: usize,
}

enum Grid {
    /// Packed occupancy. Index 0 in the palette is empty, so a zero byte is air.
    Dense {
        origin: [i32; 3],
        dims: [usize; 3],
        cells: Vec<u8>,
    },
    Sparse(HashMap<(i32, i32, i32), u8>),
}

/// Everything a sample needs, owned so a worker thread can keep tracing
/// after the window has moved on to the next input.
struct Shade {
    materials: [Material; 256],
    palette: [[u8; 4]; 256],
    max_bounces: i32,
    stochastic_gi: bool,
    glass_mode: GlassMode,
    aperture: f32,
    focus_distance: f32,
    power_weighted_nee: bool,
    nee_ris: i32,
    indirect_clamp: f32,
    ema_floor: f32,
    atmospheric_sky: bool,
    sky_intensity: f32,
    horizon_softness: f32,
    sun_elevation: f32,
    sun_azimuth: f32,
    sun_disc: f32,
    sun_intensity: f32,
    sun_color: [f32; 3],
    eye: Vec3,
    target: Vec3,
}

impl Shade {
    fn from_session(session: &Session) -> Self {
        Self {
            materials: session.materials,
            palette: session.palette,
            max_bounces: session.max_bounces,
            stochastic_gi: session.stochastic_gi,
            glass_mode: session.glass_mode,
            aperture: session.aperture,
            focus_distance: session.focus_distance,
            power_weighted_nee: session.power_weighted_nee,
            nee_ris: session.nee_ris,
            indirect_clamp: session.indirect_clamp,
            ema_floor: session.ema_floor,
            atmospheric_sky: session.atmospheric_sky,
            sky_intensity: session.sky_intensity,
            horizon_softness: session.horizon_softness,
            sun_elevation: session.sun_elevation,
            sun_azimuth: session.sun_azimuth,
            sun_disc: session.sun_disc,
            sun_intensity: session.sun_intensity,
            sun_color: session.sun_color,
            eye: session.eye(),
            target: session.target,
        }
    }

    fn sun_dir(&self) -> Vec3 {
        let e = self.sun_elevation.to_radians();
        let a = self.sun_azimuth.to_radians();
        let dir = Vec3::new(a.cos() * e.cos(), a.sin() * e.cos(), e.sin()).normalize_or_zero();
        if dir.length_squared() < 1.0e-6 {
            Vec3::new(0.3, 0.2, 0.9).normalize()
        } else {
            dir
        }
    }
}

struct Light {
    point: Vec3,
    normal: Vec3,
    radiance: [f32; 3],
    power: f32,
}

struct Hit {
    point: Vec3,
    normal: Vec3,
    slot: u8,
}

struct Rng(u32);

impl Rng {
    fn next_f32(&mut self) -> f32 {
        self.0 = self.0.wrapping_mul(747796405).wrapping_add(2891336453);
        let word = ((self.0 >> ((self.0 >> 28) + 4)) ^ self.0).wrapping_mul(277803737);
        let bits = (word >> 22) ^ word;
        (bits >> 8) as f32 / 16_777_216.0
    }
}

/// Trace `rows` scanlines into `image`. Returns true when another sample was just finished.
pub fn trace_rows(image: &mut Image, session: &Session, rows: u32) -> bool {
    if image.width == 0 || image.height == 0 || rows == 0 {
        return false;
    }
    let world = build_world(session);
    let shade = Shade::from_session(session);
    let finished_before = image.samples;
    let mut left = rows;
    while left > 0 {
        let y = image.row;
        let sample = image.samples;
        for x in 0..image.width {
            let (color, albedo) =
                shade_pixel(&world, &shade, image.width, image.height, x, y, sample);
            store_pixel(image, &shade, x, y, sample, color, albedo);
        }
        image.row += 1;
        if image.row >= image.height {
            image.row = 0;
            image.samples += 1;
        }
        left -= 1;
    }
    image.samples > finished_before
}

fn shade_pixel(
    world: &World,
    shade: &Shade,
    width: u32,
    height: u32,
    x: u32,
    y: u32,
    sample: u32,
) -> ([f32; 3], [f32; 3]) {
    let mut rng = Rng(hash(x, y, sample));
    let center = primary_dir(width, height, x, y, shade.eye, shade.target, &mut rng);
    let (origin, dir) = lens_ray(shade, shade.eye, shade.target, center, &mut rng);
    let color = radiance(world, shade, origin, dir, 0, &mut rng);
    let albedo = if sample == 0 {
        first_albedo(world, shade, origin, dir)
    } else {
        [0.0; 3]
    };
    (color, albedo)
}

fn store_pixel(
    image: &mut Image,
    shade: &Shade,
    x: u32,
    y: u32,
    sample: u32,
    color: [f32; 3],
    albedo: [f32; 3],
) {
    let i = (y as usize) * (image.width as usize) + x as usize;
    if sample == 0 {
        image.albedo[i] = albedo;
    }
    image.sum[i] = add(image.sum[i], color);
    image.shown[i] = display_color(shade, image.sum[i], image.shown[i], color, sample);
}

fn display_color(
    shade: &Shade,
    sum: [f32; 3],
    shown: [f32; 3],
    color: [f32; 3],
    sample: u32,
) -> [f32; 3] {
    let n = (sample + 1) as f32;
    let weight = (1.0 / n).max(shade.ema_floor.clamp(0.0, 1.0));
    let blended = if sample == 0 {
        color
    } else {
        lerp(shown, color, weight)
    };
    // Keep the unbiased average when the floor is zero. A positive floor
    // matches the Metal display blend and stays noisier.
    if shade.ema_floor <= 0.0 {
        scale(sum, 1.0 / n)
    } else {
        blended
    }
}

pub fn preview_size(session: &Session, viewport: [u32; 2]) -> [u32; 2] {
    preview_capped(session, viewport, 192)
}

/// GPU frames can be larger. The long side still stays under the panel's 1024
/// unless Match window is on, and then it stops at 1280.
pub fn gpu_preview_size(session: &Session, viewport: [u32; 2]) -> [u32; 2] {
    preview_capped(session, viewport, 1280)
}

fn preview_capped(session: &Session, viewport: [u32; 2], cap: u32) -> [u32; 2] {
    let (mut w, mut h) = if session.resolution_match_window {
        (viewport[0].max(1), viewport[1].max(1))
    } else {
        (
            session.render_width.clamp(16, 1024) as u32,
            session.render_height.clamp(16, 1024) as u32,
        )
    };
    let long = w.max(h).max(1);
    if long > cap {
        let scale = cap as f32 / long as f32;
        w = ((w as f32) * scale).round().max(1.0) as u32;
        h = ((h as f32) * scale).round().max(1.0) as u32;
    }
    [w, h]
}

/// Tonemapped RGBA8, top row first, optional edge-aware filter.
pub fn pixels(image: &Image, session: &Session) -> Vec<u8> {
    let linear = if session.denoise {
        denoise(image)
    } else {
        image.shown.clone()
    };
    let mut out = Vec::with_capacity(linear.len() * 4);
    for color in linear {
        let mapped = if session.aces {
            [aces(color[0]), aces(color[1]), aces(color[2])]
        } else {
            [
                color[0].clamp(0.0, 1.0),
                color[1].clamp(0.0, 1.0),
                color[2].clamp(0.0, 1.0),
            ]
        };
        out.push(to_srgb(mapped[0]));
        out.push(to_srgb(mapped[1]));
        out.push(to_srgb(mapped[2]));
        out.push(255);
    }
    out
}

pub fn write_png(path: &std::path::Path, image: &Image, session: &Session) -> Result<(), String> {
    if image.samples == 0 && image.row == 0 {
        return Err("Render has no samples yet.".into());
    }
    let rgba = pixels(image, session);
    let mut bytes = Vec::new();
    let mut encoder = png::Encoder::new(&mut bytes, image.width, image.height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder
        .write_header()
        .map_err(|err| format!("Could not write PNG: {err}"))?;
    writer
        .write_image_data(&rgba)
        .map_err(|err| format!("Could not write PNG: {err}"))?;
    writer
        .finish()
        .map_err(|err| format!("Could not write PNG: {err}"))?;
    std::fs::write(path, bytes).map_err(|err| format!("Could not write {}: {err}", path.display()))
}

fn build_world(session: &Session) -> World {
    let mut voxels = HashMap::new();
    for object in &session.objects {
        for (cell, slot) in &object.cells {
            if *slot == 0 {
                continue;
            }
            voxels.insert(
                (
                    cell.0 + object.translation.0,
                    cell.1 + object.translation.1,
                    cell.2 + object.translation.2,
                ),
                *slot,
            );
        }
    }
    let mut min = [i32::MAX; 3];
    let mut max = [i32::MIN; 3];
    for cell in voxels.keys() {
        min[0] = min[0].min(cell.0);
        min[1] = min[1].min(cell.1);
        min[2] = min[2].min(cell.2);
        max[0] = max[0].max(cell.0);
        max[1] = max[1].max(cell.1);
        max[2] = max[2].max(cell.2);
    }
    let mut lights = Vec::new();
    let offsets = [
        (Vec3::X, Vec3::new(1.0, 0.5, 0.5)),
        (-Vec3::X, Vec3::new(0.0, 0.5, 0.5)),
        (Vec3::Y, Vec3::new(0.5, 1.0, 0.5)),
        (-Vec3::Y, Vec3::new(0.5, 0.0, 0.5)),
        (Vec3::Z, Vec3::new(0.5, 0.5, 1.0)),
        (-Vec3::Z, Vec3::new(0.5, 0.5, 0.0)),
    ];
    for (cell, slot) in &voxels {
        let material = session.materials[*slot as usize];
        if material.ty != MaterialType::Emissive || material.emission <= 0.0 {
            continue;
        }
        let origin = Vec3::new(cell.0 as f32, cell.1 as f32, cell.2 as f32);
        let radiance = scale(
            linear_rgb(session.palette[*slot as usize]),
            emission_gain(&material),
        );
        for (normal, at) in offsets {
            let neighbor = (
                cell.0 + normal.x as i32,
                cell.1 + normal.y as i32,
                cell.2 + normal.z as i32,
            );
            if voxels.contains_key(&neighbor) {
                continue;
            }
            let power = radiance[0] + radiance[1] + radiance[2];
            if power <= 0.0 {
                continue;
            }
            lights.push(Light {
                point: origin + at,
                normal,
                radiance,
                power,
            });
        }
    }
    let count = voxels.len();
    if voxels.is_empty() {
        min = [0; 3];
        max = [0; 3];
    }
    World {
        grid: pack_grid(&voxels, min, max),
        lights,
        min,
        max,
        count,
    }
}

fn pack_grid(voxels: &HashMap<(i32, i32, i32), u8>, min: [i32; 3], max: [i32; 3]) -> Grid {
    let mut dims = [0usize; 3];
    let mut volume = 1usize;
    for axis in 0..3 {
        let n = (max[axis] as i64 - min[axis] as i64 + 1).max(0) as usize;
        if n > 4096 {
            return Grid::Sparse(voxels.clone());
        }
        volume = volume.saturating_mul(n);
        dims[axis] = n;
    }
    if volume == 0 || volume > 32_000_000 {
        return Grid::Sparse(voxels.clone());
    }
    let mut cells = vec![0u8; volume];
    for (cell, slot) in voxels {
        let x = (cell.0 - min[0]) as usize;
        let y = (cell.1 - min[1]) as usize;
        let z = (cell.2 - min[2]) as usize;
        cells[x + dims[0] * (y + dims[1] * z)] = *slot;
    }
    Grid::Dense {
        origin: min,
        dims,
        cells,
    }
}

impl World {
    fn slot(&self, x: i32, y: i32, z: i32) -> Option<u8> {
        let slot = match &self.grid {
            Grid::Dense {
                origin,
                dims,
                cells,
            } => {
                let ix = x - origin[0];
                let iy = y - origin[1];
                let iz = z - origin[2];
                if ix < 0
                    || iy < 0
                    || iz < 0
                    || ix >= dims[0] as i32
                    || iy >= dims[1] as i32
                    || iz >= dims[2] as i32
                {
                    return None;
                }
                cells[ix as usize + dims[0] * (iy as usize + dims[1] * iz as usize)]
            }
            Grid::Sparse(map) => return map.get(&(x, y, z)).copied(),
        };
        if slot == 0 {
            None
        } else {
            Some(slot)
        }
    }
}

/// One grid the GPU can index. `None` when the scene is too spread out to pack.
pub struct GpuScene {
    pub origin: [i32; 4],
    pub dims: [u32; 4],
    pub cells: Vec<u32>,
    pub lights: Vec<GpuLight>,
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct GpuLight {
    pub point: [f32; 4],
    pub normal: [f32; 4],
    /// xyz radiance, w power.
    pub radiance: [f32; 4],
}

pub fn gpu_scene(session: &Session) -> Option<GpuScene> {
    let world = build_world(session);
    let Grid::Dense {
        origin,
        dims,
        cells,
    } = &world.grid
    else {
        return None;
    };
    let lights = world
        .lights
        .iter()
        .take(4096)
        .map(|light| GpuLight {
            point: [light.point.x, light.point.y, light.point.z, 1.0],
            normal: [light.normal.x, light.normal.y, light.normal.z, 0.0],
            radiance: [
                light.radiance[0],
                light.radiance[1],
                light.radiance[2],
                light.power,
            ],
        })
        .collect();
    Some(GpuScene {
        origin: [origin[0], origin[1], origin[2], 0],
        dims: [dims[0] as u32, dims[1] as u32, dims[2] as u32, 0],
        cells: cells.iter().map(|slot| u32::from(*slot)).collect(),
        lights,
    })
}

fn emission_gain(material: &Material) -> f32 {
    material.emission * (material.emission_power.max(1) as f32) * 8.0
}

fn radiance(
    world: &World,
    session: &Shade,
    origin: Vec3,
    dir: Vec3,
    bounce: i32,
    rng: &mut Rng,
) -> [f32; 3] {
    let bounces = session.max_bounces.clamp(1, 8);
    if bounce > bounces {
        return [0.0; 3];
    }
    let Some(hit) = march(world, origin, dir) else {
        return sky(session, dir, bounce == 0);
    };
    let material = session.materials[hit.slot as usize];
    let albedo = linear_rgb(session.palette[hit.slot as usize]);
    let color = match material.ty {
        MaterialType::Emissive => {
            // Next-event estimation already samples these faces. Counting them
            // again on a bounce would light the scene twice.
            if bounce > 0 && session.stochastic_gi {
                [0.0; 3]
            } else {
                scale(albedo, emission_gain(&material))
            }
        }
        MaterialType::Metal => {
            let reflect = reflect(-dir, hit.normal);
            let rough = material.roughness.clamp(0.0, 1.0);
            let wi = if rough > 0.02 {
                lerp_dir(reflect, cosine_hemisphere(hit.normal, rng), rough).normalize_or_zero()
            } else {
                reflect
            };
            if wi.dot(hit.normal) <= 0.0 || bounce == bounces {
                [0.0; 3]
            } else {
                let next = radiance(world, session, hit.point + wi * 0.001, wi, bounce + 1, rng);
                mul(albedo, next)
            }
        }
        MaterialType::Glass => glass(world, session, &hit, albedo, &material, dir, bounce, rng),
        MaterialType::Diffuse => diffuse(world, session, &hit, albedo, dir, bounce, rng),
    };
    if bounce > 0 {
        clamp_indirect(color, session.indirect_clamp)
    } else {
        color
    }
}

fn diffuse(
    world: &World,
    session: &Shade,
    hit: &Hit,
    albedo: [f32; 3],
    _dir: Vec3,
    bounce: i32,
    rng: &mut Rng,
) -> [f32; 3] {
    let sun = sun_radiance(session);
    let ndotl = hit.normal.dot(session.sun_dir()).max(0.0);
    let mut color = if ndotl > 0.0 && !occluded(world, hit.point, session.sun_dir(), f32::MAX) {
        scale(mul(albedo, sun), ndotl)
    } else {
        [0.0; 3]
    };
    if session.stochastic_gi && bounce < session.max_bounces.clamp(1, 8) {
        if !world.lights.is_empty() {
            color = add(color, nee(world, session, hit, albedo, bounce, rng));
        }
        let wi = cosine_hemisphere(hit.normal, rng);
        let next = radiance(world, session, hit.point + wi * 0.001, wi, bounce + 1, rng);
        color = add(color, mul(albedo, next));
    } else {
        let ambient = scale(sky(session, hit.normal, false), 0.35);
        color = add(color, mul(albedo, ambient));
    }
    color
}

fn glass(
    world: &World,
    session: &Shade,
    hit: &Hit,
    albedo: [f32; 3],
    material: &Material,
    dir: Vec3,
    bounce: i32,
    rng: &mut Rng,
) -> [f32; 3] {
    if session.glass_mode == GlassMode::Absorption {
        let tint = lerp(
            albedo,
            [1.0, 1.0, 1.0],
            material.transparency.clamp(0.0, 1.0),
        );
        let next = radiance(
            world,
            session,
            hit.point + dir * 0.002,
            dir,
            bounce + 1,
            rng,
        );
        return mul(tint, next);
    }
    let ior = material.ior.clamp(1.0, 3.0);
    let entering = dir.dot(hit.normal) < 0.0;
    let (n, eta) = if entering {
        (hit.normal, 1.0 / ior)
    } else {
        (-hit.normal, ior)
    };
    let cos_i = (-dir).dot(n).clamp(0.0, 1.0);
    let fresnel = schlick(cos_i, ior);
    let reflect_dir = reflect(-dir, n);
    if rng.next_f32() < fresnel {
        return radiance(
            world,
            session,
            hit.point + reflect_dir * 0.001,
            reflect_dir,
            bounce + 1,
            rng,
        );
    }
    let Some(refract_dir) = refract(dir, n, eta) else {
        return radiance(
            world,
            session,
            hit.point + reflect_dir * 0.001,
            reflect_dir,
            bounce + 1,
            rng,
        );
    };
    radiance(
        world,
        session,
        hit.point + refract_dir * 0.001,
        refract_dir,
        bounce + 1,
        rng,
    )
}

fn nee(
    world: &World,
    session: &Shade,
    hit: &Hit,
    albedo: [f32; 3],
    bounce: i32,
    rng: &mut Rng,
) -> [f32; 3] {
    let candidates = session.nee_ris.clamp(1, 32) as u32;
    let mut chosen: Option<&Light> = None;
    let mut chosen_w = 0.0;
    let mut total = 0.0;
    for _ in 0..candidates {
        let light = pick_light(world, session.power_weighted_nee, rng);
        let to = light.point - hit.point;
        let dist2 = to.length_squared().max(1.0e-4);
        let wi = to.normalize_or_zero();
        let cos_l = light.normal.dot(-wi).max(0.0);
        let cos_h = hit.normal.dot(wi).max(0.0);
        let weight = light.power * cos_l * cos_h / dist2;
        total += weight;
        if rng.next_f32() * (chosen_w + weight) <= weight || chosen.is_none() {
            chosen = Some(light);
            chosen_w = weight;
        }
    }
    let Some(light) = chosen else {
        return [0.0; 3];
    };
    let to = light.point - hit.point;
    let dist = to.length().max(1.0e-3);
    let wi = to / dist;
    if occluded(world, hit.point, wi, dist - 0.02) {
        return [0.0; 3];
    }
    let cos_l = light.normal.dot(-wi).max(0.0);
    let cos_h = hit.normal.dot(wi).max(0.0);
    let mut contrib = scale(mul(albedo, light.radiance), cos_l * cos_h / (dist * dist));
    if candidates > 1 && chosen_w > 0.0 {
        contrib = scale(contrib, total / (candidates as f32 * chosen_w.max(1.0e-6)));
    }
    if bounce > 0 {
        clamp_indirect(contrib, session.indirect_clamp)
    } else {
        contrib
    }
}

fn pick_light<'a>(world: &'a World, power_weighted: bool, rng: &mut Rng) -> &'a Light {
    if !power_weighted || world.lights.len() == 1 {
        return &world.lights
            [(rng.next_f32() * world.lights.len() as f32) as usize % world.lights.len()];
    }
    let sum: f32 = world.lights.iter().map(|light| light.power).sum();
    let mut pick = rng.next_f32() * sum.max(1.0e-6);
    for light in &world.lights {
        pick -= light.power;
        if pick <= 0.0 {
            return light;
        }
    }
    world.lights.last().expect("lights")
}

fn march(world: &World, origin: Vec3, dir: Vec3) -> Option<Hit> {
    if world.count == 0 || dir.length_squared() < 1.0e-8 {
        return None;
    }
    let Some(entry) = ray_box_entry(origin, dir, world.min, world.max) else {
        return None;
    };
    let origin = origin + dir * entry;
    let mut cell = [
        origin.x.floor() as i32,
        origin.y.floor() as i32,
        origin.z.floor() as i32,
    ];
    let step = [
        if dir.x >= 0.0 { 1 } else { -1 },
        if dir.y >= 0.0 { 1 } else { -1 },
        if dir.z >= 0.0 { 1 } else { -1 },
    ];
    let delta = [
        if dir.x.abs() < 1.0e-8 {
            f32::MAX
        } else {
            (1.0 / dir.x).abs()
        },
        if dir.y.abs() < 1.0e-8 {
            f32::MAX
        } else {
            (1.0 / dir.y).abs()
        },
        if dir.z.abs() < 1.0e-8 {
            f32::MAX
        } else {
            (1.0 / dir.z).abs()
        },
    ];
    let mut tmax = [0.0; 3];
    for axis in 0..3 {
        let start = if step[axis] > 0 {
            (cell[axis] + 1) as f32
        } else {
            cell[axis] as f32
        };
        let coord = [origin.x, origin.y, origin.z][axis];
        let component = [dir.x, dir.y, dir.z][axis];
        tmax[axis] = if component.abs() < 1.0e-8 {
            f32::MAX
        } else {
            (start - coord) / component
        };
    }
    let mut normal = -dir.normalize_or_zero();
    if let Some(slot) = world.slot(cell[0], cell[1], cell[2]) {
        return Some(hit_at(cell, normal, slot));
    }
    for _ in 0..MAX_STEPS {
        let axis = if tmax[0] <= tmax[1] && tmax[0] <= tmax[2] {
            0
        } else if tmax[1] <= tmax[2] {
            1
        } else {
            2
        };
        cell[axis] += step[axis];
        tmax[axis] += delta[axis];
        normal = Vec3::ZERO;
        match axis {
            0 => normal.x = -step[0] as f32,
            1 => normal.y = -step[1] as f32,
            _ => normal.z = -step[2] as f32,
        }
        if cell[axis] < world.min[axis] - 1 || cell[axis] > world.max[axis] + 1 {
            return None;
        }
        if let Some(slot) = world.slot(cell[0], cell[1], cell[2]) {
            return Some(hit_at(cell, normal, slot));
        }
    }
    None
}

fn hit_at(cell: [i32; 3], normal: Vec3, slot: u8) -> Hit {
    let point =
        Vec3::new(cell[0] as f32, cell[1] as f32, cell[2] as f32) + Vec3::splat(0.5) + normal * 0.5;
    Hit {
        point,
        normal,
        slot,
    }
}

fn occluded(world: &World, origin: Vec3, dir: Vec3, max_dist: f32) -> bool {
    let Some(hit) = march(world, origin + dir * 0.002, dir) else {
        return false;
    };
    (hit.point - origin).dot(dir) < max_dist
}

fn ray_box_entry(origin: Vec3, dir: Vec3, min: [i32; 3], max: [i32; 3]) -> Option<f32> {
    let mut t0 = 0.0_f32;
    let mut t1 = f32::MAX;
    let lo = [min[0] as f32, min[1] as f32, min[2] as f32];
    let hi = [
        max[0] as f32 + 1.0,
        max[1] as f32 + 1.0,
        max[2] as f32 + 1.0,
    ];
    let o = [origin.x, origin.y, origin.z];
    let d = [dir.x, dir.y, dir.z];
    for axis in 0..3 {
        if d[axis].abs() < 1.0e-8 {
            if o[axis] < lo[axis] || o[axis] > hi[axis] {
                return None;
            }
            continue;
        }
        let inv = 1.0 / d[axis];
        let mut a = (lo[axis] - o[axis]) * inv;
        let mut b = (hi[axis] - o[axis]) * inv;
        if a > b {
            std::mem::swap(&mut a, &mut b);
        }
        t0 = t0.max(a);
        t1 = t1.min(b);
        if t0 > t1 {
            return None;
        }
    }
    if t1 < 0.0 {
        None
    } else {
        Some(t0.max(0.0))
    }
}

fn primary_dir(
    width: u32,
    height: u32,
    x: u32,
    y: u32,
    eye: Vec3,
    target: Vec3,
    rng: &mut Rng,
) -> Vec3 {
    let forward = (target - eye).normalize_or_zero();
    let world_up = if forward.dot(Vec3::Z).abs() > 0.95 {
        Vec3::Y
    } else {
        Vec3::Z
    };
    let right = forward.cross(world_up).normalize_or_zero();
    let up = right.cross(forward).normalize_or_zero();
    let aspect = width as f32 / height.max(1) as f32;
    let tan = (FOV_Y * 0.5).tan();
    let jitter_x = rng.next_f32() - 0.5;
    let jitter_y = rng.next_f32() - 0.5;
    let u = ((x as f32 + 0.5 + jitter_x) / width as f32) * 2.0 - 1.0;
    let v = 1.0 - ((y as f32 + 0.5 + jitter_y) / height as f32) * 2.0;
    (forward + right * (u * aspect * tan) + up * (v * tan)).normalize_or_zero()
}

fn lens_ray(session: &Shade, eye: Vec3, target: Vec3, dir: Vec3, rng: &mut Rng) -> (Vec3, Vec3) {
    if session.aperture <= 0.0 {
        return (eye, dir);
    }
    let forward = (target - eye).normalize_or_zero();
    let world_up = if forward.dot(Vec3::Z).abs() > 0.95 {
        Vec3::Y
    } else {
        Vec3::Z
    };
    let right = forward.cross(world_up).normalize_or_zero();
    let up = right.cross(forward);
    let radius = session.aperture.sqrt() * 0.05 * rng.next_f32().sqrt();
    let angle = rng.next_f32() * std::f32::consts::TAU;
    let lens = eye + right * (angle.cos() * radius) + up * (angle.sin() * radius);
    let focus = eye + dir * session.focus_distance.max(0.05);
    (lens, (focus - lens).normalize_or_zero())
}

fn sun_radiance(session: &Shade) -> [f32; 3] {
    scale(session.sun_color, session.sun_intensity.max(0.0))
}

fn sky(session: &Shade, dir: Vec3, include_sun: bool) -> [f32; 3] {
    let up = dir.z.clamp(-1.0, 1.0);
    let horizon = (-up.abs() * session.horizon_softness.max(0.0)).exp();
    let zenith = if session.atmospheric_sky {
        [0.25, 0.45, 0.85]
    } else {
        [0.55, 0.62, 0.72]
    };
    let ground = [0.28, 0.26, 0.24];
    let base = if up >= 0.0 {
        lerp(zenith, [0.75, 0.78, 0.82], horizon)
    } else {
        lerp(ground, [0.75, 0.78, 0.82], horizon)
    };
    let mut color = scale(base, session.sky_intensity.max(0.0));
    if include_sun {
        let cos = dir
            .normalize_or_zero()
            .dot(session.sun_dir())
            .clamp(-1.0, 1.0);
        let radius = (session.sun_disc.max(0.1).to_radians() * 0.5).cos();
        if cos >= radius {
            color = add(color, sun_radiance(session));
        }
    }
    color
}

fn first_albedo(world: &World, session: &Shade, origin: Vec3, dir: Vec3) -> [f32; 3] {
    march(world, origin, dir)
        .map(|hit| linear_rgb(session.palette[hit.slot as usize]))
        .unwrap_or([0.0; 3])
}

fn denoise(image: &Image) -> Vec<[f32; 3]> {
    let w = image.width as i32;
    let h = image.height as i32;
    let mut out = vec![[0.0; 3]; image.shown.len()];
    for y in 0..h {
        for x in 0..w {
            let i = (y * w + x) as usize;
            let mut acc = [0.0; 3];
            let mut weight = 0.0;
            for dy in -1..=1 {
                for dx in -1..=1 {
                    let nx = x + dx;
                    let ny = y + dy;
                    if nx < 0 || ny < 0 || nx >= w || ny >= h {
                        continue;
                    }
                    let j = (ny * w + nx) as usize;
                    let diff = sub(image.albedo[i], image.albedo[j]);
                    let dist = (diff[0] * diff[0] + diff[1] * diff[1] + diff[2] * diff[2]).sqrt();
                    let wgt = (-dist * 12.0).exp();
                    acc = add(acc, scale(image.shown[j], wgt));
                    weight += wgt;
                }
            }
            out[i] = scale(acc, 1.0 / weight.max(1.0e-6));
        }
    }
    out
}

fn cosine_hemisphere(normal: Vec3, rng: &mut Rng) -> Vec3 {
    let u1 = rng.next_f32().clamp(1.0e-6, 1.0);
    let u2 = rng.next_f32();
    let r = u1.sqrt();
    let phi = std::f32::consts::TAU * u2;
    let local = Vec3::new(r * phi.cos(), r * phi.sin(), (1.0 - u1).sqrt());
    let tangent = if normal.z.abs() < 0.9 {
        normal.cross(Vec3::Z).normalize()
    } else {
        normal.cross(Vec3::X).normalize()
    };
    let bitangent = normal.cross(tangent);
    (tangent * local.x + bitangent * local.y + normal * local.z).normalize_or_zero()
}

fn reflect(incoming: Vec3, normal: Vec3) -> Vec3 {
    (incoming - normal * (2.0 * incoming.dot(normal))).normalize_or_zero()
}

fn refract(dir: Vec3, normal: Vec3, eta: f32) -> Option<Vec3> {
    let cos_i = (-dir).dot(normal).clamp(-1.0, 1.0);
    let sin2_t = eta * eta * (1.0 - cos_i * cos_i);
    if sin2_t > 1.0 {
        return None;
    }
    let cos_t = (1.0 - sin2_t).sqrt();
    Some((dir * eta + normal * (eta * cos_i - cos_t)).normalize_or_zero())
}

fn schlick(cos: f32, ior: f32) -> f32 {
    let r0 = ((1.0 - ior) / (1.0 + ior)).powi(2);
    r0 + (1.0 - r0) * (1.0 - cos).powi(5)
}

fn lerp_dir(a: Vec3, b: Vec3, t: f32) -> Vec3 {
    a * (1.0 - t) + b * t
}

fn clamp_indirect(color: [f32; 3], limit: f32) -> [f32; 3] {
    if limit <= 0.0 {
        return color;
    }
    let peak = color[0].max(color[1]).max(color[2]);
    if peak <= limit {
        color
    } else {
        scale(color, limit / peak)
    }
}

fn aces(x: f32) -> f32 {
    let x = x.max(0.0);
    ((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14)).clamp(0.0, 1.0)
}

fn linear_channel(channel: u8) -> f32 {
    let encoded = channel as f32 / 255.0;
    if encoded <= 0.04045 {
        encoded / 12.92
    } else {
        ((encoded + 0.055) / 1.055).powf(2.4)
    }
}

pub(crate) fn linear_rgb(rgba: [u8; 4]) -> [f32; 3] {
    [
        linear_channel(rgba[0]),
        linear_channel(rgba[1]),
        linear_channel(rgba[2]),
    ]
}

fn to_srgb(linear: f32) -> u8 {
    let linear = linear.clamp(0.0, 1.0);
    let encoded = if linear <= 0.0031308 {
        linear * 12.92
    } else {
        1.055 * linear.powf(1.0 / 2.4) - 0.055
    };
    (encoded * 255.0 + 0.5).clamp(0.0, 255.0) as u8
}

fn hash(x: u32, y: u32, sample: u32) -> u32 {
    let mut n = x
        .wrapping_mul(374761393)
        .wrapping_add(y.wrapping_mul(668265263));
    n = n.wrapping_add(sample.wrapping_mul(1440678137));
    n = (n ^ (n >> 13)).wrapping_mul(1274126177);
    n ^ (n >> 16)
}

fn add(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

fn sub(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn mul(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] * b[0], a[1] * b[1], a[2] * b[2]]
}

fn scale(a: [f32; 3], s: f32) -> [f32; 3] {
    [a[0] * s, a[1] * s, a[2] * s]
}

fn lerp(a: [f32; 3], b: [f32; 3], t: f32) -> [f32; 3] {
    add(scale(a, 1.0 - t), scale(b, t))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::{Material, MaterialType, Session};

    fn voxel(session: &mut Session, cell: (i32, i32, i32), slot: u8) {
        session.objects[0].cells.insert(cell, slot);
    }

    #[test]
    fn a_ray_hits_the_voxel_in_front_of_it() {
        let mut session = Session::new();
        session.objects[0].cells.clear();
        voxel(&mut session, (0, 0, 0), 1);
        session.target = Vec3::new(0.5, 0.5, 0.5);
        session.distance = 6.0;
        session.yaw = 0.0;
        session.pitch = 0.0;
        let image = Image::new(1, 1);
        let world = build_world(&session);
        let eye = Vec3::new(0.5, -4.0, 0.5);
        let hit = march(&world, eye, Vec3::Y).expect("hit");
        assert_eq!(hit.slot, 1);
        assert!(image.samples == 0);
    }

    #[test]
    fn an_emissive_voxel_lights_the_pixel() {
        let mut session = Session::new();
        session.objects[0].cells.clear();
        session.stochastic_gi = false;
        session.sun_intensity = 0.0;
        session.sky_intensity = 0.0;
        session.aces = false;
        session.denoise = false;
        session.ema_floor = 0.0;
        voxel(&mut session, (0, 0, 0), 4);
        session.materials[4] = Material {
            ty: MaterialType::Emissive,
            emission: 1.0,
            emission_power: 2,
            ..Material::default()
        };
        session.palette[4] = [255, 0, 0, 255];
        session.target = Vec3::new(0.5, 0.5, 0.5);
        session.yaw = -std::f32::consts::FRAC_PI_2;
        session.pitch = 0.0;
        session.distance = 1.2;
        let mut image = Image::new(1, 1);
        trace_rows(&mut image, &session, 1);
        let px = pixels(&image, &session);
        assert!(px[0] > px[1] && px[0] > 20, "rgba {px:?}");
    }

    #[test]
    fn an_emissive_neighbor_lights_a_diffuse_face() {
        let mut session = Session::new();
        session.objects[0].cells.clear();
        session.sun_intensity = 0.0;
        session.sky_intensity = 0.0;
        session.aces = false;
        session.denoise = false;
        session.ema_floor = 0.0;
        session.stochastic_gi = true;
        voxel(&mut session, (0, 0, 0), 4);
        voxel(&mut session, (2, 2, 0), 1);
        session.materials[4] = Material {
            ty: MaterialType::Emissive,
            emission: 1.0,
            emission_power: 2,
            ..Material::default()
        };
        session.palette[4] = [255, 0, 0, 255];
        session.palette[1] = [255, 255, 255, 255];
        session.target = Vec3::new(2.5, 2.5, 0.5);
        session.yaw = -std::f32::consts::FRAC_PI_2;
        session.pitch = 0.0;
        session.distance = 1.2;
        let mut image = Image::new(1, 1);
        trace_rows(&mut image, &session, 1);
        let px = pixels(&image, &session);
        assert!(px[0] > px[1] && px[0] > 20, "rgba {px:?}");
    }

    #[test]
    fn save_render_writes_a_png() {
        let mut session = Session::new();
        session.objects[0].cells.clear();
        voxel(&mut session, (0, 0, 0), 1);
        session.ema_floor = 0.0;
        let mut image = Image::new(2, 2);
        trace_rows(&mut image, &session, 2);
        let path = std::env::temp_dir().join("macvoxel-egui-render.png");
        write_png(&path, &image, &session).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(&bytes[..8], &[137, 80, 78, 71, 13, 10, 26, 10]);
        let _ = std::fs::remove_file(path);
    }
}
