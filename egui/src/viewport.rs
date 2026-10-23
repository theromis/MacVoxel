//! Voxel viewport. The mesh is drawn by wgpu into a texture; egui shows that
//! texture and the HUD on top. Picking still uses the CPU ray, with the same
//! camera the shader uses.

use std::sync::{Arc, Mutex};

use glam::{Mat4, Vec3, Vec4};

use crate::gpu::{self, SceneGpu, SharedGpu};
use crate::state::{EditorMode, RenderMode, Session};

pub struct ViewCache {
    gpu: Option<SharedGpu>,
    texture: Option<egui::TextureId>,
}

impl ViewCache {
    pub fn new() -> Self {
        Self {
            gpu: None,
            texture: None,
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
) {
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
    let aim = hover.or_else(|| {
        pointer
            .hover_pos()
            .filter(|_| pointer.button_down(egui::PointerButton::Primary))
    });
    let ray = aim.map(|p| ray_through(session, rect, p));
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
    );

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

    if matches!(session.hover, Some(_)) && session.tool == crate::state::Tool::Brush {
        ctx.set_cursor_icon(egui::CursorIcon::Crosshair);
    }
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
