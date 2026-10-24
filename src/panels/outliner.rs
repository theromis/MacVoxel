//! Bones and the object outliner.

use egui::{RichText, Ui};

use super::*;

pub(super) fn bones(ui: &mut Ui, session: &mut Session) {
    section(ui, "Bones");
    let names: Vec<String> = session
        .skeleton
        .bones
        .iter()
        .map(|bone| bone.name.clone())
        .collect();
    if ui.button("Add").clicked() {
        let name = session.fresh_bone_name();
        let parent = session
            .selected_bone
            .and_then(|index| names.get(index).cloned());
        let pivot = session.active_bone_pivot();
        if let Err(err) = session.add_bone(&name, parent.as_deref(), pivot, None) {
            session.status = err;
        }
    }
    let mut pick = None;
    for (index, name) in names.iter().enumerate() {
        if ui
            .selectable_label(session.selected_bone == Some(index), name)
            .clicked()
        {
            pick = Some(index);
        }
    }
    if let Some(index) = pick {
        session.selected_bone = Some(index);
    }
    if let Some(index) = session.selected_bone {
        if index < session.skeleton.bones.len() {
            bone_fields(ui, session, index);
        } else {
            session.selected_bone = None;
        }
    }
    bind_object(ui, session);
}

pub(super) fn bone_fields(ui: &mut Ui, session: &mut Session, index: usize) {
    let current = session.skeleton.bones[index].name.clone();
    let mut text = current.clone();
    if ui
        .add(
            egui::TextEdit::singleline(&mut text)
                .desired_width(160.0)
                .hint_text("Rename"),
        )
        .changed()
        && text != current
    {
        if let Err(err) = session.set_bone(&current, None, None, None, Some(text.trim())) {
            session.status = err;
        }
    }
    let parent = session.skeleton.bones[index].parent.clone();
    let bone_name = session.skeleton.bones[index].name.clone();
    let names: Vec<String> = session
        .skeleton
        .bones
        .iter()
        .map(|bone| bone.name.clone())
        .collect();
    let mut next_parent = parent.clone();
    let mut parent_changed = false;
    egui::ComboBox::from_id_salt("bone-parent")
        .selected_text(parent.as_deref().unwrap_or("Root"))
        .show_ui(ui, |ui| {
            if ui.selectable_label(parent.is_none(), "Root").clicked() {
                next_parent = None;
                parent_changed = true;
            }
            for name in &names {
                if !session.skeleton.accepts_parent(&bone_name, name) {
                    continue;
                }
                if ui
                    .selectable_label(parent.as_deref() == Some(name.as_str()), name)
                    .clicked()
                {
                    next_parent = Some(name.clone());
                    parent_changed = true;
                }
            }
        });
    if parent_changed && next_parent != parent {
        if let Err(err) = session.set_bone(&bone_name, Some(next_parent), None, None, None) {
            session.status = err;
        }
    }
    let pivot = session
        .skeleton
        .bones
        .get(index)
        .map(|bone| bone.pivot)
        .unwrap_or([0.0; 3]);
    ui.horizontal(|ui| {
        ui.label("Pivot");
        for axis in 0..3 {
            let mut value = pivot[axis];
            let prefix = match axis {
                0 => "x ",
                1 => "y ",
                _ => "z ",
            };
            let response = ui.add(egui::DragValue::new(&mut value).speed(0.05).prefix(prefix));
            if response.changed() {
                session.preview_bone_pivot(index, axis, value);
            }
            if response.drag_stopped() || (response.changed() && !response.dragged()) {
                session.finish_bone_edit();
            }
        }
    });
    let rotation = session.skeleton.bones[index].rotation;
    let (turned, started) = angle_row(ui, "Rotation", rotation);
    if started {
        session.begin_gesture();
    }
    if let Some(rotation) = turned {
        if let Err(err) = session.set_bone(&bone_name, None, None, Some(rotation), None) {
            session.status = err;
        }
    }
    if ui.button("Delete").clicked() {
        let name = session
            .skeleton
            .bones
            .get(index)
            .map(|bone| bone.name.clone())
            .unwrap_or(bone_name);
        if let Err(err) = session.remove_bone(&name) {
            session.status = err;
        }
    }
}

pub(super) fn bind_object(ui: &mut Ui, session: &mut Session) {
    let names: Vec<String> = session
        .skeleton
        .bones
        .iter()
        .map(|bone| bone.name.clone())
        .collect();
    let current = session
        .objects
        .get(session.selected)
        .and_then(|object| object.bone.clone());
    let mut next = current.clone();
    let mut changed = false;
    ui.horizontal(|ui| {
        ui.label("Bind");
        egui::ComboBox::from_id_salt("object-bone")
            .selected_text(current.as_deref().unwrap_or("None"))
            .show_ui(ui, |ui| {
                if ui.selectable_label(current.is_none(), "None").clicked() {
                    next = None;
                    changed = true;
                }
                for name in &names {
                    if ui
                        .selectable_label(current.as_deref() == Some(name.as_str()), name)
                        .clicked()
                    {
                        next = Some(name.clone());
                        changed = true;
                    }
                }
            });
    });
    if changed && next != current {
        let index = session.selected;
        if let Err(err) = session.bind_object(index, next.as_deref()) {
            session.status = err;
        }
    }
}

pub(super) fn outliner(ui: &mut Ui, session: &mut Session) {
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
        let resp = ui
            .horizontal(|ui| {
                let hidden = session.objects[i].hidden;
                action_checkbox(
                    ui,
                    session,
                    &format!("object.visible.{i}"),
                    "",
                    !hidden,
                    UiAction::ObjectHidden(i),
                );
                ui.selectable_label(chosen, label)
            })
            .inner;
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
    let at = session.active().translation;
    let mut position = [at.0, at.1, at.2];
    let mut moved = false;
    ui.horizontal(|ui| {
        ui.label(RichText::new("Position").small().color(DIM));
        for value in &mut position {
            let response = ui.add(
                egui::DragValue::new(value)
                    .range(-1024..=1023)
                    .speed(0.2),
            );
            if response.drag_started() {
                session.begin_gesture();
            }
            moved |= response.changed();
        }
    });
    if moved {
        let index = session.selected;
        if let Err(err) = session.set_object(index, None, Some(position), None) {
            session.status = err;
        }
    }
    ui.horizontal(|ui| {
        ui.label(RichText::new("Mirror").small().color(DIM));
        for (axis, name) in ["X", "Y", "Z"].into_iter().enumerate() {
            action_button(
                ui,
                session,
                &format!("object.mirror.{}", name.to_ascii_lowercase()),
                name,
                UiAction::Mirror(axis),
            );
        }
        let bones = session.mirror_bones;
        action_checkbox(
            ui,
            session,
            "object.mirror-bones",
            "Bones",
            bones,
            UiAction::MirrorBones,
        );
    });
}

/// Three angle fields, in degrees, for a quaternion `[x, y, z, w]`. Returns
/// the new rotation when a field changed, and whether a drag began.
fn angle_row(ui: &mut Ui, label: &str, rotation: [f32; 4]) -> (Option<[f32; 4]>, bool) {
    let (x, y, z) = glam::Quat::from_array(rotation)
        .normalize()
        .to_euler(glam::EulerRot::XYZ);
    // `+ 0.0` turns -0 into 0, so a still bone does not read "-0°".
    let mut angles = [x, y, z].map(|angle| angle.to_degrees() + 0.0);
    let mut changed = false;
    let mut started = false;
    ui.horizontal(|ui| {
        ui.label(label);
        for (angle, prefix) in angles.iter_mut().zip(["x ", "y ", "z "]) {
            let response = ui.add(
                egui::DragValue::new(angle)
                    .range(-180.0..=180.0)
                    .speed(0.5)
                    .max_decimals(1)
                    .prefix(prefix)
                    .suffix("°"),
            );
            started |= response.drag_started();
            changed |= response.changed();
        }
    });
    let next = changed.then(|| {
        let [x, y, z] = angles.map(f32::to_radians);
        glam::Quat::from_euler(glam::EulerRot::XYZ, x, y, z)
            .normalize()
            .to_array()
    });
    (next, started)
}

/// Preview pose of the selected bone: a turn and a scale on top of the bind
/// pose, the same as `set_pose`.
pub(super) fn pose(ui: &mut Ui, session: &mut Session) {
    section(ui, "Pose");
    let selected = session
        .selected_bone
        .filter(|index| *index < session.skeleton.bones.len());
    if let Some(index) = selected {
        let name = session.skeleton.bones[index].name.clone();
        let extra = session
            .pose
            .get(&name)
            .copied()
            .unwrap_or(crate::rig::BonePose::IDENTITY);
        let (turned, mut started) = angle_row(ui, "Turn", extra.rotation);
        let mut scale = extra.scale;
        let mut scaled = false;
        ui.horizontal(|ui| {
            ui.label("Scale");
            for (value, prefix) in scale.iter_mut().zip(["x ", "y ", "z "]) {
                let response = ui.add(
                    egui::DragValue::new(value)
                        .range(0.0..=16.0)
                        .speed(0.01)
                        .max_decimals(2)
                        .prefix(prefix),
                );
                started |= response.drag_started();
                scaled |= response.changed();
            }
        });
        if started {
            session.begin_gesture();
        }
        if turned.is_some() || scaled {
            let next = crate::rig::BonePose {
                rotation: turned.unwrap_or(extra.rotation),
                scale,
            };
            if let Err(err) = session.set_bone_pose(index, next) {
                session.status = err;
            }
        }
        if ui.button("Reset bone").clicked() {
            if let Err(err) = session.set_bone_pose(index, crate::rig::BonePose::IDENTITY) {
                session.status = err;
            }
        }
    } else {
        ui.label(RichText::new("Select a bone to pose it.").small().color(DIM));
    }
    ui.add_enabled_ui(!session.pose.is_empty(), |ui| {
        action_button(ui, session, "pose.clear", "Clear pose", UiAction::ClearPose);
    });
}

/// Animation clips: add, delete, and key the current pose at a time.
pub(super) fn clips(ui: &mut Ui, session: &mut Session) {
    section(ui, "Clips");
    let mut pick = None;
    for (index, clip) in session.clips.iter().enumerate() {
        let keys: usize = clip.tracks.iter().map(|track| track.keys.len()).sum();
        let bones = clip.tracks.len();
        let label = format!(
            "{}  ·  {bones} {}, {keys} {}",
            clip.name,
            if bones == 1 { "bone" } else { "bones" },
            if keys == 1 { "key" } else { "keys" },
        );
        if ui
            .selectable_label(session.selected_clip == Some(index), label)
            .clicked()
        {
            pick = Some(index);
        }
    }
    if let Some(index) = pick {
        session.selected_clip = Some(index);
    }
    ui.horizontal(|ui| {
        ui.add(
            egui::TextEdit::singleline(&mut session.clip_draft)
                .desired_width(120.0)
                .hint_text("New clip"),
        );
        action_button(ui, session, "clip.add", "Add", UiAction::AddClip);
    });
    let Some(index) = session
        .selected_clip
        .filter(|index| *index < session.clips.len())
    else {
        session.selected_clip = None;
        return;
    };
    for track in &session.clips[index].tracks {
        let times: Vec<String> = track
            .keys
            .iter()
            .map(|key| format!("{:.2}", key.time))
            .collect();
        ui.label(
            RichText::new(format!("{}: {}", track.bone, times.join(" ")))
                .small()
                .monospace()
                .color(DIM),
        );
    }
    ui.horizontal(|ui| {
        ui.label("Time");
        ui.add(
            egui::DragValue::new(&mut session.clip_time)
                .range(0.0..=600.0)
                .speed(0.05)
                .max_decimals(2)
                .suffix(" s"),
        );
        action_button(ui, session, "clip.key", "Key pose", UiAction::KeyPose);
        action_button(ui, session, "clip.delete", "Delete", UiAction::RemoveClip);
    });
}
