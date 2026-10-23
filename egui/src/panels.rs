//! Side panels. The layout matches the SwiftUI shell: tools and palette
//! on the left, scene and render settings on the right.

use egui::{Color32, RichText, Slider, Ui};

use crate::state::*;

/// Secondary labels. Light enough to read on the blue-gray panel
/// (`#2c333e`), still quieter than the primary text.
const DIM: Color32 = Color32::from_rgb(196, 206, 220);

pub fn left(ui: &mut Ui, session: &mut Session) {
    tools(ui, session);
    ui.separator();
    palette(ui, session);
}

pub fn right(ui: &mut Ui, session: &mut Session) {
    outliner(ui, session);
    ui.separator();
    document(ui, session);
    ui.separator();
    render(ui, session);
    ui.separator();
    light(ui, session);
    ui.separator();
    selection(ui, session);
}

fn section(ui: &mut Ui, title: &str) {
    ui.add_space(4.0);
    ui.label(RichText::new(title.to_ascii_uppercase()).small().strong());
}

fn segment<T: PartialEq + Copy>(ui: &mut Ui, value: &mut T, opts: &[(&str, T)]) {
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 2.0;
        for (name, v) in opts {
            ui.selectable_value(value, *v, *name);
        }
    });
}

fn slider_i32(
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

fn slider_f32(
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

fn slider_value(session: &Session, target: SliderTarget) -> f32 {
    match target {
        SliderTarget::BrushSize => session.brush_size as f32,
        SliderTarget::FoliageSeed => session.foliage_seed as f32,
        SliderTarget::FoliageDensity => session.foliage_density,
        SliderTarget::TorusTube => session.torus_tube,
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
        | SliderTarget::MaterialPower => material_shown(session, target),
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

fn note_slider(
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

fn material_shown(session: &Session, target: SliderTarget) -> f32 {
    let mat = &session.materials[session.active_slot as usize];
    match target {
        SliderTarget::MaterialRoughness => mat.roughness,
        SliderTarget::MaterialMetallic => mat.metallic,
        SliderTarget::MaterialTransparency => mat.transparency,
        SliderTarget::MaterialIor => mat.ior,
        SliderTarget::MaterialEmission => mat.emission * 100.0,
        SliderTarget::MaterialPower => mat.emission_power as f32,
        _ => 0.0,
    }
}

fn material_slider_f32(
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

fn material_slider_i32(
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

fn tools(ui: &mut Ui, session: &mut Session) {
    section(ui, "Tool");
    const TOOLS: [(Tool, &str, &str); 11] = [
        (Tool::Brush, "Brush", "V"),
        (Tool::Line, "Line", "L"),
        (Tool::Circle, "Circle", ""),
        (Tool::Square, "Square", ""),
        (Tool::Box, "Box", "B"),
        (Tool::Face, "Face", "F"),
        (Tool::Generator, "Generator", ""),
        (Tool::Mutator, "Mutator", "U"),
        (Tool::Marquee, "Marquee", "M"),
        (Tool::BoxSelect, "Box Select", ""),
        (Tool::FloodSelect, "Flood", ""),
    ];
    egui::Grid::new("tools")
        .num_columns(2)
        .spacing([4.0, 4.0])
        .show(ui, |ui| {
            for (i, (tool, label, key)) in TOOLS.iter().enumerate() {
                let tip = if key.is_empty() {
                    (*label).to_string()
                } else {
                    format!("{label} ({key})")
                };
                let on = session.tool == *tool;
                let resp = ui
                    .add_sized([86.0, 26.0], egui::Button::new(*label).selected(on))
                    .on_hover_text(tip);
                let rect = resp.rect;
                let clicked = resp.clicked();
                let id = format!("tool.{}", label.to_ascii_lowercase().replace(' ', "-"));
                session.note_ui(&id, label, rect, UiAction::Tool(*tool));
                if clicked {
                    session.tool = *tool;
                }
                if i % 2 == 1 {
                    ui.end_row();
                }
            }
        });

    section(ui, "Mode");
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 2.0;
        for (name, mode) in [
            ("Add", ToolMode::Add),
            ("Remove", ToolMode::Remove),
            ("Paint", ToolMode::Paint),
        ] {
            let resp = ui.selectable_value(&mut session.tool_mode, mode, name);
            let rect = resp.rect;
            session.note_ui(
                &format!("mode.{}", name.to_ascii_lowercase()),
                name,
                rect,
                UiAction::Mode(mode),
            );
        }
    });

    if session.tool != Tool::Face && session.tool != Tool::Generator {
        section(ui, "Brush");
        slider_i32(ui, session, "Size", SliderTarget::BrushSize, 1..=63);
        session.brush_size = session.brush_size.clamp(1, 63);
        segment(
            ui,
            &mut session.brush_shape,
            &[
                ("Square", BrushShape::Square),
                ("Circle", BrushShape::Circle),
            ],
        );
        let mut dim = session.brush_3d;
        ui.horizontal(|ui| {
            if ui.selectable_label(!dim, "2D").clicked() {
                dim = false;
            }
            if ui.selectable_label(dim, "3D").clicked() {
                dim = true;
            }
        });
        session.brush_3d = dim;
        let n = session.brush_cell_count();
        let edge = session.brush_size;
        let summary = if session.brush_3d {
            format!("{edge} × {edge} × {edge}  ({n} cells)")
        } else {
            format!("{edge} × {edge}  ({n} cells, on face plane)")
        };
        ui.label(RichText::new(summary).small().monospace().color(DIM));
    }

    match session.tool {
        Tool::Line => {
            section(ui, "Line");
            segment(
                ui,
                &mut session.line_mode,
                &[
                    ("Straight", LineMode::Straight),
                    ("Project", LineMode::Project),
                ],
            );
        }
        Tool::Circle => {
            section(ui, "Circle");
            ui.horizontal(|ui| {
                ui.toggle_value(&mut session.circle_fill, "Fill");
                ui.toggle_value(&mut session.circle_even, "Even");
            });
        }
        Tool::Square => {
            section(ui, "Square");
            ui.horizontal(|ui| {
                ui.toggle_value(&mut session.square_fill, "Fill");
                ui.toggle_value(&mut session.square_even, "Even");
            });
        }
        Tool::Box => {
            section(ui, "Box");
            ui.toggle_value(&mut session.box_fill, "Fill");
        }
        Tool::Face => {
            section(ui, "Face");
            ui.label(RichText::new("Extrude").small().color(DIM));
            segment(
                ui,
                &mut session.face_extrude,
                &[
                    ("Color", FaceExtrude::Color),
                    ("Geometry", FaceExtrude::Geometry),
                ],
            );
            ui.label(RichText::new("With").small().color(DIM));
            segment(
                ui,
                &mut session.face_with,
                &[
                    ("Geometry", FaceWith::Geometry),
                    ("Palette", FaceWith::Palette),
                ],
            );
            ui.label(RichText::new("Connectivity").small().color(DIM));
            let mut eight = session.face_eight;
            ui.horizontal(|ui| {
                if ui.selectable_label(!eight, "4-side").clicked() {
                    eight = false;
                }
                if ui.selectable_label(eight, "8-side").clicked() {
                    eight = true;
                }
            });
            session.face_eight = eight;
        }
        Tool::Generator => {
            section(ui, "Generator");
            egui::ComboBox::from_id_salt("generator")
                .selected_text(session.generator.name())
                .show_ui(ui, |ui| {
                    for kind in [
                        GeneratorKind::Ellipsoid,
                        GeneratorKind::Cylinder,
                        GeneratorKind::Cone,
                        GeneratorKind::Pyramid,
                        GeneratorKind::Torus,
                        GeneratorKind::Perlin,
                        GeneratorKind::Tree,
                        GeneratorKind::Helix,
                        GeneratorKind::Conifer,
                    ] {
                        ui.selectable_value(&mut session.generator, kind, kind.name());
                    }
                });
            generator(ui, session);
        }
        Tool::Mutator => {
            section(ui, "Mutator");
            ui.add_enabled_ui(false, |ui| {
                let mut foliage = 0;
                egui::ComboBox::from_id_salt("mutator")
                    .selected_text("Foliage")
                    .show_ui(ui, |ui| {
                        ui.selectable_value(&mut foliage, 0, "Foliage");
                    });
            });
            ui.label(RichText::new("Seed color").small().color(DIM));
            slider_i32(ui, session, "Slot", SliderTarget::FoliageSeed, 1..=255);
            session.foliage_seed = session.foliage_seed.clamp(1, 255);
            if ui.button("Use active palette slot").clicked() {
                session.foliage_seed = session.active_slot as i32;
            }
            slider_f32(
                ui,
                session,
                "Density",
                SliderTarget::FoliageDensity,
                0.0..=1.0,
                2,
            );
        }
        _ => {}
    }
}

fn axis_row(ui: &mut Ui, axis: &mut Axis) {
    ui.label(RichText::new("Axis").small().color(DIM));
    segment(ui, axis, &[("X", Axis::X), ("Y", Axis::Y), ("Z", Axis::Z)]);
}

fn generator(ui: &mut Ui, session: &mut Session) {
    match session.generator {
        GeneratorKind::Ellipsoid => {
            ui.label(
                RichText::new("(shape derives from bounds)")
                    .small()
                    .color(DIM),
            );
        }
        GeneratorKind::Cylinder => axis_row(ui, &mut session.gen_axis),
        GeneratorKind::Cone | GeneratorKind::Pyramid => {
            axis_row(ui, &mut session.gen_axis);
            ui.label(RichText::new("Apex at").small().color(DIM));
            let mut max = session.apex_at_max;
            ui.horizontal(|ui| {
                if ui.selectable_label(!max, "Min").clicked() {
                    max = false;
                }
                if ui.selectable_label(max, "Max").clicked() {
                    max = true;
                }
            });
            session.apex_at_max = max;
        }
        GeneratorKind::Torus => {
            axis_row(ui, &mut session.gen_axis);
            slider_f32(ui, session, "Tube", SliderTarget::TorusTube, 0.05..=1.0, 2);
        }
        GeneratorKind::Perlin => {
            slider_f32(
                ui,
                session,
                "Scale",
                SliderTarget::NoiseScale,
                1.0..=64.0,
                1,
            );
            slider_f32(
                ui,
                session,
                "Threshold",
                SliderTarget::NoiseThreshold,
                0.0..=1.0,
                2,
            );
            slider_i32(ui, session, "Octaves", SliderTarget::NoiseOctaves, 1..=6);
            slider_i32(ui, session, "Seed", SliderTarget::NoiseSeed, 0..=9999);
            slider_i32(ui, session, "Palette lo", SliderTarget::PerlinLo, 1..=255);
            slider_i32(ui, session, "Palette hi", SliderTarget::PerlinHi, 1..=255);
        }
        GeneratorKind::Tree => {
            axis_row(ui, &mut session.gen_axis);
            slider_i32(ui, session, "Depth", SliderTarget::TreeDepth, 1..=5);
            slider_f32(
                ui,
                session,
                "Wildness",
                SliderTarget::TreeWildness,
                0.0..=1.0,
                2,
            );
            slider_f32(
                ui,
                session,
                "Trunk",
                SliderTarget::TreeTrunk,
                0.20..=1.50,
                2,
            );
            slider_i32(ui, session, "Leaf color", SliderTarget::TreeLeaf, 1..=255);
            slider_i32(ui, session, "Seed", SliderTarget::TreeSeed, 0..=9999);
        }
        GeneratorKind::Helix => {
            axis_row(ui, &mut session.gen_axis);
            slider_f32(
                ui,
                session,
                "Turns",
                SliderTarget::HelixTurns,
                0.25..=12.0,
                2,
            );
            slider_f32(
                ui,
                session,
                "Radius",
                SliderTarget::HelixRadius,
                0.0..=1.0,
                2,
            );
            slider_f32(ui, session, "Tube", SliderTarget::HelixTube, 0.02..=0.90, 2);
            ui.label(RichText::new("Winding").small().color(DIM));
            let mut cw = session.helix_cw;
            ui.horizontal(|ui| {
                if ui.selectable_label(!cw, "CCW").clicked() {
                    cw = false;
                }
                if ui.selectable_label(cw, "CW").clicked() {
                    cw = true;
                }
            });
            session.helix_cw = cw;
        }
        GeneratorKind::Conifer => {
            axis_row(ui, &mut session.gen_axis);
            slider_i32(ui, session, "Tiers", SliderTarget::ConiferTiers, 2..=5);
            slider_f32(
                ui,
                session,
                "Raggedness",
                SliderTarget::ConiferRagged,
                0.0..=1.0,
                2,
            );
            slider_f32(
                ui,
                session,
                "Clump",
                SliderTarget::ConiferClump,
                2.0..=24.0,
                1,
            );
            slider_f32(
                ui,
                session,
                "Trunk",
                SliderTarget::ConiferTrunk,
                0.20..=1.50,
                2,
            );
            slider_f32(
                ui,
                session,
                "Crown",
                SliderTarget::ConiferCrown,
                0.0..=1.0,
                2,
            );
            slider_i32(ui, session, "Needle", SliderTarget::ConiferNeedle, 1..=255);
            slider_i32(ui, session, "Seed", SliderTarget::ConiferSeed, 0..=9999);
        }
    }
}

fn palette(ui: &mut Ui, session: &mut Session) {
    section(ui, "Palette");
    let cell = 14.0;
    let gap = 2.0;
    let pitch = cell + gap;
    let cols = 8i32;
    let rows = 32i32;
    let w = cols as f32 * cell + (cols - 1) as f32 * gap;
    let h = rows as f32 * cell + (rows - 1) as f32 * gap;
    let (rect, resp) = ui.allocate_exact_size(egui::vec2(w, h), egui::Sense::click_and_drag());
    let painter = ui.painter().with_clip_rect(rect);
    let cell_of = |p: egui::Pos2| -> (i32, i32) {
        let col = ((p.x - rect.min.x) / pitch).floor() as i32;
        let row = ((p.y - rect.min.y) / pitch).floor() as i32;
        (col.clamp(0, cols - 1), row.clamp(0, rows - 1))
    };
    for row in 0..rows {
        for col in 0..cols {
            let slot = crate::state::palette_slot_at(col, row);
            let r = egui::Rect::from_min_size(
                egui::pos2(
                    rect.min.x + col as f32 * pitch,
                    rect.min.y + row as f32 * pitch,
                ),
                egui::vec2(cell, cell),
            );
            if slot == 0 {
                continue;
            }
            let c = session.palette[slot as usize];
            painter.rect_filled(
                r,
                1.0,
                Color32::from_rgba_unmultiplied(c[0], c[1], c[2], c[3]),
            );
            session.note_ui(
                &format!("palette.{slot}"),
                &format!("{slot}"),
                r,
                UiAction::Palette(slot),
            );
            let selected = session.palette_slots.contains(&slot);
            let active = slot == session.active_slot;
            if selected || active {
                painter.rect_stroke(
                    r,
                    1.0,
                    egui::Stroke::new(
                        if active { 1.5_f32 } else { 1.0_f32 },
                        if active {
                            Color32::from_rgb(255, 210, 70)
                        } else {
                            Color32::from_white_alpha(180)
                        },
                    ),
                    egui::StrokeKind::Inside,
                );
            }
        }
    }
    if let Some(((c0, r0), (c1, r1))) = session.palette_drag() {
        let min_c = c0.min(c1);
        let max_c = c0.max(c1);
        let min_r = r0.min(r1);
        let max_r = r0.max(r1);
        let band = egui::Rect::from_min_max(
            egui::pos2(
                rect.min.x + min_c as f32 * pitch,
                rect.min.y + min_r as f32 * pitch,
            ),
            egui::pos2(
                rect.min.x + max_c as f32 * pitch + cell,
                rect.min.y + max_r as f32 * pitch + cell,
            ),
        );
        painter.rect_stroke(
            band,
            0.0,
            egui::Stroke::new(1.5_f32, Color32::from_rgb(255, 220, 80)),
            egui::StrokeKind::Outside,
        );
    }
    if resp.secondary_clicked() {
        if let Some(p) = resp.interact_pointer_pos() {
            let (col, row) = cell_of(p);
            session.note_palette_anchor(crate::state::palette_slot_at(col, row));
        }
    }
    let anchor = session.palette_anchor;
    let can_paste_color = session.has_color_clipboard();
    let voxels = !session.picked.is_empty();
    let count = session.palette_action_count(anchor);
    resp.context_menu(|ui| {
        if ui.button("Copy color").clicked() {
            session.copy_palette_color(anchor);
            ui.close_menu();
        }
        if ui
            .add_enabled(can_paste_color, egui::Button::new("Paste color"))
            .clicked()
        {
            session.paste_palette_color(anchor);
            ui.close_menu();
        }
        ui.separator();
        if ui.button("Select voxels by color").clicked() {
            session.select_voxels_by_color(anchor);
            ui.close_menu();
        }
        if ui
            .add_enabled(
                voxels && count == 1,
                egui::Button::new("Paint voxels with selected color"),
            )
            .clicked()
        {
            session.paint_picked_with_color(anchor);
            ui.close_menu();
        }
        if ui
            .add_enabled(
                voxels && count >= 2,
                egui::Button::new("Paint voxels with random selected colors"),
            )
            .clicked()
        {
            session.paint_picked_with_random_colors(anchor);
            ui.close_menu();
        }
        ui.separator();
        if ui
            .add_enabled(count >= 3, egui::Button::new("Make gradient"))
            .clicked()
        {
            session.make_palette_gradient(anchor);
            ui.close_menu();
        }
    });
    if ui.input(|i| i.pointer.primary_pressed()) && resp.hovered() {
        if let Some(p) = resp.interact_pointer_pos() {
            let shift = ui.input(|i| i.modifiers.shift);
            session.begin_palette_drag(cell_of(p), shift);
        }
    }
    if session.palette_drag().is_some() {
        if let Some(p) = ui.input(|i| i.pointer.interact_pos()) {
            session.update_palette_drag(cell_of(p));
        }
    }
    if session.palette_drag().is_some() && ui.input(|i| i.pointer.primary_released()) {
        if let Some(p) = ui.input(|i| i.pointer.interact_pos()) {
            session.update_palette_drag(cell_of(p));
        }
        session.finish_palette_drag();
    }

    ui.horizontal(|ui| {
        ui.label(RichText::new("Active").small().color(DIM));
        ui.monospace(format!("{}", session.active_slot));
        let mut rgb = session.color(session.active_slot);
        let resp = ui.color_edit_button_srgb(&mut rgb);
        if resp.changed() {
            session.begin_edit();
            session.set_color(session.active_slot, rgb);
        }
        if resp.drag_stopped() || (resp.changed() && !resp.dragged()) {
            session.end_edit();
        }
    });
}

fn outliner(ui: &mut Ui, session: &mut Session) {
    section(ui, "Objects");
    let mut select = None;
    let mut frame = false;
    let mut rename: Option<String> = None;
    let count = session.objects.len();
    for i in 0..count {
        let chosen = session.object_selection.contains(&i);
        let primary = i == session.selected;
        let name = session.objects[i].name.clone();
        let label = if primary {
            RichText::new(name.clone()).strong()
        } else {
            RichText::new(name.clone())
        };
        let resp = ui.selectable_label(chosen, label);
        if resp.clicked() {
            select = Some(i);
        }
        if resp.double_clicked() {
            select = Some(i);
            frame = true;
        }
        resp.context_menu(|ui| {
            if ui.button("Make active").clicked() {
                select = Some(i);
                ui.close_menu();
            }
        });
        if primary {
            let mut text = name.clone();
            // A quiet rename field under the selected row.
            if ui
                .add(
                    egui::TextEdit::singleline(&mut text)
                        .desired_width(160.0)
                        .hint_text("Rename"),
                )
                .changed()
            {
                rename = Some(text);
            }
        }
    }
    if let Some(i) = select {
        session.select_object(i);
    }
    if let Some(name) = rename {
        session.rename_selected(name);
    }
    if frame {
        session.frame_camera();
    }

    ui.horizontal(|ui| {
        let new = ui.button("New");
        let new_rect = new.rect;
        let new_clicked = new.clicked();
        session.note_ui("object.new", "New", new_rect, UiAction::NewObject);
        if new_clicked {
            session.new_object();
        }
        let duplicate = ui.button("Duplicate");
        let duplicate_rect = duplicate.rect;
        let duplicate_clicked = duplicate.clicked();
        session.note_ui(
            "object.duplicate",
            "Duplicate",
            duplicate_rect,
            UiAction::Duplicate,
        );
        if duplicate_clicked {
            session.duplicate_object();
        }
        ui.add_enabled_ui(session.objects.len() > 1, |ui| {
            let delete = ui.button("Delete");
            let delete_rect = delete.rect;
            let delete_clicked = delete.clicked();
            session.note_ui(
                "object.delete",
                "Delete",
                delete_rect,
                UiAction::DeleteObject,
            );
            if delete_clicked {
                session.delete_object();
            }
        });
    });
    ui.horizontal(|ui| {
        ui.label(RichText::new("Size").small().color(DIM));
        if let Some((x, y, z)) = session.size_xyz() {
            for (axis, value) in [(0usize, x), (1, y), (2, z)] {
                let mut next = value;
                ui.add(egui::DragValue::new(&mut next).range(1..=256).speed(0.2));
                if next != value {
                    session.resize_active(axis, next);
                }
            }
        } else {
            ui.monospace("—");
        }
    });
}

fn document(ui: &mut Ui, session: &Session) {
    section(ui, "Document");
    ui.label(RichText::new(session.document_label()).small().color(DIM));
    section(ui, "Statistics");
    if session.voxel_count() == 0 {
        ui.label(RichText::new("empty").color(DIM));
    } else if let Some((x, y, z)) = session.size_xyz() {
        stat(ui, "Voxels", &format_count(session.voxel_count()));
        stat(ui, "Size", &format!("{x} × {y} × {z}"));
    }
}

fn stat(ui: &mut Ui, label: &str, value: &str) {
    ui.horizontal(|ui| {
        ui.add_sized(
            [56.0, 16.0],
            egui::Label::new(RichText::new(label).color(DIM)),
        );
        ui.monospace(value);
    });
}

fn format_count(n: usize) -> String {
    let s = n.to_string();
    let mut out = String::new();
    for (i, ch) in s.chars().rev().enumerate() {
        if i > 0 && i % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }
    out.chars().rev().collect()
}

fn render(ui: &mut Ui, session: &mut Session) {
    section(ui, "Render");
    ui.checkbox(&mut session.stochastic_gi, "Stochastic Sampling GI")
        .on_hover_text("On: area-light sampling at every bounce. Off: emissives are found only by the random walk.");
    ui.horizontal(|ui| {
        ui.add_sized(
            [64.0, 16.0],
            egui::Label::new(RichText::new("Glass").small().color(DIM)),
        );
        egui::ComboBox::from_id_salt("glass")
            .selected_text(match session.glass_mode {
                GlassMode::Probabilistic => "Probabilistic",
                GlassMode::Absorption => "Absorption",
            })
            .show_ui(ui, |ui| {
                ui.selectable_value(
                    &mut session.glass_mode,
                    GlassMode::Probabilistic,
                    "Probabilistic",
                );
                ui.selectable_value(&mut session.glass_mode, GlassMode::Absorption, "Absorption");
            });
    });
    ui.checkbox(
        &mut session.resolution_match_window,
        "Match window resolution",
    );
    ui.add_enabled_ui(!session.resolution_match_window, |ui| {
        ui.horizontal(|ui| {
            ui.add_sized(
                [64.0, 16.0],
                egui::Label::new(RichText::new("Resolution").small().color(DIM)),
            );
            ui.add(egui::DragValue::new(&mut session.render_width).range(16..=16384));
            ui.label("×");
            ui.add(egui::DragValue::new(&mut session.render_height).range(16..=16384));
        });
    });
    slider_i32(ui, session, "Samples", SliderTarget::MaxSamples, 16..=8192);
    section(ui, "Camera");
    ui.checkbox(&mut session.aces, "ACES tonemap");
    ui.checkbox(&mut session.denoise, "Denoise (OIDN)");
    slider_f32(
        ui,
        session,
        "Aperture",
        SliderTarget::Aperture,
        0.0..=3.0,
        2,
    );
    ui.add_enabled_ui(session.aperture > 0.0, |ui| {
        slider_f32(
            ui,
            session,
            "Focus",
            SliderTarget::FocusDistance,
            1.0..=500.0,
            0,
        );
    });
    if ui.button("Save render…").clicked() {
        session.status =
            "Saving a path-traced frame stays in the Metal app. This preview only shades the mesh."
                .into();
    }

    ui.separator();
    section(ui, "Material");
    ui.label(
        RichText::new(format!("Index {}", session.active_slot))
            .small()
            .color(DIM),
    );
    let mut ty = session.materials[session.active_slot as usize].ty;
    let before = ty;
    egui::ComboBox::from_id_salt("material")
        .selected_text(ty.name())
        .show_ui(ui, |ui| {
            ui.selectable_value(&mut ty, MaterialType::Diffuse, "Diffuse");
            ui.selectable_value(&mut ty, MaterialType::Metal, "Metal");
            ui.selectable_value(&mut ty, MaterialType::Emissive, "Emissive");
            ui.selectable_value(&mut ty, MaterialType::Glass, "Glass");
        });
    if ty != before {
        session.begin_edit();
        session.material_mut().ty = ty;
        session.end_edit();
    }
    match ty {
        MaterialType::Diffuse => {}
        MaterialType::Metal => {
            material_slider_f32(
                ui,
                session,
                "Roughness",
                SliderTarget::MaterialRoughness,
                0.0..=1.0,
                2,
            );
            material_slider_f32(
                ui,
                session,
                "Metallic",
                SliderTarget::MaterialMetallic,
                0.0..=1.0,
                2,
            );
        }
        MaterialType::Glass => {
            material_slider_f32(
                ui,
                session,
                "Roughness",
                SliderTarget::MaterialRoughness,
                0.0..=1.0,
                2,
            );
            material_slider_f32(
                ui,
                session,
                "Transparency",
                SliderTarget::MaterialTransparency,
                0.0..=1.0,
                2,
            );
            material_slider_f32(ui, session, "IoR", SliderTarget::MaterialIor, 1.0..=3.0, 2);
        }
        MaterialType::Emissive => {
            material_slider_f32(
                ui,
                session,
                "Emission",
                SliderTarget::MaterialEmission,
                0.0..=100.0,
                0,
            );
            material_slider_i32(ui, session, "Power", SliderTarget::MaterialPower, 1..=5);
        }
    }
}

fn light(ui: &mut Ui, session: &mut Session) {
    section(ui, "Path tracer");
    slider_i32(ui, session, "Bounces", SliderTarget::MaxBounces, 1..=8);
    ui.add_enabled_ui(session.stochastic_gi, |ui| {
        ui.checkbox(&mut session.power_weighted_nee, "Power-weighted NEE");
        slider_i32(ui, session, "RIS samples", SliderTarget::NeeRis, 1..=32);
    });
    slider_f32(
        ui,
        session,
        "Indirect clamp",
        SliderTarget::IndirectClamp,
        0.0..=32.0,
        1,
    );
    slider_f32(
        ui,
        session,
        "Temporal smooth",
        SliderTarget::EmaFloor,
        0.0..=1.0,
        3,
    );

    section(ui, "Sky");
    ui.checkbox(&mut session.atmospheric_sky, "Atmospheric sky");
    ui.add_enabled_ui(!session.atmospheric_sky, |ui| {
        slider_f32(
            ui,
            session,
            "Intensity",
            SliderTarget::SkyIntensity,
            0.0..=4.0,
            2,
        );
    });
    slider_f32(
        ui,
        session,
        "Horizon",
        SliderTarget::HorizonSoftness,
        0.0..=15.0,
        1,
    );

    section(ui, "Sun");
    slider_f32(
        ui,
        session,
        "Elevation",
        SliderTarget::SunElevation,
        -90.0..=90.0,
        0,
    );
    slider_f32(
        ui,
        session,
        "Azimuth",
        SliderTarget::SunAzimuth,
        0.0..=360.0,
        0,
    );
    slider_f32(
        ui,
        session,
        "Disc size",
        SliderTarget::SunDisc,
        0.1..=30.0,
        1,
    );
    slider_f32(
        ui,
        session,
        "Intensity",
        SliderTarget::SunIntensity,
        0.0..=10.0,
        2,
    );
    ui.horizontal(|ui| {
        ui.add_sized(
            [96.0, 16.0],
            egui::Label::new(RichText::new("Color").small().color(DIM)),
        );
        let mut rgb = [
            (session.sun_color[0] * 255.0) as u8,
            (session.sun_color[1] * 255.0) as u8,
            (session.sun_color[2] * 255.0) as u8,
        ];
        if ui.color_edit_button_srgb(&mut rgb).changed() {
            session.sun_color = [
                rgb[0] as f32 / 255.0,
                rgb[1] as f32 / 255.0,
                rgb[2] as f32 / 255.0,
            ];
        }
    });
}

fn selection(ui: &mut Ui, session: &mut Session) {
    let enabled = session.voxel_count() > 0;
    let object = session.editor_mode == EditorMode::Object;
    ui.add_enabled_ui(enabled, |ui| {
        section(ui, "Rotate 90°");
        axis_buttons(ui, "CCW", |axis| {
            if object {
                session.rotate_object(axis, false);
            } else {
                session.rotate_selection(axis, false);
            }
        });
        ui.label(RichText::new("CCW (right-hand rule)").small().color(DIM));
        axis_buttons(ui, "CW", |axis| {
            if object {
                session.rotate_object(axis, true);
            } else {
                session.rotate_selection(axis, true);
            }
        });
        ui.label(RichText::new("CW").small().color(DIM));
        ui.separator();
        section(ui, "Flip");
        axis_buttons(ui, "Flip", |axis| {
            if object {
                session.flip_object(axis);
            } else {
                session.flip_selection(axis);
            }
        });
        let scope = if object || session.picked.is_empty() {
            "Whole object"
        } else {
            "Selection"
        };
        ui.label(
            RichText::new(format!("{scope} · {} selected", session.picked.len()))
                .small()
                .color(DIM),
        );
        let hint = if object {
            "Drag empty space to select. X Y Z rotate the selection. Shift flips."
        } else {
            "⌘-drag moves it. Paste lands on the hovered face."
        };
        ui.label(RichText::new(hint).small().color(DIM));
    });
}

fn axis_buttons(ui: &mut Ui, _which: &str, mut act: impl FnMut(Axis)) {
    ui.horizontal(|ui| {
        if ui.button("X").clicked() {
            act(Axis::X);
        }
        if ui.button("Y").clicked() {
            act(Axis::Y);
        }
        if ui.button("Z").clicked() {
            act(Axis::Z);
        }
    });
}
