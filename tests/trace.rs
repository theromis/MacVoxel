use super::shade::{ggx_sample_vndf, nishita_sky};
use super::world::{build_world, march};
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
fn noon_nishita_is_blue_and_a_downward_ray_is_dark() {
    let cos_half = 15.0_f32.to_radians().cos();
    let white = [1.0, 1.0, 1.0];
    let noon = nishita_sky(Vec3::Z, Vec3::Z, white, cos_half);
    let down = nishita_sky(-Vec3::Z, Vec3::Z, white, cos_half);
    let sunset = nishita_sky(Vec3::Z, Vec3::X, white, cos_half);
    assert!(noon.iter().all(|c| c.is_finite() && *c > 0.0), "{noon:?}");
    assert!(noon[2] > noon[0], "noon {noon:?}");
    assert!(noon[2] > down[2] * 4.0 + 1.0e-4, "down {down:?}");
    assert!(noon[2] > sunset[2], "sunset {sunset:?}");
}

#[test]
fn a_smooth_ggx_facet_is_the_mirror_and_rough_samples_stay_above() {
    let normal = Vec3::Z;
    let dir = Vec3::new(0.2, -0.1, -1.0).normalize();
    let mut rng = super::Rng(1);
    let facet = ggx_sample_vndf(normal, -dir, 0.0, &mut rng);
    assert!(facet.dot(normal) > 0.999, "{facet:?}");
    let mirror = dir - normal * (2.0 * dir.dot(normal));
    let wi = dir - facet * (2.0 * dir.dot(facet));
    assert!(wi.normalize().dot(mirror.normalize()) > 0.999);
    for _ in 0..24 {
        let facet = ggx_sample_vndf(normal, -dir, 0.4, &mut rng);
        let wi = (dir - facet * (2.0 * dir.dot(facet))).normalize();
        assert!(wi.dot(normal) > 0.0, "{wi:?}");
    }
}

#[test]
fn a_metal_with_zero_metallic_matches_diffuse() {
    let diffuse = neighbor_scene();
    let mut metal = neighbor_scene();
    metal.materials[1].ty = MaterialType::Metal;
    metal.materials[1].metallic = 0.0;
    let mut left = Image::new(1, 1);
    let mut right = Image::new(1, 1);
    trace_rows(&mut left, &diffuse, 1);
    trace_rows(&mut right, &metal, 1);
    assert_eq!(pixels(&left, &diffuse), pixels(&right, &metal));
}

fn neighbor_scene() -> Session {
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
    session
}

#[test]
fn a_pending_render_is_written_only_at_the_sample_cap() {
    let mut session = Session::new();
    session.max_samples = 4;
    session.render_save_path = Some(std::path::PathBuf::from("later.png"));
    assert!(session.take_finished_render(3).is_none());
    assert!(session.render_save_path.is_some());
    let path = session.take_finished_render(4).unwrap();
    assert_eq!(path, std::path::PathBuf::from("later.png"));
    assert!(session.render_save_path.is_none());
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
