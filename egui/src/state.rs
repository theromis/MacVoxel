//! Editor session for the egui preview.
//!
//! Geometry, palette, and panel values live here. The SwiftUI app and the
//! C++ core are not linked: brush strokes edit this in-memory volume so the
//! shell can be tried on its own.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use glam::Vec3;

pub type Cell = (i32, i32, i32);

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Tool {
    Brush,
    Line,
    Circle,
    Square,
    Box,
    Face,
    Generator,
    Mutator,
    Marquee,
    BoxSelect,
    FloodSelect,
}

impl Tool {
    pub fn name(self) -> &'static str {
        match self {
            Tool::Brush => "Brush",
            Tool::Line => "Line",
            Tool::Circle => "Circle",
            Tool::Square => "Square",
            Tool::Box => "Box",
            Tool::Face => "Face",
            Tool::Generator => "Generator",
            Tool::Mutator => "Mutator",
            Tool::Marquee => "Marquee",
            Tool::BoxSelect => "Box Select",
            Tool::FloodSelect => "Flood Select",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum ToolMode {
    Add,
    Remove,
    Paint,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum BrushShape {
    Square,
    Circle,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum LineMode {
    Straight,
    Project,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Axis {
    X,
    Y,
    Z,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum FaceExtrude {
    Color,
    Geometry,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum FaceWith {
    Geometry,
    Palette,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum GeneratorKind {
    Ellipsoid,
    Cylinder,
    Cone,
    Pyramid,
    Torus,
    Perlin,
    Tree,
    Helix,
    Conifer,
}

impl GeneratorKind {
    pub fn name(self) -> &'static str {
        match self {
            GeneratorKind::Ellipsoid => "Ellipsoid",
            GeneratorKind::Cylinder => "Cylinder",
            GeneratorKind::Cone => "Cone",
            GeneratorKind::Pyramid => "Pyramid",
            GeneratorKind::Torus => "Torus",
            GeneratorKind::Perlin => "Perlin",
            GeneratorKind::Tree => "Tree",
            GeneratorKind::Helix => "Helix",
            GeneratorKind::Conifer => "Conifer",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum EditorMode {
    Model,
    Object,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum RenderMode {
    Edit,
    Render,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum GlassMode {
    Probabilistic,
    Absorption,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum MaterialType {
    Diffuse,
    Metal,
    Emissive,
    Glass,
}

impl MaterialType {
    pub fn name(self) -> &'static str {
        match self {
            MaterialType::Diffuse => "Diffuse",
            MaterialType::Metal => "Metal",
            MaterialType::Emissive => "Emissive",
            MaterialType::Glass => "Glass",
        }
    }
}

#[derive(Clone, Copy)]
pub struct Material {
    pub ty: MaterialType,
    pub roughness: f32,
    pub metallic: f32,
    pub emission: f32,
    pub emission_power: i32,
    pub transparency: f32,
    pub ior: f32,
}

impl Default for Material {
    fn default() -> Self {
        Self {
            ty: MaterialType::Diffuse,
            roughness: 1.0,
            metallic: 0.0,
            emission: 0.0,
            emission_power: 1,
            transparency: 0.0,
            ior: 1.5,
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct Volume {
    pub name: String,
    pub cells: HashMap<Cell, u8>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Grab {
    None,
    Orbit,
    Pan,
    Paint,
}

pub struct Hit {
    pub cell: Cell,
    pub normal: Cell,
}

pub struct Session {
    pub tool: Tool,
    pub tool_mode: ToolMode,
    pub brush_size: i32,
    pub brush_shape: BrushShape,
    pub brush_3d: bool,
    pub line_mode: LineMode,
    pub circle_fill: bool,
    pub circle_even: bool,
    pub square_fill: bool,
    pub square_even: bool,
    pub box_fill: bool,
    pub face_extrude: FaceExtrude,
    pub face_with: FaceWith,
    pub face_eight: bool,
    pub generator: GeneratorKind,
    pub gen_axis: Axis,
    pub apex_at_max: bool,
    pub torus_tube: f32,
    pub tree_depth: i32,
    pub tree_wildness: f32,
    pub tree_trunk: f32,
    pub tree_leaf: i32,
    pub tree_seed: i32,
    pub conifer_tiers: i32,
    pub conifer_ragged: f32,
    pub conifer_clump: f32,
    pub conifer_trunk: f32,
    pub conifer_crown: f32,
    pub conifer_needle: i32,
    pub conifer_seed: i32,
    pub helix_turns: f32,
    pub helix_radius: f32,
    pub helix_tube: f32,
    pub helix_cw: bool,
    pub noise_scale: f32,
    pub noise_threshold: f32,
    pub noise_octaves: i32,
    pub noise_seed: i32,
    pub perlin_lo: i32,
    pub perlin_hi: i32,
    pub foliage_seed: i32,
    pub foliage_density: f32,

    pub palette: [[u8; 4]; 256],
    pub materials: [Material; 256],
    pub active_slot: u8,

    pub objects: Vec<Volume>,
    pub selected: usize,
    pub next_object: u32,
    pub path: Option<PathBuf>,

    pub editor_mode: EditorMode,
    pub render_mode: RenderMode,
    pub stochastic_gi: bool,
    pub glass_mode: GlassMode,
    pub resolution_match_window: bool,
    pub render_width: i32,
    pub render_height: i32,
    pub max_samples: i32,
    pub aces: bool,
    pub denoise: bool,
    pub aperture: f32,
    pub focus_distance: f32,
    pub max_bounces: i32,
    pub power_weighted_nee: bool,
    pub nee_ris: i32,
    pub indirect_clamp: f32,
    pub ema_floor: f32,
    pub atmospheric_sky: bool,
    pub sky_intensity: f32,
    pub horizon_softness: f32,
    pub sun_elevation: f32,
    pub sun_azimuth: f32,
    pub sun_disc: f32,
    pub sun_intensity: f32,
    pub sun_color: [f32; 3],

    pub yaw: f32,
    pub pitch: f32,
    pub distance: f32,
    pub target: Vec3,

    pub mesh_epoch: u64,
    pub status: String,
    pub hover: Option<Hit>,
    grab: Grab,
    pending: Option<Vec<Volume>>,
    undo: Vec<Vec<Volume>>,
    redo: Vec<Vec<Volume>>,
}

const IDLE: &str = "egui preview. Right-drag orbits, scroll zooms, left-drag paints with Brush. The SwiftUI app is unchanged.";

impl Session {
    pub fn new() -> Self {
        let mut session = Self {
            tool: Tool::Brush,
            tool_mode: ToolMode::Add,
            brush_size: 1,
            brush_shape: BrushShape::Square,
            brush_3d: true,
            line_mode: LineMode::Straight,
            circle_fill: false,
            circle_even: false,
            square_fill: false,
            square_even: false,
            box_fill: false,
            face_extrude: FaceExtrude::Color,
            face_with: FaceWith::Geometry,
            face_eight: false,
            generator: GeneratorKind::Ellipsoid,
            gen_axis: Axis::Y,
            apex_at_max: true,
            torus_tube: 0.3,
            tree_depth: 3,
            tree_wildness: 0.35,
            tree_trunk: 0.45,
            tree_leaf: 1,
            tree_seed: 1,
            conifer_tiers: 3,
            conifer_ragged: 0.25,
            conifer_clump: 6.0,
            conifer_trunk: 0.4,
            conifer_crown: 0.5,
            conifer_needle: 1,
            conifer_seed: 1,
            helix_turns: 2.0,
            helix_radius: 0.75,
            helix_tube: 0.16,
            helix_cw: false,
            noise_scale: 8.0,
            noise_threshold: 0.5,
            noise_octaves: 4,
            noise_seed: 1,
            perlin_lo: 1,
            perlin_hi: 8,
            foliage_seed: 1,
            foliage_density: 0.30,
            palette: default_palette(),
            materials: [Material::default(); 256],
            active_slot: 36,
            objects: Vec::new(),
            selected: 0,
            next_object: 2,
            path: None,
            editor_mode: EditorMode::Model,
            render_mode: RenderMode::Edit,
            stochastic_gi: true,
            glass_mode: GlassMode::Probabilistic,
            resolution_match_window: false,
            render_width: 960,
            render_height: 800,
            max_samples: 1024,
            aces: true,
            denoise: false,
            aperture: 0.0,
            focus_distance: 30.0,
            max_bounces: 5,
            power_weighted_nee: true,
            nee_ris: 8,
            indirect_clamp: 8.0,
            ema_floor: 0.05,
            atmospheric_sky: false,
            sky_intensity: 1.0,
            horizon_softness: 3.0,
            sun_elevation: 30.0,
            sun_azimuth: 30.0,
            sun_disc: 30.0,
            sun_intensity: 0.0,
            sun_color: [1.0, 0.95, 0.85],
            yaw: -0.8,
            pitch: 0.55,
            distance: 28.0,
            target: Vec3::new(0.0, 0.0, 4.0),
            mesh_epoch: 1,
            status: IDLE.into(),
            hover: None,
            grab: Grab::None,
            pending: None,
            undo: Vec::new(),
            redo: Vec::new(),
        };
        session.objects.push(Volume {
            name: "Tree".into(),
            cells: demo_tree(),
        });
        session.frame_camera();
        session
    }

    pub fn active(&self) -> &Volume {
        &self.objects[self.selected]
    }

    fn active_mut(&mut self) -> &mut Volume {
        let i = self.selected.min(self.objects.len().saturating_sub(1));
        self.selected = i;
        &mut self.objects[i]
    }

    pub fn voxel_count(&self) -> usize {
        self.active().cells.len()
    }

    pub fn bounds(&self) -> Option<(Cell, Cell)> {
        let mut iter = self.active().cells.keys().copied();
        let first = iter.next()?;
        let mut min = first;
        let mut max = first;
        for c in iter {
            min.0 = min.0.min(c.0);
            min.1 = min.1.min(c.1);
            min.2 = min.2.min(c.2);
            max.0 = max.0.max(c.0);
            max.1 = max.1.max(c.1);
            max.2 = max.2.max(c.2);
        }
        Some((min, max))
    }

    pub fn size_xyz(&self) -> Option<(i32, i32, i32)> {
        let (min, max) = self.bounds()?;
        Some((max.0 - min.0 + 1, max.1 - min.1 + 1, max.2 - min.2 + 1))
    }

    pub fn document_label(&self) -> String {
        match &self.path {
            Some(p) => p.display().to_string(),
            None => "Untitled".into(),
        }
    }

    pub fn color(&self, slot: u8) -> [u8; 3] {
        let c = self.palette[slot as usize];
        [c[0], c[1], c[2]]
    }

    pub fn set_color(&mut self, slot: u8, rgb: [u8; 3]) {
        if slot == 0 {
            return;
        }
        self.palette[slot as usize] = [rgb[0], rgb[1], rgb[2], 255];
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
    }

    pub fn material_mut(&mut self) -> &mut Material {
        &mut self.materials[self.active_slot as usize]
    }

    pub fn sun_dir(&self) -> Vec3 {
        let e = self.sun_elevation.to_radians();
        let a = self.sun_azimuth.to_radians();
        Vec3::new(a.cos() * e.cos(), a.sin() * e.cos(), e.sin()).normalize_or_zero()
    }

    pub fn eye(&self) -> Vec3 {
        self.target
            + Vec3::new(
                self.yaw.cos() * self.pitch.cos(),
                self.yaw.sin() * self.pitch.cos(),
                self.pitch.sin(),
            ) * self.distance
    }

    pub fn frame_camera(&mut self) {
        if let Some((min, max)) = self.bounds() {
            self.target = Vec3::new(
                (min.0 + max.0 + 1) as f32 * 0.5,
                (min.1 + max.1 + 1) as f32 * 0.5,
                (min.2 + max.2 + 1) as f32 * 0.5,
            );
            let ext = (max.0 - min.0).max(max.1 - min.1).max(max.2 - min.2) as f32 + 1.0;
            self.distance = (ext * 2.4).clamp(6.0, 800.0);
        } else {
            self.target = Vec3::ZERO;
            self.distance = 24.0;
        }
        self.yaw = -0.8;
        self.pitch = 0.55;
    }

    pub fn new_document(&mut self) {
        self.commit();
        self.objects.clear();
        self.objects.push(Volume {
            name: "Tree".into(),
            cells: demo_tree(),
        });
        self.selected = 0;
        self.next_object = 2;
        self.path = None;
        self.palette = default_palette();
        self.materials = [Material::default(); 256];
        self.undo.clear();
        self.redo.clear();
        self.pending = None;
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.frame_camera();
        self.status = IDLE.into();
    }

    pub fn open_dialog(&mut self) {
        let Some(path) = rfd::FileDialog::new()
            .add_filter("MagicaVoxel", &["vox"])
            .pick_file()
        else {
            return;
        };
        self.load_path(&path);
    }

    pub fn load_path(&mut self, path: &Path) {
        let bytes = match std::fs::read(path) {
            Ok(b) => b,
            Err(e) => {
                self.status = format!("Could not read {}: {e}", path.display());
                return;
            }
        };
        match load_vox(&bytes) {
            Ok(loaded) => {
                self.commit();
                let n = loaded.cells.len();
                let models = loaded.model_count;
                self.objects.clear();
                self.objects.push(Volume {
                    name: path
                        .file_stem()
                        .map(|s| s.to_string_lossy().into_owned())
                        .unwrap_or_else(|| "Model".into()),
                    cells: loaded.cells,
                });
                self.selected = 0;
                if let Some(pal) = loaded.palette {
                    self.palette = pal;
                }
                self.path = Some(path.to_path_buf());
                self.undo.clear();
                self.redo.clear();
                self.pending = None;
                self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
                self.frame_camera();
                self.status = if models > 1 {
                    format!(
                        "Loaded {n} voxels from the first of {models} models in {}. Scene transforms are not applied in this preview.",
                        path.file_name().unwrap_or_default().to_string_lossy()
                    )
                } else {
                    format!(
                        "Loaded {n} voxels from {}.",
                        path.file_name().unwrap_or_default().to_string_lossy()
                    )
                };
            }
            Err(e) => self.status = format!("{}: {e}", path.display()),
        }
    }

    pub fn take_drops(&mut self, ctx: &egui::Context) {
        let dropped: Vec<PathBuf> = ctx.input(|i| {
            i.raw
                .dropped_files
                .iter()
                .filter_map(|f| f.path.clone())
                .collect()
        });
        if let Some(path) = dropped.into_iter().next() {
            self.load_path(&path);
        }
    }

    pub fn new_object(&mut self) {
        self.commit();
        self.checkpoint();
        let name = format!("Object {}", self.next_object);
        self.next_object += 1;
        self.objects.push(Volume {
            name,
            cells: HashMap::new(),
        });
        self.selected = self.objects.len() - 1;
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.commit();
    }

    pub fn duplicate_object(&mut self) {
        self.commit();
        self.checkpoint();
        let copy = Volume {
            name: format!("{} copy", self.active().name),
            cells: self.active().cells.clone(),
        };
        self.objects.insert(self.selected + 1, copy);
        self.selected += 1;
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.commit();
    }

    pub fn delete_object(&mut self) {
        if self.objects.len() < 2 {
            return;
        }
        self.commit();
        self.checkpoint();
        self.objects.remove(self.selected);
        self.selected = self.selected.min(self.objects.len() - 1);
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.commit();
    }

    pub fn rename_selected(&mut self, name: String) {
        let name = name.trim().to_string();
        if name.is_empty() || name == self.active().name {
            return;
        }
        self.checkpoint();
        self.active_mut().name = name;
        self.commit();
    }

    pub fn select_object(&mut self, index: usize) {
        if index < self.objects.len() && index != self.selected {
            self.selected = index;
            self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        }
    }

    fn checkpoint(&mut self) {
        if self.pending.is_none() {
            self.pending = Some(self.objects.clone());
        }
    }

    fn commit(&mut self) {
        if let Some(prev) = self.pending.take() {
            if prev != self.objects {
                self.undo.push(prev);
                self.redo.clear();
                if self.undo.len() > 40 {
                    self.undo.remove(0);
                }
            }
        }
    }

    pub fn undo(&mut self) {
        self.commit();
        let Some(prev) = self.undo.pop() else {
            return;
        };
        let cur = std::mem::replace(&mut self.objects, prev);
        self.redo.push(cur);
        self.clamp_selection();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
    }

    pub fn redo(&mut self) {
        self.commit();
        let Some(next) = self.redo.pop() else {
            return;
        };
        let cur = std::mem::replace(&mut self.objects, next);
        self.undo.push(cur);
        self.clamp_selection();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
    }

    fn clamp_selection(&mut self) {
        if self.objects.is_empty() {
            self.objects.push(Volume {
                name: "Object".into(),
                cells: HashMap::new(),
            });
        }
        self.selected = self.selected.min(self.objects.len() - 1);
    }

    pub fn pointer(
        &mut self,
        inside: bool,
        primary_down: bool,
        primary_pressed: bool,
        primary_released: bool,
        secondary_down: bool,
        secondary_pressed: bool,
        middle_down: bool,
        middle_pressed: bool,
        space: bool,
        delta: glam::Vec2,
        scroll: f32,
        ray: Option<(Vec3, Vec3)>,
    ) {
        if inside && scroll.abs() > 0.0 {
            self.distance = (self.distance * (1.0 - scroll * 0.0014)).clamp(2.0, 2000.0);
        }

        if secondary_pressed && inside {
            self.grab = Grab::Orbit;
        } else if middle_pressed && inside {
            self.grab = Grab::Pan;
        } else if primary_pressed && inside {
            if space {
                self.grab = Grab::Pan;
            } else if self.can_paint() {
                self.grab = Grab::Paint;
                self.checkpoint();
            } else {
                self.grab = Grab::None;
                self.status = self.blocked_reason();
            }
        }

        match self.grab {
            Grab::Orbit if secondary_down => self.orbit(delta.x, delta.y),
            Grab::Pan if middle_down || primary_down => self.pan(delta.x, delta.y),
            Grab::Paint if primary_down => {
                if let Some((origin, dir)) = ray {
                    if let Some(hit) = raycast(&self.active().cells, origin, dir) {
                        self.stamp(hit);
                    }
                }
            }
            _ => {}
        }

        if primary_released && self.grab == Grab::Paint {
            self.commit();
            self.grab = Grab::None;
        }
        if !secondary_down && self.grab == Grab::Orbit {
            self.grab = Grab::None;
        }
        if !middle_down && !primary_down && self.grab == Grab::Pan {
            self.grab = Grab::None;
        }

        self.hover = None;
        if inside && self.grab != Grab::Orbit && self.grab != Grab::Pan {
            if let Some((origin, dir)) = ray {
                self.hover = raycast(&self.active().cells, origin, dir);
            }
        }
    }

    fn can_paint(&self) -> bool {
        self.tool == Tool::Brush
            && self.editor_mode == EditorMode::Model
            && self.render_mode == RenderMode::Edit
    }

    fn blocked_reason(&self) -> String {
        if self.render_mode == RenderMode::Render {
            "Render mode in this preview keeps the shaded voxels. Path tracing stays in the Metal app.".into()
        } else if self.editor_mode == EditorMode::Object {
            "Object-mode gizmos are not in this preview.".into()
        } else {
            format!(
                "{} options are live. Only Brush edits voxels in this preview.",
                self.tool.name()
            )
        }
    }

    fn orbit(&mut self, dx: f32, dy: f32) {
        self.yaw -= dx * 0.008;
        self.pitch = (self.pitch + dy * 0.008).clamp(-1.15, 1.15);
    }

    fn pan(&mut self, dx: f32, dy: f32) {
        let eye = self.eye();
        let forward = (self.target - eye).normalize_or_zero();
        let mut right = forward.cross(Vec3::Z);
        if right.length_squared() < 1e-4 {
            right = forward.cross(Vec3::Y);
        }
        let right = right.normalize_or_zero();
        let up = right.cross(forward).normalize_or_zero();
        let scale = self.distance * 0.0022;
        self.target += right * dx * scale + up * -dy * scale;
    }

    fn stamp(&mut self, hit: Hit) {
        let base = match self.tool_mode {
            ToolMode::Add => (
                hit.cell.0 + hit.normal.0,
                hit.cell.1 + hit.normal.1,
                hit.cell.2 + hit.normal.2,
            ),
            ToolMode::Remove | ToolMode::Paint => hit.cell,
        };
        let axis = if hit.normal.0 != 0 {
            0
        } else if hit.normal.1 != 0 {
            1
        } else {
            2
        };
        let slot = match self.tool_mode {
            ToolMode::Remove => 0,
            ToolMode::Add | ToolMode::Paint => self.active_slot,
        };
        let mut changed = false;
        for (u, v, w) in footprint(self.brush_size, self.brush_shape, self.brush_3d) {
            let (dx, dy, dz) = match axis {
                0 => (w, u, v),
                1 => (u, w, v),
                _ => (u, v, w),
            };
            let cell = (base.0 + dx, base.1 + dy, base.2 + dz);
            changed |= self.write_cell(cell, slot);
        }
        if changed {
            self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        }
    }

    fn write_cell(&mut self, cell: Cell, slot: u8) -> bool {
        let map = &mut self.active_mut().cells;
        if slot == 0 {
            map.remove(&cell).is_some()
        } else if map.get(&cell).copied() == Some(slot) {
            false
        } else {
            map.insert(cell, slot);
            true
        }
    }

    pub fn rotate_selection(&mut self, axis: Axis, clockwise: bool) {
        if self.active().cells.is_empty() {
            return;
        }
        self.checkpoint();
        let cells = std::mem::take(&mut self.active_mut().cells);
        let pivot = cells.keys().copied().next().unwrap_or((0, 0, 0));
        let mut pivot = pivot;
        for c in cells.keys() {
            pivot.0 = pivot.0.min(c.0);
            pivot.1 = pivot.1.min(c.1);
            pivot.2 = pivot.2.min(c.2);
        }
        let mut next = HashMap::with_capacity(cells.len());
        for (c, v) in cells {
            let p = (c.0 - pivot.0, c.1 - pivot.1, c.2 - pivot.2);
            let q = rot90(p, axis, clockwise);
            next.insert((q.0 + pivot.0, q.1 + pivot.1, q.2 + pivot.2), v);
        }
        self.active_mut().cells = next;
        self.commit();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
    }

    pub fn flip_selection(&mut self, axis: Axis) {
        if self.active().cells.is_empty() {
            return;
        }
        self.checkpoint();
        let cells = std::mem::take(&mut self.active_mut().cells);
        let mut min = (i32::MAX, i32::MAX, i32::MAX);
        let mut max = (i32::MIN, i32::MIN, i32::MIN);
        for c in cells.keys() {
            min.0 = min.0.min(c.0);
            min.1 = min.1.min(c.1);
            min.2 = min.2.min(c.2);
            max.0 = max.0.max(c.0);
            max.1 = max.1.max(c.1);
            max.2 = max.2.max(c.2);
        }
        let mut next = HashMap::with_capacity(cells.len());
        for (c, v) in cells {
            let q = match axis {
                Axis::X => (min.0 + max.0 - c.0, c.1, c.2),
                Axis::Y => (c.0, min.1 + max.1 - c.1, c.2),
                Axis::Z => (c.0, c.1, min.2 + max.2 - c.2),
            };
            next.insert(q, v);
        }
        self.active_mut().cells = next;
        self.commit();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
    }

    pub fn brush_cell_count(&self) -> i32 {
        footprint(self.brush_size, self.brush_shape, self.brush_3d).len() as i32
    }

    pub fn take_keys(&mut self, ctx: &egui::Context) {
        if ctx.wants_keyboard_input() {
            return;
        }
        let mut cmd: Option<Cmd> = None;
        ctx.input_mut(|i| {
            let redo = egui::KeyboardShortcut::new(
                egui::Modifiers::COMMAND | egui::Modifiers::SHIFT,
                egui::Key::Z,
            );
            let undo = egui::KeyboardShortcut::new(egui::Modifiers::COMMAND, egui::Key::Z);
            let open = egui::KeyboardShortcut::new(egui::Modifiers::COMMAND, egui::Key::O);
            let new = egui::KeyboardShortcut::new(egui::Modifiers::COMMAND, egui::Key::N);
            if i.consume_shortcut(&redo) {
                cmd = Some(Cmd::Redo);
            } else if i.consume_shortcut(&undo) {
                cmd = Some(Cmd::Undo);
            } else if i.consume_shortcut(&open) {
                cmd = Some(Cmd::Open);
            } else if i.consume_shortcut(&new) {
                cmd = Some(Cmd::New);
            } else if i.key_pressed(egui::Key::Tab) {
                cmd = Some(Cmd::Tab);
            } else if i.key_pressed(egui::Key::V) {
                cmd = Some(Cmd::Tool(Tool::Brush));
            } else if i.key_pressed(egui::Key::L) {
                cmd = Some(Cmd::Tool(Tool::Line));
            } else if i.key_pressed(egui::Key::B) {
                cmd = Some(Cmd::Tool(Tool::Box));
            } else if i.key_pressed(egui::Key::F) {
                cmd = Some(Cmd::Tool(Tool::Face));
            } else if i.key_pressed(egui::Key::U) {
                cmd = Some(Cmd::Tool(Tool::Mutator));
            } else if i.key_pressed(egui::Key::M) {
                cmd = Some(Cmd::Tool(Tool::Marquee));
            }
        });
        match cmd {
            Some(Cmd::Undo) => self.undo(),
            Some(Cmd::Redo) => self.redo(),
            Some(Cmd::Open) => self.open_dialog(),
            Some(Cmd::New) => self.new_document(),
            Some(Cmd::Tab) => {
                self.editor_mode = if self.editor_mode == EditorMode::Model {
                    EditorMode::Object
                } else {
                    EditorMode::Model
                };
            }
            Some(Cmd::Tool(tool)) => self.tool = tool,
            None => {}
        }
    }
}

enum Cmd {
    Undo,
    Redo,
    Open,
    New,
    Tab,
    Tool(Tool),
}

fn rot90(p: Cell, axis: Axis, clockwise: bool) -> Cell {
    let (x, y, z) = p;
    match (axis, clockwise) {
        (Axis::Z, false) => (-y, x, z),
        (Axis::Z, true) => (y, -x, z),
        (Axis::X, false) => (x, -z, y),
        (Axis::X, true) => (x, z, -y),
        (Axis::Y, false) => (z, y, -x),
        (Axis::Y, true) => (-z, y, x),
    }
}

fn footprint(size: i32, shape: BrushShape, three_d: bool) -> Vec<Cell> {
    let edge = size.clamp(1, 63);
    let lo = -((edge - 1) / 2);
    let hi = edge / 2;
    let c = (lo + hi) as f32 * 0.5;
    let r2 = (edge as f32 * 0.5) * (edge as f32 * 0.5);
    let mut out = Vec::new();
    for w in lo..=hi {
        if !three_d && w != 0 {
            continue;
        }
        for v in lo..=hi {
            for u in lo..=hi {
                if shape == BrushShape::Circle {
                    let fu = u as f32 - c;
                    let fv = v as f32 - c;
                    let fw = if three_d { w as f32 - c } else { 0.0 };
                    if fu * fu + fv * fv + fw * fw > r2 {
                        continue;
                    }
                }
                out.push((u, v, w));
            }
        }
    }
    out
}

pub fn raycast(cells: &HashMap<Cell, u8>, origin: Vec3, dir: Vec3) -> Option<Hit> {
    let dir = dir.normalize_or_zero();
    if dir.length_squared() < 1e-8 {
        return None;
    }
    let mut x = origin.x.floor() as i32;
    let mut y = origin.y.floor() as i32;
    let mut z = origin.z.floor() as i32;
    let step = |d: f32| if d >= 0.0 { 1 } else { -1 };
    let step_x = step(dir.x);
    let step_y = step(dir.y);
    let step_z = step(dir.z);
    let t_delta = |d: f32| {
        if d.abs() < 1e-8 {
            f32::INFINITY
        } else {
            (1.0 / d).abs()
        }
    };
    let t_max = |origin: f32, cell: i32, d: f32, step: i32| {
        if d.abs() < 1e-8 {
            f32::INFINITY
        } else if step > 0 {
            (cell as f32 + 1.0 - origin) / d
        } else {
            (cell as f32 - origin) / d
        }
    };
    let mut t_max_x = t_max(origin.x, x, dir.x, step_x);
    let mut t_max_y = t_max(origin.y, y, dir.y, step_y);
    let mut t_max_z = t_max(origin.z, z, dir.z, step_z);
    let t_delta_x = t_delta(dir.x);
    let t_delta_y = t_delta(dir.y);
    let t_delta_z = t_delta(dir.z);

    if cells.contains_key(&(x, y, z)) {
        return Some(Hit {
            cell: (x, y, z),
            normal: dominant_normal(-dir),
        });
    }

    for _ in 0..768 {
        let travel = t_max_x.min(t_max_y).min(t_max_z);
        if travel > 400.0 {
            break;
        }
        let normal = if t_max_x <= t_max_y && t_max_x <= t_max_z {
            x += step_x;
            t_max_x += t_delta_x;
            (-step_x, 0, 0)
        } else if t_max_y <= t_max_z {
            y += step_y;
            t_max_y += t_delta_y;
            (0, -step_y, 0)
        } else {
            z += step_z;
            t_max_z += t_delta_z;
            (0, 0, -step_z)
        };
        if cells.contains_key(&(x, y, z)) {
            return Some(Hit {
                cell: (x, y, z),
                normal,
            });
        }
    }
    None
}

fn dominant_normal(dir: Vec3) -> Cell {
    let ax = dir.x.abs();
    let ay = dir.y.abs();
    let az = dir.z.abs();
    if ax >= ay && ax >= az {
        (dir.x.signum() as i32, 0, 0)
    } else if ay >= az {
        (0, dir.y.signum() as i32, 0)
    } else {
        (0, 0, dir.z.signum() as i32)
    }
}

fn demo_tree() -> HashMap<Cell, u8> {
    let mut cells = HashMap::new();
    for y in -7..=7 {
        for x in -7..=7 {
            if x * x + y * y <= 49 {
                cells.insert((x, y, 0), 250);
            }
        }
    }
    for z in 1..=6 {
        cells.insert((0, 0, z), 100);
        cells.insert((1, 0, z), 100);
        cells.insert((0, 1, z), 100);
    }
    let r = 5;
    for z in -r..=r {
        for y in -r..=r {
            for x in -r..=r {
                if x * x + y * y + z * z <= r * r {
                    cells.insert((x, y, z + 9), 150);
                }
            }
        }
    }
    cells
}

struct Loaded {
    cells: HashMap<Cell, u8>,
    palette: Option<[[u8; 4]; 256]>,
    model_count: usize,
}

fn load_vox(bytes: &[u8]) -> Result<Loaded, String> {
    if bytes.len() < 8 || &bytes[0..4] != b"VOX " {
        return Err("not a .vox file".into());
    }
    let mut p = 8usize;
    let id = read_id(bytes, &mut p)?;
    if &id != b"MAIN" {
        return Err("expected MAIN chunk".into());
    }
    let main_content = read_u32(bytes, &mut p)? as usize;
    let main_children = read_u32(bytes, &mut p)? as usize;
    p = p.saturating_add(main_content);
    if p + main_children > bytes.len() {
        return Err("truncated MAIN chunk".into());
    }
    let end = p + main_children;

    let mut models: Vec<Vec<(u8, u8, u8, u8)>> = Vec::new();
    let mut pending: Option<(u32, u32, u32)> = None;
    let mut palette = None;

    while p + 12 <= end {
        let id = read_id(bytes, &mut p)?;
        let content = read_u32(bytes, &mut p)? as usize;
        let children = read_u32(bytes, &mut p)? as usize;
        if p + content + children > end {
            return Err("chunk extends past MAIN".into());
        }
        let body = &bytes[p..p + content];
        if &id == b"SIZE" {
            if body.len() != 12 {
                return Err("SIZE chunk has the wrong length".into());
            }
            pending = Some((
                u32::from_le_bytes(body[0..4].try_into().unwrap()),
                u32::from_le_bytes(body[4..8].try_into().unwrap()),
                u32::from_le_bytes(body[8..12].try_into().unwrap()),
            ));
        } else if &id == b"XYZI" {
            if pending.take().is_none() {
                return Err("XYZI chunk before SIZE".into());
            }
            if body.len() < 4 {
                return Err("truncated XYZI".into());
            }
            let n = u32::from_le_bytes(body[0..4].try_into().unwrap()) as usize;
            if body.len() < 4 + n * 4 {
                return Err("XYZI voxel data is truncated".into());
            }
            let mut voxels = Vec::with_capacity(n);
            for i in 0..n {
                let o = 4 + i * 4;
                voxels.push((body[o], body[o + 1], body[o + 2], body[o + 3]));
            }
            models.push(voxels);
        } else if &id == b"RGBA" {
            if body.len() < 1024 {
                return Err("RGBA chunk is shorter than 1024 bytes".into());
            }
            let mut pal = default_palette();
            for i in 0..255 {
                pal[i + 1] = [
                    body[i * 4],
                    body[i * 4 + 1],
                    body[i * 4 + 2],
                    body[i * 4 + 3],
                ];
            }
            pal[0] = [0, 0, 0, 0];
            palette = Some(pal);
        }
        p += content + children;
    }

    if models.is_empty() {
        return Err("file has no models".into());
    }
    let model_count = models.len();
    let voxels = models.into_iter().next().unwrap();
    let mut raw: Vec<Cell> = Vec::new();
    let mut colors: Vec<u8> = Vec::new();
    for (x, y, z, i) in voxels {
        if i == 0 {
            continue;
        }
        raw.push((x as i32, y as i32, z as i32));
        colors.push(i);
    }
    let cells = if raw.is_empty() {
        HashMap::new()
    } else {
        let mut min = raw[0];
        let mut max = raw[0];
        for c in &raw {
            min.0 = min.0.min(c.0);
            min.1 = min.1.min(c.1);
            min.2 = min.2.min(c.2);
            max.0 = max.0.max(c.0);
            max.1 = max.1.max(c.1);
            max.2 = max.2.max(c.2);
        }
        let dx = -((min.0 + max.0) / 2);
        let dy = -((min.1 + max.1) / 2);
        let dz = -min.2;
        let mut cells = HashMap::with_capacity(raw.len());
        for (c, color) in raw.into_iter().zip(colors) {
            cells.insert((c.0 + dx, c.1 + dy, c.2 + dz), color);
        }
        cells
    };
    Ok(Loaded {
        cells,
        palette,
        model_count,
    })
}

fn read_id(bytes: &[u8], p: &mut usize) -> Result<[u8; 4], String> {
    if *p + 4 > bytes.len() {
        return Err("truncated chunk id".into());
    }
    let id = [bytes[*p], bytes[*p + 1], bytes[*p + 2], bytes[*p + 3]];
    *p += 4;
    Ok(id)
}

fn read_u32(bytes: &[u8], p: &mut usize) -> Result<u32, String> {
    if *p + 4 > bytes.len() {
        return Err("truncated chunk header".into());
    }
    let v = u32::from_le_bytes(bytes[*p..*p + 4].try_into().unwrap());
    *p += 4;
    Ok(v)
}

fn default_palette() -> [[u8; 4]; 256] {
    let mut out = [[0u8; 4]; 256];
    for (i, v) in DEFAULT_PALETTE.iter().enumerate() {
        out[i] = [
            (v & 0xff) as u8,
            ((v >> 8) & 0xff) as u8,
            ((v >> 16) & 0xff) as u8,
            ((v >> 24) & 0xff) as u8,
        ];
    }
    out
}

// MagicaVoxel default palette, same table as src/Palette.cpp.
// Little-endian byte order of each word is R, G, B, A.
const DEFAULT_PALETTE: [u32; 256] = [
    0x00000000, 0xffffffff, 0xffccffff, 0xff99ffff, 0xff66ffff, 0xff33ffff, 0xff00ffff, 0xffffccff,
    0xffccccff, 0xff99ccff, 0xff66ccff, 0xff33ccff, 0xff00ccff, 0xffff99ff, 0xffcc99ff, 0xff9999ff,
    0xff6699ff, 0xff3399ff, 0xff0099ff, 0xffff66ff, 0xffcc66ff, 0xff9966ff, 0xff6666ff, 0xff3366ff,
    0xff0066ff, 0xffff33ff, 0xffcc33ff, 0xff9933ff, 0xff6633ff, 0xff3333ff, 0xff0033ff, 0xffff00ff,
    0xffcc00ff, 0xff9900ff, 0xff6600ff, 0xff3300ff, 0xff0000ff, 0xffffffcc, 0xffccffcc, 0xff99ffcc,
    0xff66ffcc, 0xff33ffcc, 0xff00ffcc, 0xffffcccc, 0xffcccccc, 0xff99cccc, 0xff66cccc, 0xff33cccc,
    0xff00cccc, 0xffff99cc, 0xffcc99cc, 0xff9999cc, 0xff6699cc, 0xff3399cc, 0xff0099cc, 0xffff66cc,
    0xffcc66cc, 0xff9966cc, 0xff6666cc, 0xff3366cc, 0xff0066cc, 0xffff33cc, 0xffcc33cc, 0xff9933cc,
    0xff6633cc, 0xff3333cc, 0xff0033cc, 0xffff00cc, 0xffcc00cc, 0xff9900cc, 0xff6600cc, 0xff3300cc,
    0xff0000cc, 0xffffff99, 0xffccff99, 0xff99ff99, 0xff66ff99, 0xff33ff99, 0xff00ff99, 0xffffcc99,
    0xffcccc99, 0xff99cc99, 0xff66cc99, 0xff33cc99, 0xff00cc99, 0xffff9999, 0xffcc9999, 0xff999999,
    0xff669999, 0xff339999, 0xff009999, 0xffff6699, 0xffcc6699, 0xff996699, 0xff666699, 0xff336699,
    0xff006699, 0xffff3399, 0xffcc3399, 0xff993399, 0xff663399, 0xff333399, 0xff003399, 0xffff0099,
    0xffcc0099, 0xff990099, 0xff660099, 0xff330099, 0xff000099, 0xffffff66, 0xffccff66, 0xff99ff66,
    0xff66ff66, 0xff33ff66, 0xff00ff66, 0xffffcc66, 0xffcccc66, 0xff99cc66, 0xff66cc66, 0xff33cc66,
    0xff00cc66, 0xffff9966, 0xffcc9966, 0xff999966, 0xff669966, 0xff339966, 0xff009966, 0xffff6666,
    0xffcc6666, 0xff996666, 0xff666666, 0xff336666, 0xff006666, 0xffff3366, 0xffcc3366, 0xff993366,
    0xff663366, 0xff333366, 0xff003366, 0xffff0066, 0xffcc0066, 0xff990066, 0xff660066, 0xff330066,
    0xff000066, 0xffffff33, 0xffccff33, 0xff99ff33, 0xff66ff33, 0xff33ff33, 0xff00ff33, 0xffffcc33,
    0xffcccc33, 0xff99cc33, 0xff66cc33, 0xff33cc33, 0xff00cc33, 0xffff9933, 0xffcc9933, 0xff999933,
    0xff669933, 0xff339933, 0xff009933, 0xffff6633, 0xffcc6633, 0xff996633, 0xff666633, 0xff336633,
    0xff006633, 0xffff3333, 0xffcc3333, 0xff993333, 0xff663333, 0xff333333, 0xff003333, 0xffff0033,
    0xffcc0033, 0xff990033, 0xff660033, 0xff330033, 0xff000033, 0xffffff00, 0xffccff00, 0xff99ff00,
    0xff66ff00, 0xff33ff00, 0xff00ff00, 0xffffcc00, 0xffcccc00, 0xff99cc00, 0xff66cc00, 0xff33cc00,
    0xff00cc00, 0xffff9900, 0xffcc9900, 0xff999900, 0xff669900, 0xff339900, 0xff009900, 0xffff6600,
    0xffcc6600, 0xff996600, 0xff666600, 0xff336600, 0xff006600, 0xffff3300, 0xffcc3300, 0xff993300,
    0xff663300, 0xff333300, 0xff003300, 0xffff0000, 0xffcc0000, 0xff990000, 0xff660000, 0xff330000,
    0xff0000ee, 0xff0000dd, 0xff0000bb, 0xff0000aa, 0xff000088, 0xff000077, 0xff000055, 0xff000044,
    0xff000022, 0xff000011, 0xff00ee00, 0xff00dd00, 0xff00bb00, 0xff00aa00, 0xff008800, 0xff007700,
    0xff005500, 0xff004400, 0xff002200, 0xff001100, 0xffee0000, 0xffdd0000, 0xffbb0000, 0xffaa0000,
    0xff880000, 0xff770000, 0xff550000, 0xff440000, 0xff220000, 0xff110000, 0xffeeeeee, 0xffdddddd,
    0xffbbbbbb, 0xffaaaaaa, 0xff888888, 0xff777777, 0xff555555, 0xff444444, 0xff222222, 0xff111111,
];

#[cfg(test)]
mod tests {
    use super::*;

    fn chunk(id: &[u8; 4], content: &[u8]) -> Vec<u8> {
        let mut out = id.to_vec();
        out.extend_from_slice(&(content.len() as u32).to_le_bytes());
        out.extend_from_slice(&0u32.to_le_bytes());
        out.extend_from_slice(content);
        out
    }

    #[test]
    fn loads_one_voxel() {
        let mut size = Vec::new();
        size.extend_from_slice(&1u32.to_le_bytes());
        size.extend_from_slice(&1u32.to_le_bytes());
        size.extend_from_slice(&1u32.to_le_bytes());
        let mut xyzi = Vec::new();
        xyzi.extend_from_slice(&1u32.to_le_bytes());
        xyzi.extend_from_slice(&[0, 0, 0, 36]);
        let children = {
            let mut c = chunk(b"SIZE", &size);
            c.extend(chunk(b"XYZI", &xyzi));
            c
        };
        let mut file = b"VOX ".to_vec();
        file.extend_from_slice(&150u32.to_le_bytes());
        file.extend(b"MAIN");
        file.extend_from_slice(&0u32.to_le_bytes());
        file.extend_from_slice(&(children.len() as u32).to_le_bytes());
        file.extend(children);

        let loaded = load_vox(&file).expect("vox");
        assert_eq!(loaded.model_count, 1);
        assert_eq!(loaded.cells.get(&(0, 0, 0)), Some(&36));
    }

    #[test]
    fn brush_undo_restores_the_previous_volume() {
        let mut session = Session::new();
        let before = session.voxel_count();
        session.checkpoint();
        session.stamp(Hit {
            cell: (0, 0, 0),
            normal: (0, 0, 1),
        });
        assert!(session.voxel_count() >= before);
        session.commit();
        session.undo();
        assert_eq!(session.voxel_count(), before);
    }
}
