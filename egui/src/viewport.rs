//! Shaded voxel viewport drawn with egui.
//!
//! Faces are projected on the CPU. There is no depth buffer, so front faces
//! are sorted far-to-near. That is enough to judge the shell; it is not the
//! Metal ray-caster.

use glam::{Mat4, Vec3, Vec4};

use crate::state::{Cell, EditorMode, RenderMode, Session};

const FACE_CAP: usize = 80_000;

struct Face {
    p: [Vec3; 4],
    normal: Vec3,
    color: [u8; 3],
}

pub struct ViewCache {
    epoch: u64,
    faces: Vec<Face>,
    capped: bool,
}

impl ViewCache {
    pub fn new() -> Self {
        Self {
            epoch: 0,
            faces: Vec::new(),
            capped: false,
        }
    }

    fn rebuild(&mut self, session: &Session) {
        self.epoch = session.mesh_epoch;
        self.faces.clear();
        self.capped = false;
        let cells = &session.active().cells;
        for (&(x, y, z), &slot) in cells {
            let color = session.color(slot);
            for face in 0..6 {
                let (dx, dy, dz) = OFFSETS[face];
                if cells.contains_key(&(x + dx, y + dy, z + dz)) {
                    continue;
                }
                if self.faces.len() >= FACE_CAP {
                    self.capped = true;
                    return;
                }
                self.faces.push(quad(x, y, z, face, color));
            }
        }
        if let Some((min, max)) = session.bounds() {
            push_grid(&mut self.faces, min, max);
        }
    }
}

pub fn show(ctx: &egui::Context, ui: &mut egui::Ui, session: &mut Session, cache: &mut ViewCache) {
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

    if cache.epoch != session.mesh_epoch {
        cache.rebuild(session);
    }

    let painter = ui.painter().with_clip_rect(rect);
    painter.rect_filled(rect, 0.0, egui::Color32::from_rgb(22, 24, 28));
    paint_faces(&painter, rect, session, &cache.faces);

    if session.active().cells.is_empty() {
        painter.text(
            rect.center(),
            egui::Align2::CENTER_CENTER,
            "empty",
            egui::FontId::proportional(14.0),
            egui::Color32::from_gray(140),
        );
    }
    if cache.capped {
        painter.text(
            rect.center_top() + egui::vec2(0.0, 36.0),
            egui::Align2::CENTER_TOP,
            "Preview mesh is capped. The volume itself is still loaded.",
            egui::FontId::proportional(12.0),
            egui::Color32::from_gray(170),
        );
    }

    // After the mesh, so the switches stay above the voxels.
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

fn paint_faces(painter: &egui::Painter, rect: egui::Rect, session: &Session, faces: &[Face]) {
    if rect.width() < 2.0 || rect.height() < 2.0 {
        return;
    }
    let eye = session.eye();
    let aspect = rect.width() / rect.height();
    let vp = projection(aspect) * view_matrix(session);
    let sun = session.sun_dir();
    let key = (0.45 + session.sun_intensity * 0.35).clamp(0.45, 1.5);

    struct Tri {
        depth: f32,
        v: [egui::epaint::Vertex; 3],
    }
    let mut tris = Vec::with_capacity(faces.len() * 2);
    for face in faces {
        let centroid = (face.p[0] + face.p[1] + face.p[2] + face.p[3]) * 0.25;
        let to_eye = eye - centroid;
        if face.normal.dot(to_eye) <= 0.0 {
            continue;
        }
        let mut screen = [egui::Pos2::ZERO; 4];
        let mut ok = true;
        for i in 0..4 {
            match project(vp, face.p[i], rect) {
                Some(p) => screen[i] = p,
                None => ok = false,
            }
        }
        if !ok {
            continue;
        }
        let ndl = face.normal.normalize_or_zero().dot(sun).max(0.0);
        let shade = (0.30 + key * ndl + 0.08 * face.normal.z).clamp(0.12, 1.35);
        let color = egui::Color32::from_rgb(
            (face.color[0] as f32 * shade).clamp(0.0, 255.0) as u8,
            (face.color[1] as f32 * shade).clamp(0.0, 255.0) as u8,
            (face.color[2] as f32 * shade).clamp(0.0, 255.0) as u8,
        );
        let depth = to_eye.length_squared();
        let vert = |p: egui::Pos2| egui::epaint::Vertex {
            pos: p,
            uv: egui::epaint::WHITE_UV,
            color,
        };
        tris.push(Tri {
            depth,
            v: [vert(screen[0]), vert(screen[1]), vert(screen[2])],
        });
        tris.push(Tri {
            depth,
            v: [vert(screen[0]), vert(screen[2]), vert(screen[3])],
        });
    }

    if let Some(hit) = session.hover.as_ref() {
        if let Some(face) = highlight_face(hit.cell, hit.normal) {
            let mut screen = [egui::Pos2::ZERO; 4];
            let mut ok = true;
            for i in 0..4 {
                match project(vp, face.p[i], rect) {
                    Some(p) => screen[i] = p,
                    None => ok = false,
                }
            }
            if ok {
                let color = egui::Color32::from_rgb(255, 214, 90);
                let vert = |p: egui::Pos2| egui::epaint::Vertex {
                    pos: p,
                    uv: egui::epaint::WHITE_UV,
                    color,
                };
                // Negative depth sorts last, so the hover face stays visible.
                tris.push(Tri {
                    depth: -1.0,
                    v: [vert(screen[0]), vert(screen[1]), vert(screen[2])],
                });
                tris.push(Tri {
                    depth: -1.0,
                    v: [vert(screen[0]), vert(screen[2]), vert(screen[3])],
                });
            }
        }
    }

    tris.sort_unstable_by(|a, b| b.depth.total_cmp(&a.depth));
    let mut mesh = egui::Mesh::default();
    mesh.vertices.reserve(tris.len() * 3);
    mesh.indices.reserve(tris.len() * 3);
    for tri in tris {
        let base = mesh.vertices.len() as u32;
        mesh.vertices.extend(tri.v);
        mesh.indices.extend([base, base + 1, base + 2]);
    }
    painter.add(egui::Shape::mesh(mesh));
}

fn project(vp: Mat4, p: Vec3, rect: egui::Rect) -> Option<egui::Pos2> {
    let c = vp * Vec4::new(p.x, p.y, p.z, 1.0);
    if c.w <= 0.05 {
        return None;
    }
    let x = c.x / c.w;
    let y = c.y / c.w;
    Some(egui::pos2(
        rect.center().x + x * rect.width() * 0.5,
        rect.center().y - y * rect.height() * 0.5,
    ))
}

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

const OFFSETS: [(i32, i32, i32); 6] = [
    (1, 0, 0),
    (-1, 0, 0),
    (0, 1, 0),
    (0, -1, 0),
    (0, 0, 1),
    (0, 0, -1),
];

const NORMALS: [[f32; 3]; 6] = [
    [1.0, 0.0, 0.0],
    [-1.0, 0.0, 0.0],
    [0.0, 1.0, 0.0],
    [0.0, -1.0, 0.0],
    [0.0, 0.0, 1.0],
    [0.0, 0.0, -1.0],
];

const QUADS: [[[f32; 3]; 4]; 6] = [
    [
        [1.0, 0.0, 0.0],
        [1.0, 1.0, 0.0],
        [1.0, 1.0, 1.0],
        [1.0, 0.0, 1.0],
    ],
    [
        [0.0, 1.0, 0.0],
        [0.0, 0.0, 0.0],
        [0.0, 0.0, 1.0],
        [0.0, 1.0, 1.0],
    ],
    [
        [1.0, 1.0, 0.0],
        [0.0, 1.0, 0.0],
        [0.0, 1.0, 1.0],
        [1.0, 1.0, 1.0],
    ],
    [
        [0.0, 0.0, 0.0],
        [1.0, 0.0, 0.0],
        [1.0, 0.0, 1.0],
        [0.0, 0.0, 1.0],
    ],
    [
        [0.0, 0.0, 1.0],
        [1.0, 0.0, 1.0],
        [1.0, 1.0, 1.0],
        [0.0, 1.0, 1.0],
    ],
    [
        [0.0, 1.0, 0.0],
        [1.0, 1.0, 0.0],
        [1.0, 1.0, 1.0],
        [0.0, 0.0, 1.0],
    ],
];

fn quad(x: i32, y: i32, z: i32, face: usize, color: [u8; 3]) -> Face {
    let o = [x as f32, y as f32, z as f32];
    let mut p = [Vec3::ZERO; 4];
    for i in 0..4 {
        let q = QUADS[face][i];
        p[i] = Vec3::new(o[0] + q[0], o[1] + q[1], o[2] + q[2]);
    }
    let n = NORMALS[face];
    Face {
        p,
        normal: Vec3::new(n[0], n[1], n[2]),
        color,
    }
}

fn highlight_face(cell: Cell, normal: Cell) -> Option<Face> {
    let face = OFFSETS.iter().position(|o| *o == normal)?;
    let mut face = quad(cell.0, cell.1, cell.2, face, [255, 214, 90]);
    let push = face.normal * 0.04;
    for p in &mut face.p {
        *p += push;
    }
    Some(face)
}

fn push_grid(faces: &mut Vec<Face>, min: Cell, max: Cell) {
    if faces.len() + 40 >= FACE_CAP {
        return;
    }
    let z = min.2 as f32;
    let x0 = min.0 as f32 - 2.0;
    let x1 = max.0 as f32 + 3.0;
    let y0 = min.1 as f32 - 2.0;
    let y1 = max.1 as f32 + 3.0;
    let color = [46, 50, 58];
    let steps = 12;
    let dx = (x1 - x0) / steps as f32;
    let dy = (y1 - y0) / steps as f32;
    for i in 0..=steps {
        let x = x0 + dx * i as f32;
        faces.push(grid_line(
            Vec3::new(x, y0, z),
            Vec3::new(x, y1, z),
            true,
            color,
        ));
        let y = y0 + dy * i as f32;
        faces.push(grid_line(
            Vec3::new(x0, y, z),
            Vec3::new(x1, y, z),
            false,
            color,
        ));
    }
}

fn grid_line(a: Vec3, b: Vec3, along_y: bool, color: [u8; 3]) -> Face {
    let w = 0.025;
    let p = if along_y {
        [
            Vec3::new(a.x - w, a.y, a.z),
            Vec3::new(a.x + w, a.y, a.z),
            Vec3::new(b.x + w, b.y, b.z),
            Vec3::new(b.x - w, b.y, b.z),
        ]
    } else {
        [
            Vec3::new(a.x, a.y - w, a.z),
            Vec3::new(a.x, a.y + w, a.z),
            Vec3::new(b.x, b.y + w, b.z),
            Vec3::new(b.x, b.y - w, b.z),
        ]
    };
    Face {
        p,
        normal: Vec3::Z,
        color,
    }
}
