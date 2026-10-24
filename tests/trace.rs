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
