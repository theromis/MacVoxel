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
                shade_pixel(&world, &shade, image.width, image.height, x, y, sample, 0);
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

/// Path-trace a finished frame. `seed` is mixed into the sampler; `0` matches
/// one sample of [`trace_rows`].
pub fn render_still(session: &Session, width: u32, height: u32, samples: u32, seed: u32) -> Image {
    let mut image = Image::new(width, height);
    if width == 0 || height == 0 || samples == 0 {
        return image;
    }
    let world = build_world(session);
    let shade = Shade::from_session(session);
    for sample in 0..samples {
        for y in 0..height {
            for x in 0..width {
                let (color, albedo) =
                    shade_pixel(&world, &shade, width, height, x, y, sample, seed);
                store_pixel(&mut image, &shade, x, y, sample, color, albedo);
            }
        }
        image.row = 0;
        image.samples = sample + 1;
    }
    image
}

fn shade_pixel(
    world: &World,
    shade: &Shade,
    width: u32,
    height: u32,
    x: u32,
    y: u32,
    sample: u32,
    seed: u32,
) -> ([f32; 3], [f32; 3]) {
    let mut rng = Rng(hash(x, y, sample).wrapping_add(seed));
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

pub(super) fn emission_gain(material: &Material) -> f32 {
    material.emission * (material.emission_power.max(1) as f32) * 8.0
}

pub(super) fn hash(x: u32, y: u32, sample: u32) -> u32 {
    let mut n = x
        .wrapping_mul(374761393)
        .wrapping_add(y.wrapping_mul(668265263));
    n = n.wrapping_add(sample.wrapping_mul(1440678137));
    n = (n ^ (n >> 13)).wrapping_mul(1274126177);
    n ^ (n >> 16)
}

pub(super) fn add(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

pub(super) fn sub(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

pub(super) fn mul(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] * b[0], a[1] * b[1], a[2] * b[2]]
}

pub(super) fn scale(a: [f32; 3], s: f32) -> [f32; 3] {
    [a[0] * s, a[1] * s, a[2] * s]
}

pub(super) fn lerp(a: [f32; 3], b: [f32; 3], t: f32) -> [f32; 3] {
    add(scale(a, 1.0 - t), scale(b, t))
}

pub(crate) fn linear_channel(channel: u8) -> f32 {
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

mod shade;
mod world;

use shade::{aces, denoise, first_albedo, lens_ray, primary_dir, radiance, to_srgb};
use world::build_world;
pub use world::{gpu_scene, GpuLight, GpuScene};

#[cfg(test)]
#[path = "../../tests/trace.rs"]
mod tests;
