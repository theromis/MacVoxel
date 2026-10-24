//! Side panels. The layout matches the SwiftUI shell: tools and palette
//! on the left, scene and render settings on the right.

use egui::{Color32, RichText, Slider, Ui};

use crate::state::*;

/// Secondary labels. Light enough to read on the blue-gray panel
/// (`#2c333e`), still quieter than the primary text.
pub(super) const DIM: Color32 = Color32::from_rgb(196, 206, 220);

pub fn left(ui: &mut Ui, session: &mut Session) {
    tools::tools(ui, session);
    ui.separator();
    palette::palette(ui, session);
}

/// Inspector on top, scene tree docked at the bottom.
pub fn right(ui: &mut Ui, session: &mut Session) {
    outliner::tree_panel(ui, session);
    egui::ScrollArea::vertical()
        .id_salt("inspector")
        .show(ui, |ui| {
            outliner::object(ui, session);
            ui.separator();
            outliner::bone(ui, session);
            ui.separator();
            outliner::pose(ui, session);
            ui.separator();
            outliner::clips(ui, session);
            ui.separator();
            script::script(ui, session);
            ui.separator();
            render::document(ui, session);
            ui.separator();
            render::export(ui, session);
            ui.separator();
            render::render(ui, session);
            ui.separator();
            render::light(ui, session);
            ui.separator();
            render::selection(ui, session);
        });
    // A drag on a panel field ends with the button; its edits are one undo step.
    if !ui.input(|input| input.pointer.any_down()) {
        session.end_gesture();
    }
}

pub(super) fn section(ui: &mut Ui, title: &str) {
    ui.add_space(4.0);
    ui.label(RichText::new(title.to_ascii_uppercase()).small().strong());
}

/// A button `ui_click` can press. Both run [`Session::activate_ui`].
pub(super) fn action_button(
    ui: &mut Ui,
    session: &mut Session,
    id: &str,
    label: &str,
    action: UiAction,
) {
    let resp = ui.button(label);
    run_action(session, id, label, resp, action);
}

/// A checkbox `ui_click` can toggle. The action flips the value.
pub(super) fn action_checkbox(
    ui: &mut Ui,
    session: &mut Session,
    id: &str,
    label: &str,
    on: bool,
    action: UiAction,
) {
    let mut shown = on;
    let resp = ui.checkbox(&mut shown, label);
    run_action(session, id, label, resp, action);
}

fn run_action(
    session: &mut Session,
    id: &str,
    label: &str,
    resp: egui::Response,
    action: UiAction,
) {
    session.note_ui(id, label, resp.rect, action);
    if resp.clicked() {
        let region = session.ui_regions.last().cloned().expect("noted above");
        if let Err(err) = session.activate_ui(&region, None) {
            session.status = err;
        }
    }
}

pub(super) fn segment<T: PartialEq + Copy>(ui: &mut Ui, value: &mut T, opts: &[(&str, T)]) {
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 2.0;
        for (name, v) in opts {
            ui.selectable_value(value, *v, *name);
        }
    });
}

pub(super) fn slider_i32(
    ui: &mut Ui,
    session: &mut Session,
    label: &str,
    target: SliderTarget,
    range: std::ops::RangeInclusive<i32>,
) {
    let mut value = slider_value(session, target).round() as i32;
    ui.horizontal(|ui| {
        ui.add_sized(
            [96.0, 16.0],
            egui::Label::new(RichText::new(label).small().color(DIM)),
        );
        let resp = ui.add(Slider::new(&mut value, range.clone()).show_value(false));
        note_slider(
            session,
            label,
            target,
            resp.rect,
            *range.start() as f32,
            *range.end() as f32,
        );
        if resp.changed() {
            session.write_slider(target, value as f32);
        }
        ui.monospace(format!("{value}"));
    });
}

pub(super) fn slider_f32(
    ui: &mut Ui,
    session: &mut Session,
    label: &str,
    target: SliderTarget,
    range: std::ops::RangeInclusive<f32>,
    digits: usize,
) {
    let mut value = slider_value(session, target);
    ui.horizontal(|ui| {
        ui.add_sized(
            [96.0, 16.0],
            egui::Label::new(RichText::new(label).small().color(DIM)),
        );
        let resp = ui.add(Slider::new(&mut value, range.clone()).show_value(false));
        note_slider(
            session,
            label,
            target,
            resp.rect,
            *range.start(),
            *range.end(),
        );
        if resp.changed() {
            session.write_slider(target, value);
        }
        ui.monospace(format!("{value:.digits$}"));
    });
}

pub(super) fn slider_value(session: &Session, target: SliderTarget) -> f32 {
    match target {
        SliderTarget::BrushSize => session.brush_size as f32,
        SliderTarget::FoliageSeed => session.foliage_seed as f32,
        SliderTarget::FoliageDensity => session.foliage_density,
        SliderTarget::TorusTube => session.torus_tube,
        SliderTarget::RoundRadius => session.round_radius,
        SliderTarget::NoiseScale => session.noise_scale,
        SliderTarget::NoiseThreshold => session.noise_threshold,
        SliderTarget::NoiseOctaves => session.noise_octaves as f32,
        SliderTarget::NoiseSeed => session.noise_seed as f32,
        SliderTarget::PerlinLo => session.perlin_lo as f32,
        SliderTarget::PerlinHi => session.perlin_hi as f32,
        SliderTarget::TreeDepth => session.tree_depth as f32,
        SliderTarget::TreeWildness => session.tree_wildness,
        SliderTarget::TreeTrunk => session.tree_trunk,
        SliderTarget::TreeLeaf => session.tree_leaf as f32,
        SliderTarget::TreeSeed => session.tree_seed as f32,
        SliderTarget::HelixTurns => session.helix_turns,
        SliderTarget::HelixRadius => session.helix_radius,
        SliderTarget::HelixTube => session.helix_tube,
        SliderTarget::ConiferTiers => session.conifer_tiers as f32,
        SliderTarget::ConiferRagged => session.conifer_ragged,
        SliderTarget::ConiferClump => session.conifer_clump,
        SliderTarget::ConiferTrunk => session.conifer_trunk,
        SliderTarget::ConiferCrown => session.conifer_crown,
        SliderTarget::ConiferNeedle => session.conifer_needle as f32,
        SliderTarget::ConiferSeed => session.conifer_seed as f32,
        SliderTarget::MaxSamples => session.max_samples as f32,
        SliderTarget::Aperture => session.aperture,
        SliderTarget::FocusDistance => session.focus_distance,
        SliderTarget::MaterialRoughness
        | SliderTarget::MaterialMetallic
        | SliderTarget::MaterialTransparency
        | SliderTarget::MaterialIor
        | SliderTarget::MaterialEmission
        | SliderTarget::MaterialPower
        | SliderTarget::MotionAmount => material_shown(session, target),
        SliderTarget::MaxBounces => session.max_bounces as f32,
        SliderTarget::NeeRis => session.nee_ris as f32,
        SliderTarget::IndirectClamp => session.indirect_clamp,
        SliderTarget::EmaFloor => session.ema_floor,
        SliderTarget::SkyIntensity => session.sky_intensity,
        SliderTarget::HorizonSoftness => session.horizon_softness,
        SliderTarget::SunElevation => session.sun_elevation,
        SliderTarget::SunAzimuth => session.sun_azimuth,
        SliderTarget::SunDisc => session.sun_disc,
        SliderTarget::SunIntensity => session.sun_intensity,
    }
}

pub(super) fn note_slider(
    session: &mut Session,
    label: &str,
    target: SliderTarget,
    rect: egui::Rect,
    min: f32,
    max: f32,
) {
    session.note_ui(
        target.id(),
        label,
        rect,
        UiAction::Slider(SliderSpec { target, min, max }),
    );
}

pub(super) fn material_shown(session: &Session, target: SliderTarget) -> f32 {
    let mat = &session.materials[session.active_slot as usize];
    match target {
        SliderTarget::MaterialRoughness => mat.roughness,
        SliderTarget::MaterialMetallic => mat.metallic,
        SliderTarget::MaterialTransparency => mat.transparency,
        SliderTarget::MaterialIor => mat.ior,
        SliderTarget::MaterialEmission => mat.emission * 100.0,
        SliderTarget::MaterialPower => mat.emission_power as f32,
        SliderTarget::MotionAmount => mat.motion_amount,
        _ => 0.0,
    }
}

pub(super) fn material_slider_f32(
    ui: &mut Ui,
    session: &mut Session,
    label: &str,
    target: SliderTarget,
    range: std::ops::RangeInclusive<f32>,
    digits: usize,
) {
    let mut shown = material_shown(session, target);
    ui.horizontal(|ui| {
        ui.add_sized(
            [96.0, 16.0],
            egui::Label::new(RichText::new(label).small().color(DIM)),
        );
        let resp = ui.add(Slider::new(&mut shown, range.clone()).show_value(false));
        note_slider(
            session,
            label,
            target,
            resp.rect,
            *range.start(),
            *range.end(),
        );
        if resp.changed() {
            session.begin_edit();
            session.write_slider(target, shown);
        }
        if resp.drag_stopped() || (resp.changed() && !resp.dragged()) {
            session.end_edit();
        }
        ui.monospace(format!("{shown:.digits$}"));
    });
}

pub(super) fn material_slider_i32(
    ui: &mut Ui,
    session: &mut Session,
    label: &str,
    target: SliderTarget,
    range: std::ops::RangeInclusive<i32>,
) {
    let mut shown = material_shown(session, target).round() as i32;
    ui.horizontal(|ui| {
        ui.add_sized(
            [96.0, 16.0],
            egui::Label::new(RichText::new(label).small().color(DIM)),
        );
        let resp = ui.add(Slider::new(&mut shown, range.clone()).show_value(false));
        note_slider(
            session,
            label,
            target,
            resp.rect,
            *range.start() as f32,
            *range.end() as f32,
        );
        if resp.changed() {
            session.begin_edit();
            session.write_slider(target, shown as f32);
        }
        if resp.drag_stopped() || (resp.changed() && !resp.dragged()) {
            session.end_edit();
        }
        ui.monospace(format!("{shown}"));
    });
}

mod outliner;
mod palette;
mod render;
mod script;
mod tools;
