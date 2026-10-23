//! Voxel viewport. The mesh is drawn by wgpu into a texture; egui shows that
//! texture and the HUD on top. Picking still uses the CPU ray, with the same
//! camera the shader uses.

use std::sync::{Arc, Mutex};

use glam::{Mat4, Vec3, Vec4};

use crate::gpu::{self, SceneGpu, SharedGpu};
use crate::state::{Cell, EditorMode, LineMode, RenderMode, Session, Tool, ToolDrag};

pub struct ViewCache {
    gpu: Option<SharedGpu>,
    texture: Option<egui::TextureId>,
    anchor: Option<egui::Pos2>,
}

impl ViewCache {
    pub fn new() -> Self {
        Self {
            gpu: None,
            texture: None,
            anchor: None,
        }
    }

    fn ensure(&mut self, rs: &eframe::egui_wgpu::RenderState) {
        if self.gpu.is_some() {
            return;
        }
        let scene = SceneGpu::new(&rs.device);
        let view = scene.color_texture().create_view(&Default::default());
        let id = rs.renderer.write().register_native_texture(
            &rs.device,
            &view,
            eframe::wgpu::FilterMode::Linear,
        );
        let shared = Arc::new(Mutex::new(scene));
        rs.renderer
            .write()
            .callback_resources
            .insert(shared.clone());
        self.gpu = Some(shared);
        self.texture = Some(id);
    }
}

pub fn show(
    ctx: &egui::Context,
    ui: &mut egui::Ui,
    render_state: Option<&eframe::egui_wgpu::RenderState>,
    session: &mut Session,
    cache: &mut ViewCache,
) -> egui::Rect {
    let rect = ui.available_rect_before_wrap();
    ui.allocate_rect(rect, egui::Sense::click_and_drag());

    let left =
        egui::Rect::from_min_size(rect.min + egui::vec2(10.0, 10.0), egui::vec2(168.0, 32.0));
    let right = egui::Rect::from_min_size(
        egui::pos2(rect.right() - 178.0, rect.top() + 10.0),
        egui::vec2(168.0, 32.0),
    );
    let pointer = ctx.input(|i| i.pointer.clone());
    let on_hud = pointer
        .hover_pos()
        .is_some_and(|p| left.contains(p) || right.contains(p));
    let hover = pointer.hover_pos().filter(|p| rect.contains(*p) && !on_hud);
    let space = ctx.input(|i| i.key_down(egui::Key::Space));
    let scroll = if hover.is_some() {
        ctx.input(|i| i.smooth_scroll_delta.y)
    } else {
        0.0
    };
    // Keep casting while a stroke is dragged past the widget edge.
    // A fast drag can arrive as press plus release, with the end position
    // only on the release frame. Keep aiming at that position.
    let aiming = pointer.button_down(egui::PointerButton::Primary)
        || pointer.button_released(egui::PointerButton::Primary);
    let aim = hover.or_else(|| pointer.latest_pos().filter(|_| aiming));
    let ray = aim.map(|p| ray_through(session, rect, p));
    if pointer.button_pressed(egui::PointerButton::Primary) && hover.is_some() {
        cache.anchor = hover;
    }
    let drag = tool_drag(session, rect, cache.anchor, aim);
    session.pointer(
        hover.is_some(),
        pointer.button_down(egui::PointerButton::Primary),
        pointer.button_pressed(egui::PointerButton::Primary) && hover.is_some(),
        pointer.button_released(egui::PointerButton::Primary),
        pointer.button_down(egui::PointerButton::Secondary),
        pointer.button_pressed(egui::PointerButton::Secondary) && hover.is_some(),
        pointer.button_down(egui::PointerButton::Middle),
        pointer.button_pressed(egui::PointerButton::Middle) && hover.is_some(),
        space,
        glam::Vec2::new(pointer.delta().x, pointer.delta().y),
        scroll,
        ray,
        &drag,
        ctx.input(|i| i.modifiers.command),
    );
    if pointer.button_released(egui::PointerButton::Primary) {
        cache.anchor = None;
    }

    let painter = ui.painter().with_clip_rect(rect);
    if let Some(rs) = render_state {
        cache.ensure(rs);
        if let (Some(gpu), Some(texture)) = (&cache.gpu, cache.texture) {
            let ppp = ctx.pixels_per_point();
            let width = (rect.width() * ppp).round().max(1.0) as u32;
            let height = (rect.height() * ppp).round().max(1.0) as u32;
            let aspect = rect.width() / rect.height().max(1.0);
            let view_proj = gpu_view_proj(session, aspect);
            let mut scene = gpu.lock().expect("voxel viewport");
            if scene.resize(&rs.device, width, height) {
                let texture_handle = scene.color_texture().clone();
                drop(scene);
                let view = texture_handle.create_view(&Default::default());
                rs.renderer.write().update_egui_texture_from_wgpu_texture(
                    &rs.device,
                    &view,
                    eframe::wgpu::FilterMode::Linear,
                    texture,
                );
                scene = gpu.lock().expect("voxel viewport");
            }
            scene.sync(&rs.device, &rs.queue, session, view_proj);
            drop(scene);
            painter.image(
                texture,
                rect,
                egui::Rect::from_min_max(egui::pos2(0.0, 0.0), egui::pos2(1.0, 1.0)),
                egui::Color32::WHITE,
            );
            // prepare() draws the texture before egui samples it. paint() is empty.
            painter.add(gpu::paint_callback(rect));
        }
    } else {
        painter.rect_filled(rect, 0.0, egui::Color32::from_rgb(22, 24, 28));
    }

    if session.tool == Tool::Marquee && pointer.button_down(egui::PointerButton::Primary) {
        if let (Some(a), Some(b)) = (cache.anchor, aim) {
            let band = egui::Rect::from_two_pos(a, b);
            painter.rect_filled(
                band,
                0.0,
                egui::Color32::from_rgba_unmultiplied(255, 220, 80, 28),
            );
            painter.rect_stroke(
                band,
                0.0,
                egui::Stroke::new(1.0_f32, egui::Color32::from_rgb(255, 220, 80)),
                egui::StrokeKind::Inside,
            );
        }
    }

    if session.active().cells.is_empty() {
        painter.text(
            rect.center(),
            egui::Align2::CENTER_CENTER,
            "empty",
            egui::FontId::proportional(14.0),
            egui::Color32::from_gray(140),
        );
    }

    ui.allocate_new_ui(egui::UiBuilder::new().max_rect(left), |ui| {
        hud_frame(ui, |ui| {
            ui.selectable_value(&mut session.editor_mode, EditorMode::Model, "Model");
            ui.selectable_value(&mut session.editor_mode, EditorMode::Object, "Object");
        });
    });
    ui.allocate_new_ui(egui::UiBuilder::new().max_rect(right), |ui| {
        hud_frame(ui, |ui| {
            ui.selectable_value(&mut session.render_mode, RenderMode::Edit, "Edit");
            ui.selectable_value(&mut session.render_mode, RenderMode::Render, "Render");
        });
    });

    if matches!(session.hover, Some(_))
        && matches!(
            session.tool,
            Tool::Brush | Tool::Marquee | Tool::BoxSelect | Tool::FloodSelect
        )
    {
        ctx.set_cursor_icon(egui::CursorIcon::Crosshair);
    }
    rect
}

fn hud_frame(ui: &mut egui::Ui, body: impl FnOnce(&mut egui::Ui)) {
    egui::Frame::NONE
        .fill(egui::Color32::from_black_alpha(170))
        .corner_radius(egui::CornerRadius::same(6))
        .inner_margin(egui::Margin::same(4))
        .show(ui, |ui| {
            ui.horizontal(|ui| body(ui));
            ui.spacing_mut().item_spacing.x = 2.0;
        });
}

/// OpenGL-style projection. The ray caster unprojects with this matrix.
fn projection(aspect: f32) -> Mat4 {
    Mat4::perspective_rh(50_f32.to_radians(), aspect.max(0.05), 0.08, 4000.0)
}

fn view_matrix(session: &Session) -> Mat4 {
    let eye = session.eye();
    let forward = (session.target - eye).normalize_or_zero();
    let up = if forward.dot(Vec3::Z).abs() > 0.95 {
        Vec3::Y
    } else {
        Vec3::Z
    };
    Mat4::look_at_rh(eye, session.target, up)
}

/// Same view as [`projection`], with z mapped into wgpu's 0..1 clip range.
fn gpu_view_proj(session: &Session, aspect: f32) -> Mat4 {
    let clip = Mat4::from_cols(
        Vec4::new(1.0, 0.0, 0.0, 0.0),
        Vec4::new(0.0, 1.0, 0.0, 0.0),
        Vec4::new(0.0, 0.0, 0.5, 0.0),
        Vec4::new(0.0, 0.0, 0.5, 1.0),
    );
    clip * projection(aspect) * view_matrix(session)
}

fn tool_drag(
    session: &Session,
    rect: egui::Rect,
    anchor: Option<egui::Pos2>,
    aim: Option<egui::Pos2>,
) -> ToolDrag {
    let Some(anchor) = anchor else {
        return ToolDrag {
            rays: Vec::new(),
            face_steps: 1,
            marquee: None,
        };
    };
    let Some(aim) = aim else {
        return ToolDrag {
            rays: Vec::new(),
            face_steps: 1,
            marquee: None,
        };
    };
    let face_steps = if let Some((cell, axis, sign)) = session.stroke_face() {
        face_drag_steps(session, rect, anchor, aim, cell, axis, sign)
    } else {
        1
    };
    let rays = if session.tool == Tool::Line && session.line_mode == LineMode::Project {
        sample_rays(session, rect, anchor, aim)
    } else {
        Vec::new()
    };
    let marquee = if session.tool == Tool::Marquee {
        Some(marquee_cells(session, rect, anchor, aim))
    } else {
        None
    };
    ToolDrag {
        rays,
        face_steps,
        marquee,
    }
}

fn marquee_cells(session: &Session, rect: egui::Rect, a: egui::Pos2, b: egui::Pos2) -> Vec<Cell> {
    let min_x = a.x.min(b.x);
    let max_x = a.x.max(b.x);
    let min_y = a.y.min(b.y);
    let max_y = a.y.max(b.y);
    // A click, not a drag, clears the selection.
    if max_x - min_x < 2.0 && max_y - min_y < 2.0 {
        return Vec::new();
    }
    let aspect = rect.width() / rect.height().max(1.0);
    let vp = projection(aspect) * view_matrix(session);
    let mut picked = Vec::new();
    for cell in session.active().cells.keys().copied() {
        let center = Vec3::new(
            cell.0 as f32 + 0.5,
            cell.1 as f32 + 0.5,
            cell.2 as f32 + 0.5,
        );
        let Some(ndc) = to_ndc(vp, center) else {
            continue;
        };
        let sx = rect.min.x + (ndc.x * 0.5 + 0.5) * rect.width();
        let sy = rect.min.y + (1.0 - (ndc.y * 0.5 + 0.5)) * rect.height();
        if sx >= min_x && sx <= max_x && sy >= min_y && sy <= max_y {
            picked.push(cell);
        }
    }
    picked
}

fn sample_rays(
    session: &Session,
    rect: egui::Rect,
    a: egui::Pos2,
    b: egui::Pos2,
) -> Vec<(Vec3, Vec3)> {
    let steps = ((a.x - b.x).abs().max((a.y - b.y).abs()) * 2.0).clamp(1.0, 256.0) as i32;
    let mut rays = Vec::with_capacity(steps as usize + 1);
    for i in 0..=steps {
        let t = i as f32 / steps as f32;
        let p = egui::pos2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
        rays.push(ray_through(session, rect, p));
    }
    rays
}

fn face_drag_steps(
    session: &Session,
    rect: egui::Rect,
    anchor: egui::Pos2,
    aim: egui::Pos2,
    cell: crate::state::Cell,
    axis: i32,
    sign: i32,
) -> i32 {
    let aspect = rect.width() / rect.height().max(1.0);
    let vp = projection(aspect) * view_matrix(session);
    let center = Vec3::new(
        cell.0 as f32 + 0.5,
        cell.1 as f32 + 0.5,
        cell.2 as f32 + 0.5,
    );
    let normal = match axis {
        0 => Vec3::new(sign as f32, 0.0, 0.0),
        1 => Vec3::new(0.0, sign as f32, 0.0),
        _ => Vec3::new(0.0, 0.0, sign as f32),
    };
    let Some(a) = to_ndc(vp, center) else {
        return 1;
    };
    let Some(b) = to_ndc(vp, center + normal) else {
        return 1;
    };
    let dir = b - a;
    let len2 = dir.dot(dir);
    if len2 < 1e-8 {
        return 1;
    }
    let drag = glam::Vec2::new(
        (aim.x - anchor.x) / rect.width().max(1.0) * 2.0,
        -(aim.y - anchor.y) / rect.height().max(1.0) * 2.0,
    );
    ((drag.x * dir.x + drag.y * dir.y) / len2).round() as i32
}

fn to_ndc(vp: Mat4, p: Vec3) -> Option<glam::Vec2> {
    let c = vp * Vec4::new(p.x, p.y, p.z, 1.0);
    if c.w <= 0.05 {
        return None;
    }
    Some(glam::Vec2::new(c.x / c.w, c.y / c.w))
}

fn ray_through(session: &Session, rect: egui::Rect, pos: egui::Pos2) -> (Vec3, Vec3) {
    let aspect = rect.width() / rect.height().max(1.0);
    let inv = (projection(aspect) * view_matrix(session)).inverse();
    let ndc_x = (pos.x - rect.min.x) / rect.width() * 2.0 - 1.0;
    let ndc_y = 1.0 - (pos.y - rect.min.y) / rect.height() * 2.0;
    let unproject = |z: f32| {
        let p = inv * Vec4::new(ndc_x, ndc_y, z, 1.0);
        Vec3::new(p.x, p.y, p.z) / p.w
    };
    let a = unproject(0.0);
    let b = unproject(1.0);
    (a, b - a)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn marquee_contains_the_cell_under_its_projection() {
        let session = Session::new();
        let rect = egui::Rect::from_min_max(egui::pos2(0.0, 0.0), egui::pos2(800.0, 600.0));
        let cell = session.active().cells.keys().copied().next().unwrap();
        let aspect = rect.width() / rect.height();
        let vp = projection(aspect) * view_matrix(&session);
        let center = Vec3::new(
            cell.0 as f32 + 0.5,
            cell.1 as f32 + 0.5,
            cell.2 as f32 + 0.5,
        );
        let ndc = to_ndc(vp, center).unwrap();
        let sx = rect.min.x + (ndc.x * 0.5 + 0.5) * rect.width();
        let sy = rect.min.y + (1.0 - (ndc.y * 0.5 + 0.5)) * rect.height();
        let hit = marquee_cells(
            &session,
            rect,
            egui::pos2(sx - 4.0, sy - 4.0),
            egui::pos2(sx + 4.0, sy + 4.0),
        );
        assert!(hit.contains(&cell));
        let click = marquee_cells(&session, rect, egui::pos2(0.0, 0.0), egui::pos2(1.0, 1.0));
        assert!(click.is_empty());
    }
}
