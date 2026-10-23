//! Side panels. The layout matches the SwiftUI shell: tools and palette
//! on the left, scene and render settings on the right.

use egui::{Color32, RichText, Slider, Ui};

use crate::state::*;

const DIM: Color32 = Color32::from_rgb(150, 150, 156);

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
    ui.label(
        RichText::new(title.to_ascii_uppercase())
            .small()
            .strong()
            .color(DIM),
    );
}

fn segment<T: PartialEq + Copy>(ui: &mut Ui, value: &mut T, opts: &[(&str, T)]) {
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 2.0;
        for (name, v) in opts {
            ui.selectable_value(value, *v, *name);
        }
    });
}

fn slider_i32(ui: &mut Ui, label: &str, value: &mut i32, range: std::ops::RangeInclusive<i32>) {
    ui.horizontal(|ui| {
        ui.add_sized(
            [96.0, 16.0],
            egui::Label::new(RichText::new(label).small().color(DIM)),
        );
        ui.add(Slider::new(value, range).show_value(false));
        ui.monospace(format!("{value}"));
    });
}

fn slider_f32(
    ui: &mut Ui,
    label: &str,
    value: &mut f32,
    range: std::ops::RangeInclusive<f32>,
    digits: usize,
) {
    ui.horizontal(|ui| {
        ui.add_sized(
            [96.0, 16.0],
            egui::Label::new(RichText::new(label).small().color(DIM)),
        );
        ui.add(Slider::new(value, range).show_value(false));
        ui.monospace(format!("{value:.digits$}"));
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
        slider_i32(ui, "Size", &mut session.brush_size, 1..=63);
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
        ui.label(
            RichText::new(summary)
                .small()
                .monospace()
                .color(Color32::from_gray(120)),
        );
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
            slider_i32(ui, "Slot", &mut session.foliage_seed, 1..=255);
            session.foliage_seed = session.foliage_seed.clamp(1, 255);
            if ui.button("Use active palette slot").clicked() {
                session.foliage_seed = session.active_slot as i32;
            }
            slider_f32(ui, "Density", &mut session.foliage_density, 0.0..=1.0, 2);
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
                    .color(Color32::from_gray(120)),
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
            slider_f32(ui, "Tube", &mut session.torus_tube, 0.05..=1.0, 2);
        }
        GeneratorKind::Perlin => {
            slider_f32(ui, "Scale", &mut session.noise_scale, 1.0..=64.0, 1);
            slider_f32(ui, "Threshold", &mut session.noise_threshold, 0.0..=1.0, 2);
            slider_i32(ui, "Octaves", &mut session.noise_octaves, 1..=6);
            slider_i32(ui, "Seed", &mut session.noise_seed, 0..=9999);
            slider_i32(ui, "Palette lo", &mut session.perlin_lo, 1..=255);
            slider_i32(ui, "Palette hi", &mut session.perlin_hi, 1..=255);
        }
        GeneratorKind::Tree => {
            axis_row(ui, &mut session.gen_axis);
            slider_i32(ui, "Depth", &mut session.tree_depth, 1..=5);
            slider_f32(ui, "Wildness", &mut session.tree_wildness, 0.0..=1.0, 2);
            slider_f32(ui, "Trunk", &mut session.tree_trunk, 0.20..=1.50, 2);
            slider_i32(ui, "Leaf color", &mut session.tree_leaf, 1..=255);
            slider_i32(ui, "Seed", &mut session.tree_seed, 0..=9999);
        }
        GeneratorKind::Helix => {
            axis_row(ui, &mut session.gen_axis);
            slider_f32(ui, "Turns", &mut session.helix_turns, 0.25..=12.0, 2);
            slider_f32(ui, "Radius", &mut session.helix_radius, 0.0..=1.0, 2);
            slider_f32(ui, "Tube", &mut session.helix_tube, 0.02..=0.90, 2);
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
            slider_i32(ui, "Tiers", &mut session.conifer_tiers, 2..=5);
            slider_f32(ui, "Raggedness", &mut session.conifer_ragged, 0.0..=1.0, 2);
            slider_f32(ui, "Clump", &mut session.conifer_clump, 2.0..=24.0, 1);
            slider_f32(ui, "Trunk", &mut session.conifer_trunk, 0.20..=1.50, 2);
            slider_f32(ui, "Crown", &mut session.conifer_crown, 0.0..=1.0, 2);
            slider_i32(ui, "Needle", &mut session.conifer_needle, 1..=255);
            slider_i32(ui, "Seed", &mut session.conifer_seed, 0..=9999);
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
        if ui.color_edit_button_srgb(&mut rgb).changed() {
            session.set_color(session.active_slot, rgb);
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
        let selected = i == session.selected;
        let name = session.objects[i].name.clone();
        let resp = ui.selectable_label(selected, name.clone());
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
        if selected {
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
            ui.monospace(format!("{x} × {y} × {z}"));
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
    slider_i32(ui, "Samples", &mut session.max_samples, 16..=8192);
    section(ui, "Camera");
    ui.checkbox(&mut session.aces, "ACES tonemap");
    ui.checkbox(&mut session.denoise, "Denoise (OIDN)");
    slider_f32(ui, "Aperture", &mut session.aperture, 0.0..=3.0, 2);
    ui.add_enabled_ui(session.aperture > 0.0, |ui| {
        slider_f32(ui, "Focus", &mut session.focus_distance, 1.0..=500.0, 0);
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
            .color(Color32::from_gray(120)),
    );
    let mat = session.material_mut();
    egui::ComboBox::from_id_salt("material")
        .selected_text(mat.ty.name())
        .show_ui(ui, |ui| {
            ui.selectable_value(&mut mat.ty, MaterialType::Diffuse, "Diffuse");
            ui.selectable_value(&mut mat.ty, MaterialType::Metal, "Metal");
            ui.selectable_value(&mut mat.ty, MaterialType::Emissive, "Emissive");
            ui.selectable_value(&mut mat.ty, MaterialType::Glass, "Glass");
        });
    let ty = session.materials[session.active_slot as usize].ty;
    match ty {
        MaterialType::Diffuse => {}
        MaterialType::Metal => {
            slider_f32(
                ui,
                "Roughness",
                &mut session.material_mut().roughness,
                0.0..=1.0,
                2,
            );
            slider_f32(
                ui,
                "Metallic",
                &mut session.material_mut().metallic,
                0.0..=1.0,
                2,
            );
        }
        MaterialType::Glass => {
            slider_f32(
                ui,
                "Roughness",
                &mut session.material_mut().roughness,
                0.0..=1.0,
                2,
            );
            slider_f32(
                ui,
                "Transparency",
                &mut session.material_mut().transparency,
                0.0..=1.0,
                2,
            );
            slider_f32(ui, "IoR", &mut session.material_mut().ior, 1.0..=3.0, 2);
        }
        MaterialType::Emissive => {
            let mut shown = session.materials[session.active_slot as usize].emission * 100.0;
            slider_f32(ui, "Emission", &mut shown, 0.0..=100.0, 0);
            session.material_mut().emission = shown / 100.0;
            slider_i32(
                ui,
                "Power",
                &mut session.material_mut().emission_power,
                1..=5,
            );
        }
    }
}

fn light(ui: &mut Ui, session: &mut Session) {
    section(ui, "Path tracer");
    slider_i32(ui, "Bounces", &mut session.max_bounces, 1..=8);
    ui.add_enabled_ui(session.stochastic_gi, |ui| {
        ui.checkbox(&mut session.power_weighted_nee, "Power-weighted NEE");
        slider_i32(ui, "RIS samples", &mut session.nee_ris, 1..=32);
    });
    slider_f32(
        ui,
        "Indirect clamp",
        &mut session.indirect_clamp,
        0.0..=32.0,
        1,
    );
    slider_f32(ui, "Temporal smooth", &mut session.ema_floor, 0.0..=1.0, 3);

    section(ui, "Sky");
    ui.checkbox(&mut session.atmospheric_sky, "Atmospheric sky");
    ui.add_enabled_ui(!session.atmospheric_sky, |ui| {
        slider_f32(ui, "Intensity", &mut session.sky_intensity, 0.0..=4.0, 2);
    });
    slider_f32(ui, "Horizon", &mut session.horizon_softness, 0.0..=15.0, 1);

    section(ui, "Sun");
    slider_f32(ui, "Elevation", &mut session.sun_elevation, -90.0..=90.0, 0);
    slider_f32(ui, "Azimuth", &mut session.sun_azimuth, 0.0..=360.0, 0);
    slider_f32(ui, "Disc size", &mut session.sun_disc, 0.1..=30.0, 1);
    slider_f32(ui, "Intensity", &mut session.sun_intensity, 0.0..=10.0, 2);
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
    ui.add_enabled_ui(enabled, |ui| {
        section(ui, "Rotate 90°");
        axis_buttons(ui, "CCW", |axis| session.rotate_selection(axis, false));
        ui.label(
            RichText::new("CCW (right-hand rule)")
                .small()
                .color(Color32::from_gray(120)),
        );
        axis_buttons(ui, "CW", |axis| session.rotate_selection(axis, true));
        ui.label(RichText::new("CW").small().color(Color32::from_gray(120)));
        ui.separator();
        section(ui, "Flip");
        axis_buttons(ui, "Flip", |axis| session.flip_selection(axis));
        let scope = if session.picked.is_empty() {
            "Whole object"
        } else {
            "Selection"
        };
        ui.label(
            RichText::new(format!("{scope} · {} selected", session.picked.len()))
                .small()
                .color(Color32::from_gray(120)),
        );
        ui.label(
            RichText::new("⌘-drag moves it. Paste lands on the hovered face.")
                .small()
                .color(Color32::from_gray(120)),
        );
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
