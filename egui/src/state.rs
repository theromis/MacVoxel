//! Editor session for the egui preview.
//!
//! Geometry, palette, and panel values live here. The SwiftUI app and the
//! C++ core are not linked: brush strokes edit this in-memory volume so the
//! shell can be tried on its own.

use std::collections::{HashMap, HashSet};
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
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

#[derive(Clone, Copy, Debug, PartialEq)]
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
    /// World offset of local cell (0, 0, 0). Copies are placed beside the
    /// source so they do not occupy the same voxels.
    pub translation: Cell,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Grab {
    None,
    Orbit,
    Pan,
    Paint,
    Select,
    Move,
    Object,
    ObjectMarquee,
}

enum ObjectPress {
    Drag,
    Marquee,
    Idle,
}

#[derive(Clone, Copy)]
pub struct Hit {
    pub cell: Cell,
    pub normal: Cell,
}

pub struct ToolDrag {
    pub rays: Vec<(Vec3, Vec3)>,
    pub face_steps: i32,
    /// Occupied cells inside a marquee, computed on release. `None` when
    /// the gesture is not a marquee.
    pub marquee: Option<Vec<Cell>>,
    pub shift: bool,
    /// Objects whose screen box meets the rubber band. `None` outside an
    /// Object-mode drag. `click` is a press that never grew past 2px.
    pub object_band: Option<ObjectBand>,
}

pub struct ObjectBand {
    pub click: bool,
    pub hits: Vec<usize>,
}

struct Stroke {
    anchor: Hit,
    base: HashMap<Cell, u8>,
    seeds: Vec<Cell>,
    axis: i32,
    sign: i32,
    id: u32,
    key: Option<(Cell, i32, u64)>,
}

#[derive(Clone, Copy, PartialEq)]
pub enum UiAction {
    None,
    Tool(Tool),
    Mode(ToolMode),
    Editor(EditorMode),
    Render(RenderMode),
    NewObject,
    Duplicate,
    DeleteObject,
    Viewport,
}

#[derive(Clone)]
pub struct UiRegion {
    pub id: String,
    pub label: String,
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
    pub action: UiAction,
}

impl UiRegion {
    fn contains(&self, x: f32, y: f32) -> bool {
        x >= self.x && y >= self.y && x < self.x + self.w && y < self.y + self.h
    }
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
    /// Primary object. Tools and the gizmo use this one.
    pub selected: usize,
    /// Object-mode selection, including `selected`. A rubber band fills it.
    pub object_selection: Vec<usize>,
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
    /// Occupied cells of the active object chosen by Marquee, Box Select,
    /// or Flood Select. Rotate, flip, and delete act on this set when it
    /// is not empty.
    pub picked: HashSet<Cell>,
    pub selection_epoch: u64,
    select_anchor: Option<Cell>,
    clipboard: Option<VoxelClipboard>,
    move_drag: Option<MoveDrag>,
    object_drag: Option<ObjectDrag>,
    /// Axis under the cursor in Object mode. The viewport sets this before
    /// the pointer handler, so a press on an arrow locks that axis.
    pub hover_gizmo: Option<i32>,
    stroke: Option<Stroke>,
    stroke_serial: u32,
    pub(crate) grab: Grab,
    /// Slots highlighted in the palette. The active slot is always one of them.
    pub palette_slots: HashSet<u8>,
    color_clipboard: Option<[u8; 4]>,
    palette_press: Option<(i32, i32)>,
    palette_current: Option<(i32, i32)>,
    palette_shift: bool,
    pub palette_anchor: u8,
    pending: Option<Snapshot>,
    undo: Vec<Snapshot>,
    redo: Vec<Snapshot>,
    /// Controls drawn last frame, in paint order. A click hits the last match.
    pub ui_regions: Vec<UiRegion>,
    recent: Vec<PathBuf>,
}

const IDLE: &str = "Right-drag orbits, scroll zooms, left-drag edits with the active tool. Path tracing stays in the Metal app.";

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
            object_selection: vec![0],
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
            picked: HashSet::new(),
            selection_epoch: 1,
            select_anchor: None,
            clipboard: None,
            move_drag: None,
            object_drag: None,
            hover_gizmo: None,
            stroke: None,
            stroke_serial: 1,
            grab: Grab::None,
            palette_slots: HashSet::from([36]),
            color_clipboard: None,
            palette_press: None,
            palette_current: None,
            palette_shift: false,
            palette_anchor: 36,
            pending: None,
            undo: Vec::new(),
            redo: Vec::new(),
            ui_regions: Vec::new(),
            recent: load_recent(),
        };
        session.objects.push(Volume {
            name: "Tree".into(),
            cells: demo_tree(),
            translation: (0, 0, 0),
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

    pub fn world_bounds(&self) -> Option<(Cell, Cell)> {
        let mut min = (i32::MAX, i32::MAX, i32::MAX);
        let mut max = (i32::MIN, i32::MIN, i32::MIN);
        let mut any = false;
        for object in &self.objects {
            for cell in object.cells.keys() {
                any = true;
                let world = (
                    cell.0 + object.translation.0,
                    cell.1 + object.translation.1,
                    cell.2 + object.translation.2,
                );
                min.0 = min.0.min(world.0);
                min.1 = min.1.min(world.1);
                min.2 = min.2.min(world.2);
                max.0 = max.0.max(world.0);
                max.1 = max.1.max(world.1);
                max.2 = max.2.max(world.2);
            }
        }
        any.then_some((min, max))
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

    pub fn palette_drag(&self) -> Option<((i32, i32), (i32, i32))> {
        Some((self.palette_press?, self.palette_current?))
    }

    pub fn begin_palette_drag(&mut self, cell: (i32, i32), shift: bool) {
        self.palette_press = Some(cell);
        self.palette_current = Some(cell);
        self.palette_shift = shift;
    }

    pub fn update_palette_drag(&mut self, cell: (i32, i32)) {
        if self.palette_press.is_some() {
            self.palette_current = Some(cell);
        }
    }

    pub fn finish_palette_drag(&mut self) {
        let Some(start) = self.palette_press.take() else {
            return;
        };
        let cell = self.palette_current.take().unwrap_or(start);
        let shift = self.palette_shift;
        if start == cell {
            let slot = palette_slot_at(cell.0, cell.1);
            if slot != 0 {
                self.select_palette_slot(slot, shift);
            }
        } else {
            self.select_palette_range(start.0, start.1, cell.0, cell.1, shift);
        }
    }

    pub fn select_palette_slot(&mut self, slot: u8, extend: bool) {
        if slot == 0 {
            return;
        }
        if !extend {
            self.palette_slots.clear();
            self.palette_slots.insert(slot);
        } else if !self.palette_slots.remove(&slot) {
            self.palette_slots.insert(slot);
        } else if self.palette_slots.is_empty() {
            self.palette_slots.insert(slot);
        }
        self.active_slot = slot;
    }

    pub fn select_palette_range(&mut self, c0: i32, r0: i32, c1: i32, r1: i32, shift: bool) {
        if !shift {
            self.palette_slots.clear();
        }
        let min_c = c0.min(c1);
        let max_c = c0.max(c1);
        let min_r = r0.min(r1);
        let max_r = r0.max(r1);
        for row in min_r..=max_r {
            for col in min_c..=max_c {
                let slot = palette_slot_at(col, row);
                if slot == 0 {
                    continue;
                }
                if shift {
                    if !self.palette_slots.remove(&slot) {
                        self.palette_slots.insert(slot);
                    }
                } else {
                    self.palette_slots.insert(slot);
                }
            }
        }
        let end = palette_slot_at(c1, r1);
        if end != 0 {
            self.palette_slots.insert(end);
            self.active_slot = end;
        }
    }

    pub fn note_palette_anchor(&mut self, slot: u8) {
        if slot != 0 {
            self.palette_anchor = slot;
        }
    }

    fn ensure_palette_anchor(&mut self, anchor: u8) {
        if anchor == 0 {
            return;
        }
        if !self.palette_slots.contains(&anchor) {
            self.palette_slots.clear();
            self.palette_slots.insert(anchor);
            self.active_slot = anchor;
        }
    }

    pub fn palette_action_count(&self, anchor: u8) -> usize {
        if anchor == 0 {
            return 0;
        }
        if self.palette_slots.contains(&anchor) {
            self.palette_slots.len()
        } else {
            1
        }
    }

    pub fn has_color_clipboard(&self) -> bool {
        self.color_clipboard.is_some()
    }

    pub fn copy_palette_color(&mut self, slot: u8) {
        if slot == 0 {
            return;
        }
        self.color_clipboard = Some(self.palette[slot as usize]);
        self.status = format!("Copied palette {slot}.");
    }

    pub fn paste_palette_color(&mut self, anchor: u8) {
        let Some(color) = self.color_clipboard else {
            return;
        };
        self.ensure_palette_anchor(anchor);
        self.checkpoint();
        for slot in self.palette_slots.iter().copied() {
            if slot != 0 {
                self.palette[slot as usize] = color;
            }
        }
        self.commit();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.status = "Pasted the copied color.".into();
    }

    pub fn make_palette_gradient(&mut self, anchor: u8) {
        self.ensure_palette_anchor(anchor);
        let mut indices: Vec<u8> = self
            .palette_slots
            .iter()
            .copied()
            .filter(|s| *s != 0)
            .collect();
        indices.sort_unstable();
        let Some(&lo) = indices.first() else {
            return;
        };
        let Some(&hi) = indices.last() else {
            return;
        };
        if hi.saturating_sub(lo) < 2 {
            return;
        }
        let c0 = self.palette[lo as usize];
        let c1 = self.palette[hi as usize];
        let span = (hi - lo) as f32;
        self.checkpoint();
        for slot in indices {
            if slot == lo || slot == hi {
                continue;
            }
            let t = (slot - lo) as f32 / span;
            self.palette[slot as usize] = lerp_color(c0, c1, t);
        }
        self.commit();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.status = format!("Gradient from {lo} to {hi}.");
    }

    pub fn select_voxels_by_color(&mut self, anchor: u8) {
        self.ensure_palette_anchor(anchor);
        let slots = self.palette_slots.clone();
        let matched = self
            .active()
            .cells
            .iter()
            .filter(|(_, slot)| slots.contains(*slot))
            .map(|(cell, _)| *cell)
            .collect();
        self.set_picked(matched);
    }

    pub fn paint_picked_with_color(&mut self, anchor: u8) {
        if self.picked.is_empty() {
            return;
        }
        self.ensure_palette_anchor(anchor);
        if self.palette_slots.len() != 1 {
            return;
        }
        let Some(slot) = self.palette_slots.iter().copied().find(|slot| *slot != 0) else {
            return;
        };
        self.recolor_picked(|_| slot);
    }

    pub fn paint_picked_with_random_colors(&mut self, anchor: u8) {
        if self.picked.is_empty() {
            return;
        }
        self.ensure_palette_anchor(anchor);
        let mut slots: Vec<u8> = self
            .palette_slots
            .iter()
            .copied()
            .filter(|s| *s != 0)
            .collect();
        slots.sort_unstable();
        if slots.len() < 2 {
            return;
        }
        self.recolor_picked(|cell| {
            let h = (cell.0 as u32).wrapping_mul(73856093)
                ^ (cell.1 as u32).wrapping_mul(19349663)
                ^ (cell.2 as u32).wrapping_mul(83492791);
            slots[(h as usize) % slots.len()]
        });
    }

    fn recolor_picked(&mut self, mut choose: impl FnMut(Cell) -> u8) {
        if self.picked.is_empty() {
            return;
        }
        self.checkpoint();
        let picked: Vec<Cell> = self.picked.iter().copied().collect();
        {
            let map = &mut self.active_mut().cells;
            for cell in picked {
                let slot = choose(cell);
                if slot != 0 {
                    map.insert(cell, slot);
                }
            }
        }
        self.commit();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.status = format!("Recolored {} voxels.", self.picked.len());
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
        if let Some((min, max)) = self.world_bounds() {
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
            translation: (0, 0, 0),
        });
        self.selected = 0;
        self.focus_object();
        self.next_object = 2;
        self.path = None;
        self.palette = default_palette();
        self.materials = [Material::default(); 256];
        self.undo.clear();
        self.redo.clear();
        self.pending = None;
        self.clear_picked();
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
        if let Err(e) = self.open_vox(path) {
            self.status = e;
            self.recent.retain(|stored| stored != path);
            store_recent(&self.recent);
        }
    }

    pub(crate) fn open_vox(&mut self, path: &Path) -> Result<(), String> {
        let bytes =
            std::fs::read(path).map_err(|e| format!("Could not read {}: {e}", path.display()))?;
        let loaded = load_vox(&bytes).map_err(|e| format!("{}: {e}", path.display()))?;
        self.commit();
        let n: usize = loaded.objects.iter().map(|object| object.cells.len()).sum();
        let models = loaded.objects.len();
        let stem = path
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| "Model".into());
        self.objects.clear();
        for (index, object) in loaded.objects.into_iter().enumerate() {
            let name = if !object.name.is_empty() {
                object.name
            } else if models == 1 {
                stem.clone()
            } else {
                format!("Object {}", index + 1)
            };
            self.objects.push(Volume {
                name,
                cells: object.cells,
                translation: object.translation,
            });
        }
        if self.objects.is_empty() {
            self.objects.push(Volume {
                name: stem,
                cells: HashMap::new(),
                translation: (0, 0, 0),
            });
        }
        self.selected = 0;
        self.focus_object();
        self.next_object = (self.objects.len() as u32).saturating_add(1).max(2);
        self.palette = loaded.palette.unwrap_or_else(default_palette);
        self.materials = loaded.materials;
        self.path = Some(path.to_path_buf());
        self.undo.clear();
        self.redo.clear();
        self.pending = None;
        self.clear_picked();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.frame_camera();
        let file = path.file_name().unwrap_or_default().to_string_lossy();
        self.status = if models > 1 {
            format!("Loaded {n} voxels in {models} objects from {file}.")
        } else {
            format!("Loaded {n} voxels from {file}.")
        };
        self.remember_path(path);
        Ok(())
    }

    /// Empty one-object document. The window's File → New still builds the demo tree.
    pub(crate) fn replace_empty(&mut self) {
        self.commit();
        self.objects.clear();
        self.objects.push(Volume {
            name: "Object".into(),
            cells: HashMap::new(),
            translation: (0, 0, 0),
        });
        self.selected = 0;
        self.focus_object();
        self.next_object = 2;
        self.path = None;
        self.palette = default_palette();
        self.materials = [Material::default(); 256];
        self.undo.clear();
        self.redo.clear();
        self.pending = None;
        self.clear_picked();
        self.hover = None;
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.frame_camera();
        self.status = "Empty document.".into();
    }

    pub(crate) fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    pub(crate) fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    /// Write cells of the active object. Palette 0 erases. One undo step.
    /// Coordinates are local to that object and must lie in `[-1024, 1024)`.
    pub(crate) fn write_cells(&mut self, writes: &[(i32, i32, i32, i32)]) -> Result<i64, String> {
        let mut deduped: HashMap<Cell, u8> = HashMap::new();
        for (x, y, z, palette) in writes {
            if !in_world(*x, *y, *z) {
                return Err("coordinate outside the world [-1024, 1024)".into());
            }
            if !(0..=255).contains(palette) {
                return Err("palette must be 0..255".into());
            }
            deduped.insert((*x, *y, *z), *palette as u8);
        }
        let mut next = self.active().cells.clone();
        let mut changed = 0i64;
        for (cell, palette) in deduped {
            let old = next.get(&cell).copied().unwrap_or(0);
            if old == palette {
                continue;
            }
            changed += 1;
            if palette == 0 {
                next.remove(&cell);
            } else {
                next.insert(cell, palette);
            }
        }
        if changed == 0 {
            return Ok(0);
        }
        if let Some((min, max)) = cell_bounds(next.keys().copied()) {
            let sx = max.0 - min.0 + 1;
            let sy = max.1 - min.1 + 1;
            let sz = max.2 - min.2 + 1;
            if sx > 256 || sy > 256 || sz > 256 {
                return Err(format!(
                    "edit would make the active object {sx}x{sy}x{sz}; .vox models are at most 256 per axis"
                ));
            }
        }
        self.commit();
        self.checkpoint();
        self.active_mut().cells = next;
        self.clear_picked();
        self.commit();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        Ok(changed)
    }

    pub(crate) fn write_palette(&mut self, slots: &[(u8, [u8; 4])]) -> i64 {
        let mut changed = 0i64;
        for (index, rgba) in slots {
            if self.palette[*index as usize] != *rgba {
                changed += 1;
            }
        }
        if changed == 0 {
            return 0;
        }
        self.commit();
        self.checkpoint();
        for (index, rgba) in slots {
            self.palette[*index as usize] = *rgba;
        }
        self.commit();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        changed
    }

    /// Save every object. An untitled document asks for a path.
    pub fn save(&mut self) {
        match self.path.clone() {
            Some(path) => {
                let _ = self.write_vox(&path);
            }
            None => self.save_as(),
        }
    }

    pub fn save_as(&mut self) {
        let name = match self.path.as_ref().and_then(|p| p.file_name()) {
            Some(name) => name.to_string_lossy().into_owned(),
            None => format!("{}.vox", self.active().name),
        };
        let Some(path) = rfd::FileDialog::new()
            .add_filter("MagicaVoxel", &["vox"])
            .set_file_name(name)
            .save_file()
        else {
            return;
        };
        let _ = self.write_vox(&ensure_vox_extension(path));
    }

    pub(crate) fn write_vox(&mut self, path: &Path) -> Result<(), String> {
        let count: usize = self.objects.iter().map(|object| object.cells.len()).sum();
        let saved = self
            .objects
            .iter()
            .filter(|object| !object.cells.is_empty())
            .count();
        let bytes = match save_scene(&self.objects, &self.palette, &self.materials) {
            Ok(bytes) => bytes,
            Err(e) => {
                self.status = e.clone();
                return Err(e);
            }
        };
        if let Err(e) = std::fs::write(path, bytes) {
            let message = format!("Could not write {}: {e}", path.display());
            self.status = message.clone();
            return Err(message);
        }
        self.path = Some(path.to_path_buf());
        let file = path
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.display().to_string());
        self.status = if saved > 1 {
            format!("Saved {count} voxels in {saved} objects to {file}.")
        } else {
            format!("Saved {count} voxels to {file}.")
        };
        self.remember_path(path);
        Ok(())
    }

    pub fn export_mesh_dialog(&mut self) {
        let name = format!("{}.glb", self.active().name);
        let Some(path) = rfd::FileDialog::new()
            .add_filter("glTF", &["glb"])
            .set_file_name(name)
            .save_file()
        else {
            return;
        };
        let path = ensure_glb(path);
        match crate::export::export_glb(self, &path) {
            Ok(quads) => {
                let file = path
                    .file_name()
                    .map(|s| s.to_string_lossy().into_owned())
                    .unwrap_or_else(|| path.display().to_string());
                self.status = format!("Exported {quads} quads to {file}.");
            }
            Err(err) => self.status = err,
        }
    }

    pub fn recent_paths(&self) -> Vec<PathBuf> {
        self.recent.clone()
    }

    fn remember_path(&mut self, path: &Path) {
        remember(&mut self.recent, path);
        store_recent(&self.recent);
    }

    pub fn clear_ui(&mut self) {
        self.ui_regions.clear();
    }

    pub fn note_ui(&mut self, id: &str, label: &str, rect: egui::Rect, action: UiAction) {
        self.ui_regions.push(UiRegion {
            id: id.to_string(),
            label: label.to_string(),
            x: rect.min.x,
            y: rect.min.y,
            w: rect.width(),
            h: rect.height(),
            action,
        });
    }

    /// Topmost registered control under a window point. `None` actions,
    /// such as the window rectangle, are not click targets.
    pub fn ui_target(&self, x: f32, y: f32) -> Option<UiRegion> {
        self.ui_regions
            .iter()
            .rev()
            .find(|region| region.action != UiAction::None && region.contains(x, y))
            .cloned()
    }

    pub fn activate_ui(&mut self, region: &UiRegion) -> Result<(), String> {
        match region.action {
            UiAction::None | UiAction::Viewport => {}
            UiAction::Tool(tool) => self.tool = tool,
            UiAction::Mode(mode) => self.tool_mode = mode,
            UiAction::Editor(mode) => self.editor_mode = mode,
            UiAction::Render(mode) => self.render_mode = mode,
            UiAction::NewObject => self.new_object(),
            UiAction::Duplicate => self.duplicate_object(),
            UiAction::DeleteObject => {
                if self.objects.len() < 2 {
                    return Err("the only object cannot be deleted".into());
                }
                self.delete_object();
            }
        }
        Ok(())
    }

    /// Press and release at one world ray, so a connected click can stamp
    /// the active tool without a second frame.
    pub(crate) fn click_viewport(&mut self, ray: (Vec3, Vec3)) {
        let drag = ToolDrag {
            rays: vec![ray],
            face_steps: 1,
            marquee: None,
            shift: false,
            object_band: None,
        };
        self.pointer(
            true,
            true,
            true,
            true,
            false,
            false,
            false,
            false,
            false,
            glam::Vec2::ZERO,
            0.0,
            Some(ray),
            &drag,
            false,
        );
    }

    pub fn describe_ui(&self) -> serde_json::Value {
        let window = self.ui_regions.iter().find(|region| region.id == "window");
        let regions: Vec<serde_json::Value> = self
            .ui_regions
            .iter()
            .filter(|region| region.action != UiAction::None)
            .map(|region| {
                serde_json::json!({
                    "id": region.id,
                    "label": region.label,
                    "x": region.x,
                    "y": region.y,
                    "width": region.w,
                    "height": region.h,
                })
            })
            .collect();
        serde_json::json!({
            "tool": self.tool.name(),
            "toolMode": match self.tool_mode {
                ToolMode::Add => "Add",
                ToolMode::Remove => "Remove",
                ToolMode::Paint => "Paint",
            },
            "editorMode": match self.editor_mode {
                EditorMode::Model => "Model",
                EditorMode::Object => "Object",
            },
            "renderMode": match self.render_mode {
                RenderMode::Edit => "Edit",
                RenderMode::Render => "Render",
            },
            "activeObject": self.active().name,
            "voxels": self.voxel_count(),
            "status": self.status,
            "window": window.map(|region| serde_json::json!({
                "x": region.x,
                "y": region.y,
                "width": region.w,
                "height": region.h,
            })),
            "regions": regions,
        })
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
        let translation = beside(self.active());
        self.objects.push(Volume {
            name,
            cells: HashMap::new(),
            translation,
        });
        self.selected = self.objects.len() - 1;
        self.focus_object();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.commit();
    }

    pub fn duplicate_object(&mut self) {
        self.commit();
        self.checkpoint();
        let copy = Volume {
            name: format!("{} copy", self.active().name),
            cells: self.active().cells.clone(),
            translation: beside(self.active()),
        };
        self.objects.insert(self.selected + 1, copy);
        self.selected += 1;
        self.focus_object();
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
        self.focus_object();
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
        if index >= self.objects.len() {
            return;
        }
        if index != self.selected {
            self.selected = index;
            self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
            self.clear_picked();
        }
        self.focus_object();
    }

    fn focus_object(&mut self) {
        if self.objects.is_empty() {
            self.object_selection.clear();
            return;
        }
        self.selected = self.selected.min(self.objects.len() - 1);
        self.object_selection = vec![self.selected];
    }

    fn choose_objects(&mut self, mut members: Vec<usize>, primary: usize) {
        members.retain(|index| *index < self.objects.len());
        members.sort_unstable();
        members.dedup();
        if members.is_empty() {
            self.focus_object();
            return;
        }
        self.object_selection = members;
        self.selected = if self.object_selection.contains(&primary) {
            primary
        } else {
            self.object_selection[self.object_selection.len() - 1]
        };
        self.clear_picked();
    }

    fn toggle_object(&mut self, index: usize) {
        if index >= self.objects.len() {
            return;
        }
        if let Some(pos) = self.object_selection.iter().position(|i| *i == index) {
            if self.object_selection.len() == 1 {
                return;
            }
            self.object_selection.remove(pos);
            if self.selected == index {
                self.selected = self.object_selection[self.object_selection.len() - 1];
                self.clear_picked();
            }
            return;
        }
        self.object_selection.push(index);
        self.selected = index;
        self.clear_picked();
    }

    fn snapshot(&self) -> Snapshot {
        Snapshot {
            objects: self.objects.clone(),
            palette: self.palette,
        }
    }

    fn restore(&mut self, snap: Snapshot) -> Snapshot {
        Snapshot {
            objects: std::mem::replace(&mut self.objects, snap.objects),
            palette: std::mem::replace(&mut self.palette, snap.palette),
        }
    }

    fn checkpoint(&mut self) {
        if self.pending.is_none() {
            self.pending = Some(self.snapshot());
        }
    }

    fn commit(&mut self) {
        if let Some(prev) = self.pending.take() {
            if prev.objects != self.objects || prev.palette != self.palette {
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
        let cur = self.restore(prev);
        self.clamp_selection();
        if cur.objects != self.objects {
            self.clear_picked();
        }
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.redo.push(cur);
    }

    pub fn redo(&mut self) {
        self.commit();
        let Some(next) = self.redo.pop() else {
            return;
        };
        let cur = self.restore(next);
        self.clamp_selection();
        if cur.objects != self.objects {
            self.clear_picked();
        }
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.undo.push(cur);
    }

    fn clamp_selection(&mut self) {
        if self.objects.is_empty() {
            self.objects.push(Volume {
                name: "Object".into(),
                cells: HashMap::new(),
                translation: (0, 0, 0),
            });
        }
        self.selected = self.selected.min(self.objects.len() - 1);
        self.object_selection
            .retain(|index| *index < self.objects.len());
        if !self.object_selection.contains(&self.selected) {
            self.object_selection.push(self.selected);
        }
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
        drag: &ToolDrag,
        command: bool,
    ) {
        let world_ray = ray;
        let aimed = world_ray.and_then(|(origin, dir)| self.pick_object(origin, dir));
        let ray = self.local_ray(world_ray);
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
            } else if self.editor_mode == EditorMode::Object {
                if self.render_mode != RenderMode::Edit {
                    self.grab = Grab::None;
                    self.status = self.blocked_reason();
                } else {
                    match self.begin_object_move(world_ray, drag.shift) {
                        ObjectPress::Drag => self.grab = Grab::Object,
                        ObjectPress::Marquee => self.grab = Grab::ObjectMarquee,
                        ObjectPress::Idle => self.grab = Grab::None,
                    }
                }
            } else if let Some((index, _)) = aimed.filter(|(index, _)| *index != self.selected) {
                self.select_object(index);
                self.grab = Grab::None;
            } else if command && self.begin_move(ray) {
                self.grab = Grab::Move;
            } else if self.can_edit() {
                self.grab = Grab::Paint;
                self.checkpoint();
                if self.status_is_blocked() {
                    self.status = IDLE.into();
                }
            } else if self.can_select() {
                self.grab = Grab::Select;
                self.begin_select(ray);
            } else {
                self.grab = Grab::None;
                self.status = self.blocked_reason();
            }
        }

        match self.grab {
            Grab::Orbit if secondary_down => self.orbit(delta.x, delta.y),
            Grab::Pan if middle_down || primary_down => self.pan(delta.x, delta.y),
            Grab::Paint if primary_down => self.apply_stroke(ray, drag),
            Grab::Select if primary_down => self.drag_select(ray),
            Grab::Move if primary_down => self.drag_move(ray),
            Grab::Object if primary_down => self.drag_object(world_ray),
            _ => {}
        }

        if primary_released && self.grab == Grab::Paint {
            // The release frame is not "down", but it carries the end of the drag.
            self.apply_stroke(ray, drag);
            self.stroke = None;
            self.commit();
            self.grab = Grab::None;
        }
        if primary_released && self.grab == Grab::Select {
            self.finish_select(ray, drag);
            self.grab = Grab::None;
        }
        if primary_released && self.grab == Grab::Move {
            self.drag_move(ray);
            self.move_drag = None;
            self.commit();
            self.grab = Grab::None;
        }
        if primary_released && self.grab == Grab::Object {
            self.drag_object(world_ray);
            let changed = self.object_drag.as_ref().is_some_and(|drag| drag.changed);
            self.object_drag = None;
            if changed {
                self.commit();
            }
            self.grab = Grab::None;
        }
        if primary_released && self.grab == Grab::ObjectMarquee {
            if let Some(band) = &drag.object_band {
                self.finish_object_band(band, drag.shift);
            }
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

    fn can_select(&self) -> bool {
        matches!(
            self.tool,
            Tool::Marquee | Tool::BoxSelect | Tool::FloodSelect
        ) && self.editor_mode == EditorMode::Model
            && self.render_mode == RenderMode::Edit
    }

    fn can_edit(&self) -> bool {
        self.edits_voxels()
            && self.editor_mode == EditorMode::Model
            && self.render_mode == RenderMode::Edit
    }

    fn edits_voxels(&self) -> bool {
        matches!(
            self.tool,
            Tool::Brush
                | Tool::Line
                | Tool::Circle
                | Tool::Square
                | Tool::Box
                | Tool::Face
                | Tool::Generator
                | Tool::Mutator
        )
    }

    fn status_is_blocked(&self) -> bool {
        self.status.contains("does not edit") || self.status.contains("Path tracing stays")
    }

    fn blocked_reason(&self) -> String {
        if self.render_mode == RenderMode::Render {
            "Render mode keeps the shaded voxels. Path tracing stays in the Metal app.".into()
        } else {
            format!(
                "{} does not edit voxels in this preview yet.",
                self.tool.name()
            )
        }
    }

    /// Anchor of a face stroke, so the viewport can turn mouse movement
    /// into an extrusion distance.
    pub fn stroke_face(&self) -> Option<(Cell, i32, i32)> {
        self.stroke
            .as_ref()
            .filter(|_| self.tool == Tool::Face)
            .map(|stroke| (stroke.anchor.cell, stroke.axis, stroke.sign))
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

    fn apply_stroke(&mut self, ray: Option<(Vec3, Vec3)>, drag: &ToolDrag) {
        let Some((origin, dir)) = ray else {
            return;
        };
        if self.tool == Tool::Brush {
            if let Some(hit) = raycast(&self.active().cells, origin, dir) {
                self.stamp(hit);
            }
        } else {
            self.preview_tool(origin, dir, &drag.rays, drag.face_steps);
        }
    }

    fn preview_tool(&mut self, origin: Vec3, dir: Vec3, rays: &[(Vec3, Vec3)], face_steps: i32) {
        let hit = self.pick_for_stroke(origin, dir);
        let Some(hit) = hit else {
            return;
        };
        if self.stroke.is_none() {
            self.begin_stroke(hit);
        }
        let Some(stroke) = self.stroke.as_ref() else {
            return;
        };
        let end = self.place(hit);
        let stamp = self.drag_stamp();
        if stroke.key == Some((end, face_steps, stamp)) {
            return;
        }
        let anchor = self.place(stroke.anchor);
        let axis = stroke.axis;
        let sign = stroke.sign;
        let seeds = stroke.seeds.clone();
        let base = stroke.base.clone();
        let stroke_id = stroke.id;
        let centers = match self.tool {
            Tool::Line if self.line_mode == LineMode::Project && !rays.is_empty() => {
                self.project_line(&base, rays)
            }
            Tool::Line => crate::tools::bresenham(anchor, end),
            Tool::Circle => {
                crate::tools::circle(anchor, end, axis, self.circle_fill, self.circle_even)
            }
            Tool::Square => {
                crate::tools::square(anchor, end, axis, self.square_fill, self.square_even)
            }
            Tool::Box => crate::tools::cube(anchor, end, self.box_fill),
            Tool::Face => {
                let steps = if self.tool_mode == ToolMode::Add {
                    if face_steps == 0 {
                        1
                    } else {
                        face_steps
                    }
                } else {
                    face_steps.abs().max(1)
                };
                let outward = self.tool_mode == ToolMode::Add && steps > 0;
                let n = steps.abs();
                crate::tools::extrude(&seeds, axis, sign, n, outward)
            }
            Tool::Generator => Vec::new(),
            Tool::Mutator => {
                let offsets = footprint(self.brush_size, self.brush_shape, self.brush_3d);
                let mapped = map_footprint(&offsets, axis);
                crate::tools::foliage(
                    &base,
                    hit.cell,
                    &mapped,
                    self.foliage_seed.clamp(1, 255) as u8,
                    self.foliage_density.clamp(0.0, 1.0),
                    stroke_id,
                )
            }
            _ => Vec::new(),
        };
        let edits = if self.tool == Tool::Generator {
            let min = (
                anchor.0.min(end.0),
                anchor.1.min(end.1),
                anchor.2.min(end.2),
            );
            let max = (
                anchor.0.max(end.0),
                anchor.1.max(end.1),
                anchor.2.max(end.2),
            );
            {
                let gen = self.gen_params();
                let filled = crate::tools::generate(min, max, &gen);
                if filled.is_empty()
                    && (max.0 - min.0 + 1) as i64
                        * (max.1 - min.1 + 1) as i64
                        * (max.2 - min.2 + 1) as i64
                        > crate::tools::MAX_GENERATOR_CELLS
                {
                    self.status = "That box is too large to fill.".into();
                }
                filled
            }
        } else if self.tool == Tool::Mutator {
            let seed = self.foliage_seed.clamp(1, 255) as u8;
            centers.into_iter().map(|cell| (cell, seed)).collect()
        } else if self.tool == Tool::Face {
            centers
                .into_iter()
                .map(|cell| {
                    let slot = if self.tool_mode == ToolMode::Add && face_steps < 0 {
                        0
                    } else if self.face_with == FaceWith::Geometry
                        && self.tool_mode == ToolMode::Add
                    {
                        let back = match axis {
                            0 => (-sign, 0, 0),
                            1 => (0, -sign, 0),
                            _ => (0, 0, -sign),
                        };
                        let mut cursor = cell;
                        for _ in 0..64 {
                            if seeds.iter().any(|seed| *seed == cursor) {
                                break;
                            }
                            cursor = crate::tools::add(cursor, back);
                        }
                        base.get(&cursor).copied().unwrap_or(self.active_slot)
                    } else {
                        self.paint_slot()
                    };
                    (cell, slot)
                })
                .collect()
        } else {
            let expanded = expand_centers(
                &centers,
                &footprint(self.brush_size, self.brush_shape, self.brush_3d),
                axis,
            );
            expanded
                .into_iter()
                .map(|cell| (cell, self.paint_slot()))
                .collect()
        };
        self.write_preview(base, edits);
        if let Some(stroke) = self.stroke.as_mut() {
            stroke.key = Some((end, face_steps, stamp));
        }
    }

    fn begin_stroke(&mut self, hit: Hit) {
        let (axis, sign) = face_axis(hit.normal);
        let base = self.active().cells.clone();
        let seeds = if self.tool == Tool::Face {
            if base.contains_key(&hit.cell) {
                let match_color = if self.face_extrude == FaceExtrude::Color {
                    base.get(&hit.cell).copied().unwrap_or(0)
                } else {
                    0
                };
                crate::tools::flood_face(&base, hit.cell, axis, sign, match_color, self.face_eight)
            } else if let Some((min, max)) = cell_bounds(base.keys().copied()) {
                let (u_axis, v_axis) = crate::tools::plane_axes(axis);
                let flooded = crate::tools::flood_empty(
                    &base,
                    hit.cell,
                    axis,
                    crate::tools::coord(min, u_axis),
                    crate::tools::coord(max, u_axis),
                    crate::tools::coord(min, v_axis),
                    crate::tools::coord(max, v_axis),
                    self.face_eight,
                );
                let back = crate::tools::axis_delta(axis, -sign);
                flooded
                    .into_iter()
                    .map(|cell| crate::tools::add(cell, back))
                    .collect()
            } else {
                Vec::new()
            }
        } else {
            Vec::new()
        };
        self.stroke_serial = self.stroke_serial.wrapping_add(1);
        self.stroke = Some(Stroke {
            anchor: hit,
            base,
            seeds,
            axis,
            sign,
            id: self.stroke_serial,
            key: None,
        });
    }

    fn pick_for_stroke(&self, origin: Vec3, dir: Vec3) -> Option<Hit> {
        let cells = if let Some(stroke) = &self.stroke {
            &stroke.base
        } else {
            &self.active().cells
        };
        if let Some(hit) = raycast(cells, origin, dir) {
            return Some(hit);
        }
        if let Some(stroke) = &self.stroke {
            return plane_hit(origin, dir, stroke.anchor);
        }
        if self.tool == Tool::Face {
            return wall_hit(cells, origin, dir);
        }
        None
    }

    fn project_line(&self, base: &HashMap<Cell, u8>, rays: &[(Vec3, Vec3)]) -> Vec<Cell> {
        let mut seen = HashSet::new();
        let mut out = Vec::new();
        for (origin, dir) in rays {
            let Some(hit) = raycast(base, *origin, *dir) else {
                continue;
            };
            let cell = self.place(hit);
            if seen.insert(cell) {
                out.push(cell);
            }
        }
        out
    }

    fn place(&self, hit: Hit) -> Cell {
        match self.tool_mode {
            ToolMode::Add => crate::tools::add(hit.cell, hit.normal),
            ToolMode::Remove | ToolMode::Paint => hit.cell,
        }
    }

    fn paint_slot(&self) -> u8 {
        match self.tool_mode {
            ToolMode::Remove => 0,
            ToolMode::Add | ToolMode::Paint => self.active_slot,
        }
    }

    fn write_preview(&mut self, base: HashMap<Cell, u8>, edits: Vec<(Cell, u8)>) {
        let mut next = base.clone();
        let mode = if self.tool == Tool::Mutator {
            ToolMode::Add
        } else {
            self.tool_mode
        };
        for (cell, slot) in edits {
            match mode {
                ToolMode::Add => {
                    if slot == 0 {
                        next.remove(&cell);
                    } else if !base.contains_key(&cell) {
                        next.insert(cell, slot);
                    }
                }
                ToolMode::Remove => {
                    next.remove(&cell);
                }
                ToolMode::Paint => {
                    if base.contains_key(&cell) && slot != 0 {
                        next.insert(cell, slot);
                    }
                }
            }
        }
        if next != self.active().cells {
            self.active_mut().cells = next;
            self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        }
    }

    fn gen_params(&self) -> crate::tools::Gen {
        crate::tools::Gen {
            kind: self.generator,
            axis: self.gen_axis,
            apex_at_max: self.apex_at_max,
            palette: self.active_slot,
            torus_tube: self.torus_tube,
            helix_turns: self.helix_turns,
            helix_radius: self.helix_radius,
            helix_tube: self.helix_tube,
            helix_cw: self.helix_cw,
            noise_scale: self.noise_scale,
            noise_threshold: self.noise_threshold,
            noise_octaves: self.noise_octaves,
            noise_seed: self.noise_seed as u32,
            perlin_lo: self.perlin_lo,
            perlin_hi: self.perlin_hi,
            tree_depth: self.tree_depth,
            tree_wildness: self.tree_wildness,
            tree_trunk: self.tree_trunk,
            tree_leaf: self.tree_leaf,
            tree_seed: self.tree_seed as u32,
            conifer_tiers: self.conifer_tiers,
            conifer_ragged: self.conifer_ragged,
            conifer_clump: self.conifer_clump,
            conifer_trunk: self.conifer_trunk,
            conifer_crown: self.conifer_crown,
            conifer_needle: self.conifer_needle,
            conifer_seed: self.conifer_seed as u32,
        }
    }

    fn drag_stamp(&self) -> u64 {
        let mode = match self.tool_mode {
            ToolMode::Add => 1u64,
            ToolMode::Remove => 2,
            ToolMode::Paint => 3,
        };
        let mut h = mode;
        h = h
            .wrapping_mul(16777619)
            .wrapping_add(self.brush_size as u64);
        h = h
            .wrapping_mul(16777619)
            .wrapping_add(self.active_slot as u64);
        h = h
            .wrapping_mul(16777619)
            .wrapping_add(self.circle_fill as u64);
        h = h.wrapping_mul(16777619).wrapping_add(self.box_fill as u64);
        h = h
            .wrapping_mul(16777619)
            .wrapping_add(self.foliage_seed as u64);
        h = h
            .wrapping_mul(16777619)
            .wrapping_add(self.generator.name().len() as u64);
        h = h
            .wrapping_mul(16777619)
            .wrapping_add(self.tree_depth as u64);
        h = h
            .wrapping_mul(16777619)
            .wrapping_add(self.noise_seed as u64);
        h
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
        if !self.picked.is_empty() {
            let pivot = min_corner(self.picked.iter().copied());
            self.map_picked(|c| {
                let p = (c.0 - pivot.0, c.1 - pivot.1, c.2 - pivot.2);
                let q = rot90(p, axis, clockwise);
                (q.0 + pivot.0, q.1 + pivot.1, q.2 + pivot.2)
            });
            return;
        }
        if self.active().cells.is_empty() {
            return;
        }
        self.checkpoint();
        let cells = std::mem::take(&mut self.active_mut().cells);
        let pivot = min_corner(cells.keys().copied());
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

    /// 90° about a world axis, around the center of the occupied span.
    /// Local cells move; the translation of that center stays put.
    pub fn rotate_object(&mut self, axis: Axis, clockwise: bool) {
        let name = axis_name(axis);
        let verb = if clockwise {
            "clockwise"
        } else {
            "counterclockwise"
        };
        self.transform_object(
            |c, pivot| {
                let p = (c.0 - pivot.0, c.1 - pivot.1, c.2 - pivot.2);
                let q = rot90(p, axis, clockwise);
                (q.0 + pivot.0, q.1 + pivot.1, q.2 + pivot.2)
            },
            &format!("Rotated the object 90° {verb} about {name}."),
        );
    }

    /// Mirror across the plane through the span center, perpendicular to `axis`.
    pub fn flip_object(&mut self, axis: Axis) {
        let name = axis_name(axis);
        self.transform_object(
            |c, pivot| match axis {
                Axis::X => (pivot.0 * 2 - c.0, c.1, c.2),
                Axis::Y => (c.0, pivot.1 * 2 - c.1, c.2),
                Axis::Z => (c.0, c.1, pivot.2 * 2 - c.2),
            },
            &format!("Flipped the object across {name}."),
        );
    }

    fn transform_object(&mut self, map: impl Fn(Cell, Cell) -> Cell, status: &str) {
        let members: Vec<usize> = self
            .object_selection
            .iter()
            .copied()
            .filter(|index| {
                self.objects
                    .get(*index)
                    .is_some_and(|volume| !volume.cells.is_empty())
            })
            .collect();
        let members = if members.is_empty() {
            if self.active().cells.is_empty() {
                return;
            }
            vec![self.selected]
        } else {
            members
        };
        let mut lo = (i32::MAX, i32::MAX, i32::MAX);
        let mut hi = (i32::MIN, i32::MIN, i32::MIN);
        for index in &members {
            let Some((min, max)) = world_extents(&self.objects[*index]) else {
                continue;
            };
            lo = (lo.0.min(min.0), lo.1.min(min.1), lo.2.min(min.2));
            hi = (hi.0.max(max.0), hi.1.max(max.1), hi.2.max(max.2));
        }
        let pivot = (
            span_center(lo.0, hi.0),
            span_center(lo.1, hi.1),
            span_center(lo.2, hi.2),
        );
        let mut rewritten = Vec::with_capacity(members.len());
        let mut changed = false;
        for index in &members {
            let volume = &self.objects[*index];
            let shift = volume.translation;
            let mut next = HashMap::with_capacity(volume.cells.len());
            for (cell, slot) in &volume.cells {
                let world = (cell.0 + shift.0, cell.1 + shift.1, cell.2 + shift.2);
                let moved = map(world, pivot);
                next.insert(
                    (moved.0 - shift.0, moved.1 - shift.1, moved.2 - shift.2),
                    *slot,
                );
            }
            changed |= next != volume.cells;
            rewritten.push((*index, next));
        }
        if !changed {
            return;
        }
        self.checkpoint();
        for (index, next) in rewritten {
            self.objects[index].cells = next;
        }
        self.clear_picked();
        self.commit();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.status = status.to_string();
    }

    pub fn flip_selection(&mut self, axis: Axis) {
        if !self.picked.is_empty() {
            let (min, max) = extents(self.picked.iter().copied());
            self.map_picked(|c| mirror(c, axis, min, max));
            return;
        }
        if self.active().cells.is_empty() {
            return;
        }
        self.checkpoint();
        let cells = std::mem::take(&mut self.active_mut().cells);
        let (min, max) = extents(cells.keys().copied());
        let mut next = HashMap::with_capacity(cells.len());
        for (c, v) in cells {
            next.insert(mirror(c, axis, min, max), v);
        }
        self.active_mut().cells = next;
        self.commit();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
    }

    pub fn delete_picked(&mut self) {
        if self.picked.is_empty() {
            return;
        }
        self.checkpoint();
        let picked = std::mem::take(&mut self.picked);
        {
            let map = &mut self.active_mut().cells;
            for cell in &picked {
                map.remove(cell);
            }
        }
        self.commit();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.note_selection();
    }

    /// Selected cells only, relative to their minimum corner. Empty slots in
    /// the bounding box are not stored, so paste does not erase neighbors.
    pub fn copy_picked(&mut self) {
        if self.picked.is_empty() {
            return;
        }
        let origin = min_corner(self.picked.iter().copied());
        let mut cells = Vec::new();
        for cell in &self.picked {
            let Some(&slot) = self.active().cells.get(cell) else {
                continue;
            };
            if slot == 0 {
                continue;
            }
            cells.push((
                (cell.0 - origin.0, cell.1 - origin.1, cell.2 - origin.2),
                slot,
            ));
        }
        if cells.is_empty() {
            return;
        }
        let n = cells.len();
        self.clipboard = Some(VoxelClipboard { origin, cells });
        self.status = format!("Copied {n} voxels.");
    }

    pub fn cut_picked(&mut self) {
        if self.picked.is_empty() {
            return;
        }
        self.copy_picked();
        let n = self
            .clipboard
            .as_ref()
            .map(|clip| clip.cells.len())
            .unwrap_or(0);
        self.delete_picked();
        if n > 0 {
            self.status = format!("Cut {n} voxels.");
        }
    }

    /// Writes the clipboard onto the hovered face, or back at its original
    /// origin when the pointer is not on a voxel. The pasted cells become
    /// the selection.
    pub fn paste_clipboard(&mut self) {
        let Some(clip) = self.clipboard.clone() else {
            return;
        };
        let origin = self.paste_origin(&clip);
        self.checkpoint();
        let mut pasted = HashSet::with_capacity(clip.cells.len());
        {
            let map = &mut self.active_mut().cells;
            for (offset, slot) in &clip.cells {
                let at = (
                    origin.0 + offset.0,
                    origin.1 + offset.1,
                    origin.2 + offset.2,
                );
                map.insert(at, *slot);
                pasted.insert(at);
            }
        }
        self.picked = pasted;
        self.commit();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.note_selection();
    }

    fn paste_origin(&self, clip: &VoxelClipboard) -> Cell {
        match self.hover {
            Some(hit) => (
                hit.cell.0 + hit.normal.0,
                hit.cell.1 + hit.normal.1,
                hit.cell.2 + hit.normal.2,
            ),
            None => clip.origin,
        }
    }

    /// Cmd-drag. The clicked face's axis stays fixed; the selection slides
    /// on that plane by whole voxels. Returns false when the click missed
    /// the selection, so the active tool still runs.
    fn begin_move(&mut self, ray: Option<(Vec3, Vec3)>) -> bool {
        if self.picked.is_empty()
            || self.editor_mode != EditorMode::Model
            || self.render_mode != RenderMode::Edit
        {
            return false;
        }
        let Some((origin, dir)) = ray else {
            return false;
        };
        let Some(hit) = raycast(&self.active().cells, origin, dir) else {
            return false;
        };
        if !self.picked.contains(&hit.cell) {
            return false;
        }
        let (axis, sign) = face_axis(hit.normal);
        let plane = match axis {
            0 => hit.cell.0 as f32 + if sign > 0 { 1.0 } else { 0.0 },
            1 => hit.cell.1 as f32 + if sign > 0 { 1.0 } else { 0.0 },
            _ => hit.cell.2 as f32 + if sign > 0 { 1.0 } else { 0.0 },
        };
        let Some(anchor) = intersect_axis_plane(origin, dir, axis, plane) else {
            return false;
        };
        self.checkpoint();
        self.move_drag = Some(MoveDrag {
            axis,
            plane,
            anchor,
            base_cells: self.active().cells.clone(),
            base_picked: self.picked.iter().copied().collect(),
            applied: (0, 0, 0),
        });
        true
    }

    fn drag_move(&mut self, ray: Option<(Vec3, Vec3)>) {
        let Some(drag) = self.move_drag.as_ref() else {
            return;
        };
        let Some((origin, dir)) = ray else {
            return;
        };
        let Some(hit) = intersect_axis_plane(origin, dir, drag.axis, drag.plane) else {
            return;
        };
        let delta = plane_delta(drag.axis, drag.anchor, hit);
        if delta == drag.applied {
            return;
        }
        let axis = drag.axis;
        let plane = drag.plane;
        let anchor = drag.anchor;
        let base_cells = drag.base_cells.clone();
        let base_picked = drag.base_picked.clone();
        let (next, picked) = translate_cells(&base_cells, &base_picked, delta);
        self.active_mut().cells = next;
        self.picked = picked;
        self.move_drag = Some(MoveDrag {
            axis,
            plane,
            anchor,
            base_cells,
            base_picked,
            applied: delta,
        });
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.selection_epoch = self.selection_epoch.wrapping_add(1);
    }

    /// Object mode. A hit keeps the rubber-band set when the object is
    /// already in it, and slides every member by the same voxel steps.
    /// Shift toggles membership and does not drag. A miss starts a marquee.
    fn begin_object_move(&mut self, ray: Option<(Vec3, Vec3)>, shift: bool) -> ObjectPress {
        let Some((origin, dir)) = ray else {
            return ObjectPress::Idle;
        };
        let aimed = self.pick_object(origin, dir);
        if shift {
            if let Some((index, _)) = aimed {
                self.toggle_object(index);
            }
            return ObjectPress::Idle;
        }
        let locked = self.hover_gizmo.filter(|axis| (0..3).contains(axis));
        let Some((index, hit)) = aimed.or_else(|| {
            if locked.is_some() {
                Some((
                    self.selected,
                    Hit {
                        cell: (0, 0, 0),
                        normal: (0, 0, 1),
                    },
                ))
            } else {
                None
            }
        }) else {
            return ObjectPress::Marquee;
        };
        if index >= self.objects.len() {
            return ObjectPress::Idle;
        }
        if self.object_selection.contains(&index) {
            if index != self.selected {
                self.selected = index;
                self.clear_picked();
            }
        } else {
            self.select_object(index);
        }
        let translation = self.objects[index].translation;
        let (plane_axis, sign) = face_axis(hit.normal);
        let local_plane = match plane_axis {
            0 => hit.cell.0 as f32 + if sign > 0 { 1.0 } else { 0.0 },
            1 => hit.cell.1 as f32 + if sign > 0 { 1.0 } else { 0.0 },
            _ => hit.cell.2 as f32 + if sign > 0 { 1.0 } else { 0.0 },
        };
        let plane = local_plane
            + match plane_axis {
                0 => translation.0 as f32,
                1 => translation.1 as f32,
                _ => translation.2 as f32,
            };
        let anchor = if locked.is_some() {
            self.object_center().unwrap_or(Vec3::ZERO)
        } else {
            let Some(point) = intersect_axis_plane(origin, dir, plane_axis, plane) else {
                return ObjectPress::Idle;
            };
            point
        };
        let forward = (self.target - self.eye()).normalize_or_zero();
        let normal = if forward.length_squared() < 1e-8 {
            Vec3::Z
        } else {
            forward
        };
        let bases = self
            .object_selection
            .iter()
            .copied()
            .filter(|member| *member < self.objects.len())
            .map(|member| (member, self.objects[member].translation))
            .collect();
        self.object_drag = Some(ObjectDrag {
            index,
            locked,
            plane_axis,
            plane,
            anchor,
            normal,
            base: translation,
            bases,
            changed: false,
        });
        ObjectPress::Drag
    }

    fn drag_object(&mut self, ray: Option<(Vec3, Vec3)>) {
        let Some(drag) = self.object_drag.clone() else {
            return;
        };
        let Some((origin, dir)) = ray else {
            return;
        };
        let next = if let Some(axis) = drag.locked {
            let Some(hit) = intersect_plane(origin, dir, drag.anchor, drag.normal) else {
                return;
            };
            let along = match axis {
                0 => hit.x - drag.anchor.x,
                1 => hit.y - drag.anchor.y,
                _ => hit.z - drag.anchor.z,
            };
            let steps = along.round() as i32;
            match axis {
                0 => (drag.base.0 + steps, drag.base.1, drag.base.2),
                1 => (drag.base.0, drag.base.1 + steps, drag.base.2),
                _ => (drag.base.0, drag.base.1, drag.base.2 + steps),
            }
        } else {
            let Some(hit) = intersect_axis_plane(origin, dir, drag.plane_axis, drag.plane) else {
                return;
            };
            let delta = plane_delta(drag.plane_axis, drag.anchor, hit);
            (
                drag.base.0 + delta.0,
                drag.base.1 + delta.1,
                drag.base.2 + delta.2,
            )
        };
        if self.objects.get(drag.index).is_none() {
            return;
        }
        let delta = (
            next.0 - drag.base.0,
            next.1 - drag.base.1,
            next.2 - drag.base.2,
        );
        if delta == (0, 0, 0) {
            return;
        }
        if !drag.changed {
            self.checkpoint();
        }
        for (member, base) in &drag.bases {
            if let Some(volume) = self.objects.get_mut(*member) {
                volume.translation = (base.0 + delta.0, base.1 + delta.1, base.2 + delta.2);
            }
        }
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.object_drag = Some(ObjectDrag {
            changed: true,
            ..drag
        });
    }

    fn finish_object_band(&mut self, band: &ObjectBand, shift: bool) {
        if band.click {
            if !shift {
                self.focus_object();
            }
            return;
        }
        let mut members = if shift {
            self.object_selection.clone()
        } else {
            Vec::new()
        };
        for index in &band.hits {
            if !members.contains(index) {
                members.push(*index);
            }
        }
        let primary = if members.contains(&self.selected) {
            self.selected
        } else {
            band.hits.last().copied().unwrap_or(self.selected)
        };
        self.choose_objects(members, primary);
        let count = self.object_selection.len();
        self.status = if count == 1 {
            "1 object selected.".into()
        } else {
            format!("{count} objects selected.")
        };
    }

    fn object_center(&self) -> Option<Vec3> {
        let (min, max) = self.bounds()?;
        let translation = self.active().translation;
        Some(Vec3::new(
            (min.0 + max.0) as f32 * 0.5 + 0.5 + translation.0 as f32,
            (min.1 + max.1) as f32 * 0.5 + 0.5 + translation.1 as f32,
            (min.2 + max.2) as f32 * 0.5 + 0.5 + translation.2 as f32,
        ))
    }

    /// Shrink one axis of the active object, clipping voxels past the new
    /// size. The minimum corner stays put. A larger value leaves the voxels
    /// alone: the size is the occupied span, not an empty margin.
    pub fn resize_active(&mut self, axis: usize, new_size: i32) {
        if axis > 2 {
            return;
        }
        let new_size = new_size.clamp(1, 256);
        let Some((min, max)) = self.bounds() else {
            return;
        };
        let min_axis = [min.0, min.1, min.2];
        let max_axis = [max.0, max.1, max.2];
        let current = max_axis[axis] - min_axis[axis] + 1;
        if new_size >= current {
            return;
        }
        self.checkpoint();
        let limit = min_axis[axis] + new_size;
        let cells = std::mem::take(&mut self.active_mut().cells);
        self.active_mut().cells = cells
            .into_iter()
            .filter(|(cell, _)| {
                let coord = [cell.0, cell.1, cell.2][axis];
                coord < limit
            })
            .collect();
        self.clear_picked();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.commit();
    }

    pub fn deselect(&mut self) {
        if self.picked.is_empty() {
            return;
        }
        self.clear_picked();
        self.status = IDLE.into();
    }

    pub fn brush_cell_count(&self) -> i32 {
        footprint(self.brush_size, self.brush_shape, self.brush_3d).len() as i32
    }

    pub fn take_keys(&mut self, ctx: &egui::Context) {
        if ctx.wants_keyboard_input() {
            return;
        }
        let object_mode = self.editor_mode == EditorMode::Object;
        let mut cmd: Option<Cmd> = None;
        // On macOS the application menu owns these accelerators. Consuming
        // them here as well would undo or save twice when AppKit also delivers
        // the key to the window.
        let native_owns_shortcuts =
            cfg!(target_os = "macos") && std::env::var_os("MACVOXEL_NO_NATIVE_MENU").is_none();
        ctx.input_mut(|i| {
            let redo = egui::KeyboardShortcut::new(
                egui::Modifiers::COMMAND | egui::Modifiers::SHIFT,
                egui::Key::Z,
            );
            let undo = egui::KeyboardShortcut::new(egui::Modifiers::COMMAND, egui::Key::Z);
            let save_as = egui::KeyboardShortcut::new(
                egui::Modifiers::COMMAND | egui::Modifiers::SHIFT,
                egui::Key::S,
            );
            let save = egui::KeyboardShortcut::new(egui::Modifiers::COMMAND, egui::Key::S);
            let open = egui::KeyboardShortcut::new(egui::Modifiers::COMMAND, egui::Key::O);
            let new = egui::KeyboardShortcut::new(egui::Modifiers::COMMAND, egui::Key::N);
            let cut = egui::KeyboardShortcut::new(egui::Modifiers::COMMAND, egui::Key::X);
            let copy = egui::KeyboardShortcut::new(egui::Modifiers::COMMAND, egui::Key::C);
            let paste = egui::KeyboardShortcut::new(egui::Modifiers::COMMAND, egui::Key::V);
            let deselect = egui::KeyboardShortcut::new(
                egui::Modifiers::COMMAND | egui::Modifiers::SHIFT,
                egui::Key::D,
            );
            let new_object = egui::KeyboardShortcut::new(
                egui::Modifiers::COMMAND | egui::Modifiers::SHIFT,
                egui::Key::N,
            );
            let duplicate = egui::KeyboardShortcut::new(egui::Modifiers::COMMAND, egui::Key::D);
            let export_mesh = egui::KeyboardShortcut::new(
                egui::Modifiers::COMMAND | egui::Modifiers::SHIFT,
                egui::Key::E,
            );
            let close = egui::KeyboardShortcut::new(egui::Modifiers::COMMAND, egui::Key::W);
            let command = i.modifiers.command;
            if !native_owns_shortcuts && i.consume_shortcut(&redo) {
                cmd = Some(Cmd::Redo);
            } else if !native_owns_shortcuts && i.consume_shortcut(&undo) {
                cmd = Some(Cmd::Undo);
            } else if !native_owns_shortcuts && i.consume_shortcut(&save_as) {
                cmd = Some(Cmd::SaveAs);
            } else if !native_owns_shortcuts && i.consume_shortcut(&save) {
                cmd = Some(Cmd::Save);
            } else if !native_owns_shortcuts && i.consume_shortcut(&open) {
                cmd = Some(Cmd::Open);
            } else if !native_owns_shortcuts && i.consume_shortcut(&new_object) {
                cmd = Some(Cmd::NewObject);
            } else if !native_owns_shortcuts && i.consume_shortcut(&new) {
                cmd = Some(Cmd::New);
            } else if !native_owns_shortcuts && i.consume_shortcut(&export_mesh) {
                cmd = Some(Cmd::ExportMesh);
            } else if !native_owns_shortcuts && i.consume_shortcut(&close) {
                cmd = Some(Cmd::Close);
            } else if !native_owns_shortcuts && i.consume_shortcut(&cut) {
                cmd = Some(Cmd::Cut);
            } else if !native_owns_shortcuts && i.consume_shortcut(&copy) {
                cmd = Some(Cmd::Copy);
            } else if !native_owns_shortcuts && i.consume_shortcut(&paste) {
                cmd = Some(Cmd::Paste);
            } else if !native_owns_shortcuts && i.consume_shortcut(&deselect) {
                cmd = Some(Cmd::Deselect);
            } else if !native_owns_shortcuts && i.consume_shortcut(&duplicate) {
                cmd = Some(Cmd::DuplicateObject);
            } else if i.key_pressed(egui::Key::Tab) {
                cmd = Some(Cmd::Tab);
            } else if i.key_pressed(egui::Key::V) && !command {
                cmd = Some(Cmd::Tool(Tool::Brush));
            } else if i.key_pressed(egui::Key::L) && !command {
                cmd = Some(Cmd::Tool(Tool::Line));
            } else if i.key_pressed(egui::Key::B) && !command {
                cmd = Some(Cmd::Tool(Tool::Box));
            } else if i.key_pressed(egui::Key::F) && !command {
                cmd = Some(Cmd::Tool(Tool::Face));
            } else if i.key_pressed(egui::Key::U) && !command {
                cmd = Some(Cmd::Tool(Tool::Mutator));
            } else if i.key_pressed(egui::Key::M) && !command {
                cmd = Some(Cmd::Tool(Tool::Marquee));
            } else if object_mode
                && !command
                && !i.modifiers.alt
                && !i.modifiers.ctrl
                && (i.key_pressed(egui::Key::X)
                    || i.key_pressed(egui::Key::Y)
                    || i.key_pressed(egui::Key::Z))
            {
                let axis = if i.key_pressed(egui::Key::X) {
                    Axis::X
                } else if i.key_pressed(egui::Key::Y) {
                    Axis::Y
                } else {
                    Axis::Z
                };
                cmd = Some(if i.modifiers.shift {
                    Cmd::FlipObject(axis)
                } else {
                    Cmd::RotateObject(axis)
                });
            } else if !command
                && (i.key_pressed(egui::Key::Delete) || i.key_pressed(egui::Key::Backspace))
            {
                cmd = Some(Cmd::DeletePicked);
            }
        });
        match cmd {
            Some(Cmd::Undo) => self.undo(),
            Some(Cmd::Redo) => self.redo(),
            Some(Cmd::Open) => self.open_dialog(),
            Some(Cmd::New) => self.new_document(),
            Some(Cmd::Save) => self.save(),
            Some(Cmd::SaveAs) => self.save_as(),
            Some(Cmd::Tab) => {
                self.editor_mode = if self.editor_mode == EditorMode::Model {
                    EditorMode::Object
                } else {
                    EditorMode::Model
                };
            }
            Some(Cmd::Tool(tool)) => self.tool = tool,
            Some(Cmd::DeletePicked) => self.delete_picked(),
            Some(Cmd::Cut) => self.cut_picked(),
            Some(Cmd::Copy) => self.copy_picked(),
            Some(Cmd::Paste) => self.paste_clipboard(),
            Some(Cmd::Deselect) => self.deselect(),
            Some(Cmd::NewObject) => self.new_object(),
            Some(Cmd::DuplicateObject) => self.duplicate_object(),
            Some(Cmd::RotateObject(axis)) => self.rotate_object(axis, false),
            Some(Cmd::FlipObject(axis)) => self.flip_object(axis),
            Some(Cmd::ExportMesh) => self.export_mesh_dialog(),
            Some(Cmd::Close) => ctx.send_viewport_cmd(egui::ViewportCommand::Close),
            None => {}
        }
    }

    fn clear_picked(&mut self) {
        if self.picked.is_empty() {
            return;
        }
        self.picked.clear();
        self.selection_epoch = self.selection_epoch.wrapping_add(1);
    }

    fn set_picked(&mut self, next: HashSet<Cell>) {
        if next == self.picked {
            return;
        }
        self.picked = next;
        self.note_selection();
    }

    fn note_selection(&mut self) {
        self.selection_epoch = self.selection_epoch.wrapping_add(1);
        let n = self.picked.len();
        self.status = if n == 0 {
            IDLE.into()
        } else {
            format!("{n} voxels selected.")
        };
    }

    fn begin_select(&mut self, ray: Option<(Vec3, Vec3)>) {
        match self.tool {
            Tool::FloodSelect => {
                if let Some(hit) = self.hit_cell(ray) {
                    self.flood_at(hit);
                } else {
                    self.set_picked(HashSet::new());
                }
            }
            Tool::BoxSelect => {
                self.select_anchor = self.hit_cell(ray);
                if self.select_anchor.is_none() {
                    self.set_picked(HashSet::new());
                } else {
                    self.drag_box(ray);
                }
            }
            Tool::Marquee => {}
            _ => {}
        }
    }

    fn drag_select(&mut self, ray: Option<(Vec3, Vec3)>) {
        if self.tool == Tool::BoxSelect {
            self.drag_box(ray);
        }
    }

    fn finish_select(&mut self, ray: Option<(Vec3, Vec3)>, drag: &ToolDrag) {
        match self.tool {
            Tool::Marquee => {
                if let Some(cells) = &drag.marquee {
                    self.set_picked(cells.iter().copied().collect());
                }
            }
            Tool::BoxSelect => self.drag_box(ray),
            _ => {}
        }
        self.select_anchor = None;
    }

    fn drag_box(&mut self, ray: Option<(Vec3, Vec3)>) {
        let Some(anchor) = self.select_anchor else {
            return;
        };
        let Some(end) = self.hit_cell(ray) else {
            return;
        };
        self.set_picked(cells_in_aabb(&self.active().cells, anchor, end));
    }

    fn flood_at(&mut self, seed: Cell) {
        let Some(&slot) = self.active().cells.get(&seed) else {
            self.set_picked(HashSet::new());
            return;
        };
        self.set_picked(flood_same(&self.active().cells, seed, slot));
    }

    fn local_ray(&self, ray: Option<(Vec3, Vec3)>) -> Option<(Vec3, Vec3)> {
        let (origin, dir) = ray?;
        let shift = self.active().translation;
        Some((
            origin - Vec3::new(shift.0 as f32, shift.1 as f32, shift.2 as f32),
            dir,
        ))
    }

    fn pick_object(&self, origin: Vec3, dir: Vec3) -> Option<(usize, Hit)> {
        let mut best: Option<(f32, usize, Hit)> = None;
        for (index, object) in self.objects.iter().enumerate() {
            let local = origin
                - Vec3::new(
                    object.translation.0 as f32,
                    object.translation.1 as f32,
                    object.translation.2 as f32,
                );
            let Some(hit) = raycast(&object.cells, local, dir) else {
                continue;
            };
            let center = Vec3::new(
                hit.cell.0 as f32 + object.translation.0 as f32 + 0.5,
                hit.cell.1 as f32 + object.translation.1 as f32 + 0.5,
                hit.cell.2 as f32 + object.translation.2 as f32 + 0.5,
            );
            let distance = (center - origin).length_squared();
            if best.is_none_or(|(so_far, _, _)| distance < so_far) {
                best = Some((distance, index, hit));
            }
        }
        best.map(|(_, index, hit)| (index, hit))
    }

    fn hit_cell(&self, ray: Option<(Vec3, Vec3)>) -> Option<Cell> {
        let (origin, dir) = ray?;
        raycast(&self.active().cells, origin, dir).map(|hit| hit.cell)
    }

    fn map_picked(&mut self, mut map: impl FnMut(Cell) -> Cell) {
        if self.picked.is_empty() {
            return;
        }
        self.checkpoint();
        let cells = std::mem::take(&mut self.active_mut().cells);
        let picked = std::mem::take(&mut self.picked);
        let mut next = HashMap::with_capacity(cells.len());
        for (cell, slot) in &cells {
            if !picked.contains(cell) {
                next.insert(*cell, *slot);
            }
        }
        let mut moved = HashSet::with_capacity(picked.len());
        for (cell, slot) in cells {
            if picked.contains(&cell) {
                let at = map(cell);
                next.insert(at, slot);
                moved.insert(at);
            }
        }
        self.active_mut().cells = next;
        self.picked = moved;
        self.commit();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.note_selection();
    }
}

enum Cmd {
    Undo,
    Redo,
    Open,
    New,
    Save,
    SaveAs,
    Tab,
    Tool(Tool),
    DeletePicked,
    Cut,
    Copy,
    Paste,
    Deselect,
    NewObject,
    DuplicateObject,
    ExportMesh,
    Close,
    RotateObject(Axis),
    FlipObject(Axis),
}

#[derive(Clone, PartialEq)]
struct Snapshot {
    objects: Vec<Volume>,
    palette: [[u8; 4]; 256],
}

#[derive(Clone)]
struct VoxelClipboard {
    origin: Cell,
    cells: Vec<(Cell, u8)>,
}

struct MoveDrag {
    axis: i32,
    plane: f32,
    anchor: Vec3,
    base_cells: HashMap<Cell, u8>,
    base_picked: Vec<Cell>,
    applied: Cell,
}

#[derive(Clone)]
struct ObjectDrag {
    index: usize,
    locked: Option<i32>,
    plane_axis: i32,
    plane: f32,
    anchor: Vec3,
    normal: Vec3,
    base: Cell,
    bases: Vec<(usize, Cell)>,
    changed: bool,
}

fn ensure_vox_extension(path: PathBuf) -> PathBuf {
    match path.extension().and_then(|ext| ext.to_str()) {
        Some(ext) if ext.eq_ignore_ascii_case("vox") => path,
        _ => path.with_extension("vox"),
    }
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

pub fn palette_slot_at(col: i32, row: i32) -> u8 {
    if !(0..8).contains(&col) || !(0..32).contains(&row) {
        return 0;
    }
    let n = (32 - 1 - row) * 8 + col + 1;
    if (1..256).contains(&n) {
        n as u8
    } else {
        0
    }
}

fn lerp_color(a: [u8; 4], b: [u8; 4], t: f32) -> [u8; 4] {
    let mix = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t + 0.5).clamp(0.0, 255.0) as u8;
    [
        mix(a[0], b[0]),
        mix(a[1], b[1]),
        mix(a[2], b[2]),
        mix(a[3], b[3]),
    ]
}

pub(crate) fn occupied_bounds(cells: &HashMap<Cell, u8>) -> Option<(Cell, Cell)> {
    cell_bounds(cells.keys().copied())
}

fn cell_bounds(cells: impl IntoIterator<Item = Cell>) -> Option<(Cell, Cell)> {
    let mut iter = cells.into_iter();
    let first = iter.next()?;
    let mut min = first;
    let mut max = first;
    for cell in iter {
        min.0 = min.0.min(cell.0);
        min.1 = min.1.min(cell.1);
        min.2 = min.2.min(cell.2);
        max.0 = max.0.max(cell.0);
        max.1 = max.1.max(cell.1);
        max.2 = max.2.max(cell.2);
    }
    Some((min, max))
}

fn in_world(x: i32, y: i32, z: i32) -> bool {
    (-1024..1024).contains(&x) && (-1024..1024).contains(&y) && (-1024..1024).contains(&z)
}

fn beside(volume: &Volume) -> Cell {
    let mut min_x = 0;
    let mut max_x = 0;
    let mut any = false;
    for cell in volume.cells.keys() {
        if !any {
            min_x = cell.0;
            max_x = cell.0;
            any = true;
        } else {
            min_x = min_x.min(cell.0);
            max_x = max_x.max(cell.0);
        }
    }
    let span = if any { max_x - min_x + 2 } else { 2 };
    (
        volume.translation.0 + span,
        volume.translation.1,
        volume.translation.2,
    )
}

fn min_corner(cells: impl IntoIterator<Item = Cell>) -> Cell {
    let mut corner = (i32::MAX, i32::MAX, i32::MAX);
    for c in cells {
        corner.0 = corner.0.min(c.0);
        corner.1 = corner.1.min(c.1);
        corner.2 = corner.2.min(c.2);
    }
    corner
}

fn axis_name(axis: Axis) -> &'static str {
    match axis {
        Axis::X => "X",
        Axis::Y => "Y",
        Axis::Z => "Z",
    }
}

fn world_extents(volume: &Volume) -> Option<(Cell, Cell)> {
    let (min, max) = cell_bounds(volume.cells.keys().copied())?;
    let shift = volume.translation;
    Some((
        (min.0 + shift.0, min.1 + shift.1, min.2 + shift.2),
        (max.0 + shift.0, max.1 + shift.1, max.2 + shift.2),
    ))
}

/// Integer center of an inclusive span. Matches the C++ floor((lo+hi+1)/2).
fn span_center(lo: i32, hi: i32) -> i32 {
    let s = lo as i64 + hi as i64 + 1;
    let center = if s >= 0 { s / 2 } else { -((-s + 1) / 2) };
    center as i32
}

fn extents(cells: impl IntoIterator<Item = Cell>) -> (Cell, Cell) {
    let mut min = (i32::MAX, i32::MAX, i32::MAX);
    let mut max = (i32::MIN, i32::MIN, i32::MIN);
    for c in cells {
        min.0 = min.0.min(c.0);
        min.1 = min.1.min(c.1);
        min.2 = min.2.min(c.2);
        max.0 = max.0.max(c.0);
        max.1 = max.1.max(c.1);
        max.2 = max.2.max(c.2);
    }
    (min, max)
}

fn mirror(c: Cell, axis: Axis, min: Cell, max: Cell) -> Cell {
    match axis {
        Axis::X => (min.0 + max.0 - c.0, c.1, c.2),
        Axis::Y => (c.0, min.1 + max.1 - c.1, c.2),
        Axis::Z => (c.0, c.1, min.2 + max.2 - c.2),
    }
}

fn cells_in_aabb(cells: &HashMap<Cell, u8>, a: Cell, b: Cell) -> HashSet<Cell> {
    let min = (a.0.min(b.0), a.1.min(b.1), a.2.min(b.2));
    let max = (a.0.max(b.0), a.1.max(b.1), a.2.max(b.2));
    cells
        .keys()
        .copied()
        .filter(|c| {
            c.0 >= min.0
                && c.0 <= max.0
                && c.1 >= min.1
                && c.1 <= max.1
                && c.2 >= min.2
                && c.2 <= max.2
        })
        .collect()
}

fn flood_same(cells: &HashMap<Cell, u8>, seed: Cell, slot: u8) -> HashSet<Cell> {
    let mut seen = HashSet::new();
    let mut out = HashSet::new();
    let mut queue = vec![seed];
    seen.insert(seed);
    const STEPS: [Cell; 6] = [
        (1, 0, 0),
        (-1, 0, 0),
        (0, 1, 0),
        (0, -1, 0),
        (0, 0, 1),
        (0, 0, -1),
    ];
    while let Some(cell) = queue.pop() {
        out.insert(cell);
        for (dx, dy, dz) in STEPS {
            let next = (cell.0 + dx, cell.1 + dy, cell.2 + dz);
            if !seen.insert(next) {
                continue;
            }
            if cells.get(&next).copied() == Some(slot) {
                queue.push(next);
            }
        }
    }
    out
}

fn intersect_plane(origin: Vec3, dir: Vec3, point: Vec3, normal: Vec3) -> Option<Vec3> {
    let dir = dir.normalize_or_zero();
    let denom = normal.dot(dir);
    if denom.abs() < 1e-6 {
        return None;
    }
    let t = normal.dot(point - origin) / denom;
    if t < 0.0 {
        return None;
    }
    Some(origin + dir * t)
}

fn intersect_axis_plane(origin: Vec3, dir: Vec3, axis: i32, plane: f32) -> Option<Vec3> {
    let dir = dir.normalize_or_zero();
    if dir.length_squared() < 1e-8 {
        return None;
    }
    let (along, component) = match axis {
        0 => (origin.x, dir.x),
        1 => (origin.y, dir.y),
        _ => (origin.z, dir.z),
    };
    if component.abs() < 1e-6 {
        return None;
    }
    let t = (plane - along) / component;
    if t < 0.0 {
        return None;
    }
    Some(origin + dir * t)
}

fn plane_delta(axis: i32, anchor: Vec3, hit: Vec3) -> Cell {
    (
        if axis == 0 {
            0
        } else {
            (hit.x - anchor.x).round() as i32
        },
        if axis == 1 {
            0
        } else {
            (hit.y - anchor.y).round() as i32
        },
        if axis == 2 {
            0
        } else {
            (hit.z - anchor.z).round() as i32
        },
    )
}

fn translate_cells(
    base: &HashMap<Cell, u8>,
    picked: &[Cell],
    delta: Cell,
) -> (HashMap<Cell, u8>, HashSet<Cell>) {
    let chosen: HashSet<Cell> = picked.iter().copied().collect();
    let mut next = HashMap::with_capacity(base.len());
    for (cell, slot) in base {
        if !chosen.contains(cell) {
            next.insert(*cell, *slot);
        }
    }
    let mut moved = HashSet::with_capacity(picked.len());
    for cell in picked {
        let Some(&slot) = base.get(cell) else {
            continue;
        };
        let at = (cell.0 + delta.0, cell.1 + delta.1, cell.2 + delta.2);
        next.insert(at, slot);
        moved.insert(at);
    }
    (next, moved)
}

fn face_axis(normal: Cell) -> (i32, i32) {
    if normal.0 != 0 {
        (0, normal.0.signum())
    } else if normal.1 != 0 {
        (1, normal.1.signum())
    } else {
        (2, normal.2.signum())
    }
}

fn plane_hit(origin: Vec3, dir: Vec3, anchor: Hit) -> Option<Hit> {
    let dir = dir.normalize_or_zero();
    if dir.length_squared() < 1e-8 {
        return None;
    }
    let (axis, sign) = face_axis(anchor.normal);
    let along = match axis {
        0 => origin.x,
        1 => origin.y,
        _ => origin.z,
    };
    let component = match axis {
        0 => dir.x,
        1 => dir.y,
        _ => dir.z,
    };
    if component.abs() < 1e-6 {
        return None;
    }
    let plane = match axis {
        0 => anchor.cell.0 as f32 + if sign > 0 { 1.0 } else { 0.0 },
        1 => anchor.cell.1 as f32 + if sign > 0 { 1.0 } else { 0.0 },
        _ => anchor.cell.2 as f32 + if sign > 0 { 1.0 } else { 0.0 },
    };
    let t = (plane - along) / component;
    if t < 0.0 {
        return None;
    }
    let point = origin + dir * t;
    let mut cell = (
        point.x.floor() as i32,
        point.y.floor() as i32,
        point.z.floor() as i32,
    );
    let solid = if sign > 0 {
        plane as i32 - 1
    } else {
        plane as i32
    };
    match axis {
        0 => cell.0 = solid,
        1 => cell.1 = solid,
        _ => cell.2 = solid,
    }
    Some(Hit {
        cell,
        normal: anchor.normal,
    })
}

/// Closest forward hit on the six walls of the occupied AABB. The returned
/// normal points into the volume, and the cell is the empty (or occupied)
/// cell on the inside of that wall.
fn wall_hit(cells: &HashMap<Cell, u8>, origin: Vec3, dir: Vec3) -> Option<Hit> {
    let (min, max) = cell_bounds(cells.keys().copied())?;
    let walls = [
        [min.0 as f32, max.0 as f32 + 1.0],
        [min.1 as f32, max.1 as f32 + 1.0],
        [min.2 as f32, max.2 as f32 + 1.0],
    ];
    let ro = [origin.x, origin.y, origin.z];
    let rd = [dir.x, dir.y, dir.z];
    let mut best_t = f32::INFINITY;
    let mut best_axis = -1i32;
    let mut best_sign = 0i32;
    let mut best_h = [0.0f32; 3];
    for axis in 0..3 {
        if rd[axis].abs() < 1e-6 {
            continue;
        }
        for side in 0..2 {
            let plane = walls[axis][side];
            if side == 0 && ro[axis] < plane {
                continue;
            }
            if side == 1 && ro[axis] > plane {
                continue;
            }
            let t = (plane - ro[axis]) / rd[axis];
            if t < 0.0 || t > 4096.0 || t >= best_t {
                continue;
            }
            let hit = [ro[0] + t * rd[0], ro[1] + t * rd[1], ro[2] + t * rd[2]];
            let mut inside = true;
            for other in 0..3 {
                if other == axis {
                    continue;
                }
                if hit[other] < walls[other][0] || hit[other] > walls[other][1] {
                    inside = false;
                }
            }
            if !inside {
                continue;
            }
            best_t = t;
            best_axis = axis as i32;
            best_sign = if side == 0 { -1 } else { 1 };
            best_h = hit;
        }
    }
    if best_axis < 0 {
        return None;
    }
    let lo = [min.0, min.1, min.2];
    let hi = [max.0, max.1, max.2];
    let mut cell = [0i32; 3];
    for axis in 0..3 {
        cell[axis] = (best_h[axis].floor() as i32).clamp(lo[axis], hi[axis]);
    }
    let axis = best_axis as usize;
    cell[axis] = if best_sign < 0 { lo[axis] } else { hi[axis] };
    let wall_sign = if cell[axis] == lo[axis] { -1 } else { 1 };
    Some(Hit {
        cell: (cell[0], cell[1], cell[2]),
        normal: crate::tools::axis_delta(best_axis, -wall_sign),
    })
}

fn map_footprint(offsets: &[Cell], axis: i32) -> Vec<Cell> {
    offsets
        .iter()
        .map(|(u, v, w)| match axis {
            0 => (*w, *u, *v),
            1 => (*u, *w, *v),
            _ => (*u, *v, *w),
        })
        .collect()
}

fn expand_centers(centers: &[Cell], offsets: &[Cell], axis: i32) -> Vec<Cell> {
    let mapped = map_footprint(offsets, axis);
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for center in centers {
        for delta in &mapped {
            let cell = crate::tools::add(*center, *delta);
            if seen.insert(cell) {
                out.push(cell);
            }
        }
    }
    out
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

struct LoadedObject {
    name: String,
    cells: HashMap<Cell, u8>,
    translation: Cell,
}

struct Loaded {
    cells: HashMap<Cell, u8>,
    objects: Vec<LoadedObject>,
    palette: Option<[[u8; 4]; 256]>,
    materials: [Material; 256],
    model_count: usize,
}

/// Single-volume MagicaVoxel file, version 150. The grid is shifted so its
/// minimum corner is the origin. Empty volumes and any axis longer than 256
/// are refused. Voxels are sorted so two saves of the same volume match.
fn save_vox(
    cells: &HashMap<Cell, u8>,
    palette: &[[u8; 4]; 256],
    materials: &[Material; 256],
) -> Result<Vec<u8>, String> {
    let mut voxels: Vec<(i32, i32, i32, u8)> = cells
        .iter()
        .filter(|(_, index)| **index != 0)
        .map(|(cell, index)| (cell.0, cell.1, cell.2, *index))
        .collect();
    if voxels.is_empty() {
        return Err("cannot save an empty grid".into());
    }
    let mut min = (voxels[0].0, voxels[0].1, voxels[0].2);
    let mut max = min;
    for voxel in &voxels {
        min.0 = min.0.min(voxel.0);
        min.1 = min.1.min(voxel.1);
        min.2 = min.2.min(voxel.2);
        max.0 = max.0.max(voxel.0);
        max.1 = max.1.max(voxel.1);
        max.2 = max.2.max(voxel.2);
    }
    let sx = max.0 - min.0 + 1;
    let sy = max.1 - min.1 + 1;
    let sz = max.2 - min.2 + 1;
    if sx > 256 || sy > 256 || sz > 256 {
        return Err(format!(
            "scene exceeds .vox single-model limit of 256 per axis (bounds {sx}x{sy}x{sz})"
        ));
    }
    for voxel in &mut voxels {
        voxel.0 -= min.0;
        voxel.1 -= min.1;
        voxel.2 -= min.2;
    }
    voxels.sort_unstable();

    let mut children = Vec::new();
    let mut size = Vec::new();
    size.extend_from_slice(&(sx as u32).to_le_bytes());
    size.extend_from_slice(&(sy as u32).to_le_bytes());
    size.extend_from_slice(&(sz as u32).to_le_bytes());
    push_chunk(&mut children, b"SIZE", &size);

    let mut xyzi = Vec::with_capacity(4 + voxels.len() * 4);
    xyzi.extend_from_slice(&(voxels.len() as u32).to_le_bytes());
    for (x, y, z, index) in voxels {
        xyzi.extend_from_slice(&[x as u8, y as u8, z as u8, index]);
    }
    push_chunk(&mut children, b"XYZI", &xyzi);
    push_rgba(&mut children, palette);
    push_matl(&mut children, materials);
    Ok(wrap_vox(children))
}

/// Every non-empty object, each as its own model. Local cells are shifted
/// so the minimum corner is the origin. The leaf translation puts that
/// model back where the editor had it. Rotations are not stored: a loaded
/// rotation is baked into the cells.
fn save_scene(
    objects: &[Volume],
    palette: &[[u8; 4]; 256],
    materials: &[Material; 256],
) -> Result<Vec<u8>, String> {
    struct Packed {
        name: String,
        voxels: Vec<(i32, i32, i32, u8)>,
        dims: [i32; 3],
        leaf_t: [i32; 3],
    }
    let mut packed = Vec::new();
    for object in objects {
        let mut voxels: Vec<(i32, i32, i32, u8)> = object
            .cells
            .iter()
            .filter(|(_, index)| **index != 0)
            .map(|(cell, index)| (cell.0, cell.1, cell.2, *index))
            .collect();
        if voxels.is_empty() {
            continue;
        }
        let mut min = (voxels[0].0, voxels[0].1, voxels[0].2);
        let mut max = min;
        for voxel in &voxels {
            min.0 = min.0.min(voxel.0);
            min.1 = min.1.min(voxel.1);
            min.2 = min.2.min(voxel.2);
            max.0 = max.0.max(voxel.0);
            max.1 = max.1.max(voxel.1);
            max.2 = max.2.max(voxel.2);
        }
        let dims = [max.0 - min.0 + 1, max.1 - min.1 + 1, max.2 - min.2 + 1];
        if dims[0] > 256 || dims[1] > 256 || dims[2] > 256 {
            return Err(format!(
                "scene exceeds .vox single-model limit of 256 per axis (bounds {}x{}x{})",
                dims[0], dims[1], dims[2]
            ));
        }
        for voxel in &mut voxels {
            voxel.0 -= min.0;
            voxel.1 -= min.1;
            voxel.2 -= min.2;
        }
        voxels.sort_unstable();
        let half = [dims[0] / 2, dims[1] / 2, dims[2] / 2];
        packed.push(Packed {
            name: object.name.clone(),
            voxels,
            dims,
            leaf_t: [
                object.translation.0 + min.0 + half[0],
                object.translation.1 + min.1 + half[1],
                object.translation.2 + min.2 + half[2],
            ],
        });
    }
    if packed.is_empty() {
        return Err("cannot save an empty grid".into());
    }

    let mut children = Vec::new();
    for model in &packed {
        let mut size = Vec::new();
        size.extend_from_slice(&(model.dims[0] as u32).to_le_bytes());
        size.extend_from_slice(&(model.dims[1] as u32).to_le_bytes());
        size.extend_from_slice(&(model.dims[2] as u32).to_le_bytes());
        push_chunk(&mut children, b"SIZE", &size);
        let mut xyzi = Vec::with_capacity(4 + model.voxels.len() * 4);
        xyzi.extend_from_slice(&(model.voxels.len() as u32).to_le_bytes());
        for (x, y, z, index) in &model.voxels {
            xyzi.extend_from_slice(&[*x as u8, *y as u8, *z as u8, *index]);
        }
        push_chunk(&mut children, b"XYZI", &xyzi);
    }

    let mut kids = Vec::new();
    for index in 0..packed.len() {
        kids.push((2 + index * 2) as i32);
    }
    push_chunk(&mut children, b"nTRN", &trn_body(0, 1, [0, 0, 0], ""));
    push_chunk(&mut children, b"nGRP", &grp_body(1, &kids));
    for (index, model) in packed.iter().enumerate() {
        let trn = (2 + index * 2) as i32;
        let shp = trn + 1;
        push_chunk(
            &mut children,
            b"nTRN",
            &trn_body(trn, shp, model.leaf_t, &model.name),
        );
        push_chunk(&mut children, b"nSHP", &shp_body(shp, index as i32));
    }
    push_rgba(&mut children, palette);
    push_matl(&mut children, materials);
    Ok(wrap_vox(children))
}

fn wrap_vox(children: Vec<u8>) -> Vec<u8> {
    let mut file = Vec::new();
    file.extend_from_slice(b"VOX ");
    file.extend_from_slice(&150u32.to_le_bytes());
    file.extend_from_slice(b"MAIN");
    file.extend_from_slice(&0u32.to_le_bytes());
    file.extend_from_slice(&(children.len() as u32).to_le_bytes());
    file.extend(children);
    file
}

fn push_i32(out: &mut Vec<u8>, value: i32) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn push_dict(out: &mut Vec<u8>, pairs: &[(&str, &str)]) {
    push_i32(out, pairs.len() as i32);
    for (key, value) in pairs {
        push_string(out, key);
        push_string(out, value);
    }
}

fn trn_body(id: i32, child: i32, t: [i32; 3], name: &str) -> Vec<u8> {
    let mut body = Vec::new();
    push_i32(&mut body, id);
    if name.is_empty() {
        push_dict(&mut body, &[]);
    } else {
        push_dict(&mut body, &[("_name", name)]);
    }
    push_i32(&mut body, child);
    push_i32(&mut body, -1);
    push_i32(&mut body, -1);
    push_i32(&mut body, 1);
    if t == [0, 0, 0] {
        push_dict(&mut body, &[]);
    } else {
        let text = format!("{} {} {}", t[0], t[1], t[2]);
        push_dict(&mut body, &[("_t", &text)]);
    }
    body
}

fn grp_body(id: i32, children: &[i32]) -> Vec<u8> {
    let mut body = Vec::new();
    push_i32(&mut body, id);
    push_dict(&mut body, &[]);
    push_i32(&mut body, children.len() as i32);
    for child in children {
        push_i32(&mut body, *child);
    }
    body
}

fn shp_body(id: i32, model: i32) -> Vec<u8> {
    let mut body = Vec::new();
    push_i32(&mut body, id);
    push_dict(&mut body, &[]);
    push_i32(&mut body, 1);
    push_i32(&mut body, model);
    push_dict(&mut body, &[]);
    body
}

fn push_chunk(out: &mut Vec<u8>, id: &[u8; 4], content: &[u8]) {
    out.extend_from_slice(id);
    out.extend_from_slice(&(content.len() as u32).to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(content);
}

fn push_rgba(out: &mut Vec<u8>, palette: &[[u8; 4]; 256]) {
    let mut body = Vec::with_capacity(1024);
    for slot in 1..=255 {
        body.extend_from_slice(&palette[slot]);
    }
    body.extend_from_slice(&[0, 0, 0, 0]);
    push_chunk(out, b"RGBA", &body);
}

fn material_is_default(material: &Material) -> bool {
    *material == Material::default()
}

fn format_float(value: f32) -> String {
    // printf("%g") for the values the editor writes. Display round-trips
    // through strtof for those (1, 0.5, 0.25); bit-identical files are not
    // required, a reload of the same numbers is.
    format!("{value}")
}

fn push_string(out: &mut Vec<u8>, text: &str) {
    out.extend_from_slice(&(text.len() as u32).to_le_bytes());
    out.extend_from_slice(text.as_bytes());
}

fn matl_type(ty: MaterialType) -> &'static str {
    match ty {
        MaterialType::Metal => "_metal",
        MaterialType::Glass => "_glass",
        MaterialType::Emissive => "_emit",
        MaterialType::Diffuse => "_diffuse",
    }
}

fn push_matl(out: &mut Vec<u8>, materials: &[Material; 256]) {
    for id in 1..=255 {
        let material = materials[id];
        if material_is_default(&material) {
            continue;
        }
        let mut pairs = vec![
            ("_type", matl_type(material.ty).to_string()),
            ("_rough", format_float(material.roughness)),
            ("_metal", format_float(material.metallic)),
            ("_ior", format_float(material.ior - 1.0)),
        ];
        if material.transparency != 0.0 {
            pairs.push(("_alpha", format_float(material.transparency)));
        }
        if material.ty == MaterialType::Emissive {
            pairs.push(("_emit", format_float(material.emission)));
            pairs.push(("_flux", format_float((material.emission_power - 1) as f32)));
        }
        let mut body = Vec::new();
        body.extend_from_slice(&(id as u32).to_le_bytes());
        body.extend_from_slice(&(pairs.len() as u32).to_le_bytes());
        for (key, value) in &pairs {
            push_string(&mut body, key);
            push_string(&mut body, value);
        }
        push_chunk(out, b"MATL", &body);
    }
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

    let mut models: Vec<([i32; 3], Vec<(i32, i32, i32, u8)>)> = Vec::new();
    let mut pending: Option<[i32; 3]> = None;
    let mut nodes: HashMap<i32, VoxNode> = HashMap::new();
    let mut palette = None;
    let mut materials = [Material::default(); 256];

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
            pending = Some([
                u32::from_le_bytes(body[0..4].try_into().unwrap()) as i32,
                u32::from_le_bytes(body[4..8].try_into().unwrap()) as i32,
                u32::from_le_bytes(body[8..12].try_into().unwrap()) as i32,
            ]);
        } else if &id == b"XYZI" {
            let Some(dims) = pending.take() else {
                return Err("XYZI chunk before SIZE".into());
            };
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
                voxels.push((
                    body[o] as i32,
                    body[o + 1] as i32,
                    body[o + 2] as i32,
                    body[o + 3],
                ));
            }
            models.push((dims, voxels));
        } else if &id == b"nTRN" {
            if let Some(node) = parse_trn(body) {
                nodes.insert(node.id, node);
            }
        } else if &id == b"nGRP" {
            if let Some(node) = parse_grp(body) {
                nodes.insert(node.id, node);
            }
        } else if &id == b"nSHP" {
            if let Some(node) = parse_shp(body) {
                nodes.insert(node.id, node);
            }
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
        } else if &id == b"MATL" {
            if let Some((slot, material)) = parse_matl(body) {
                materials[slot] = material;
            }
        }
        p += content + children;
    }

    if models.is_empty() {
        return Err("file has no models".into());
    }
    let model_count = models.len();
    let objects = place_models(&models, &nodes);
    let cells = objects
        .first()
        .map(|object| object.cells.clone())
        .unwrap_or_default();
    Ok(Loaded {
        cells,
        objects,
        palette,
        materials,
        model_count,
    })
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum VoxKind {
    Transform,
    Group,
    Shape,
}

#[derive(Clone)]
struct VoxNode {
    id: i32,
    kind: VoxKind,
    child: i32,
    children: Vec<i32>,
    model_id: i32,
    t: [i32; 3],
    rot: u8,
    name: String,
}

const ROT_IDENTITY: [[i32; 3]; 3] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];

fn rot_from_byte(rot: u8) -> [[i32; 3]; 3] {
    let c0 = (rot & 3) as i32;
    let c1 = ((rot >> 2) & 3) as i32;
    let c2 = 3 - c0 - c1;
    if c0 == c1 || !(0..=2).contains(&c2) {
        return ROT_IDENTITY;
    }
    let sign = |bit: u8| if rot & (1 << bit) == 0 { 1 } else { -1 };
    let mut matrix = [[0; 3]; 3];
    matrix[0][c0 as usize] = sign(4);
    matrix[1][c1 as usize] = sign(5);
    matrix[2][c2 as usize] = sign(6);
    matrix
}

fn rot_mul(a: [[i32; 3]; 3], b: [[i32; 3]; 3]) -> [[i32; 3]; 3] {
    let mut out = [[0; 3]; 3];
    for i in 0..3 {
        for j in 0..3 {
            out[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
        }
    }
    out
}

fn rot_apply(matrix: [[i32; 3]; 3], v: [i32; 3]) -> [i32; 3] {
    [
        matrix[0][0] * v[0] + matrix[0][1] * v[1] + matrix[0][2] * v[2],
        matrix[1][0] * v[0] + matrix[1][1] * v[1] + matrix[1][2] * v[2],
        matrix[2][0] * v[0] + matrix[2][1] * v[1] + matrix[2][2] * v[2],
    ]
}

fn parse_trn(body: &[u8]) -> Option<VoxNode> {
    let mut cursor = body;
    let id = take_i32(&mut cursor)?;
    let attrs = read_dict(&mut cursor)?;
    let child = take_i32(&mut cursor)?;
    let _reserved = take_i32(&mut cursor)?;
    let _layer = take_i32(&mut cursor)?;
    let frames = take_i32(&mut cursor)?;
    let mut t = [0, 0, 0];
    let mut rot = 4u8;
    for index in 0..frames {
        let frame = read_dict(&mut cursor)?;
        if index == 0 {
            if let Some(text) = frame.get("_t") {
                t = parse_translation(text).unwrap_or(t);
            }
            if let Some(text) = frame.get("_r") {
                rot = text.parse().unwrap_or(4);
            }
        }
    }
    Some(VoxNode {
        id,
        kind: VoxKind::Transform,
        child,
        children: Vec::new(),
        model_id: -1,
        t,
        rot,
        name: attrs.get("_name").cloned().unwrap_or_default(),
    })
}

fn parse_grp(body: &[u8]) -> Option<VoxNode> {
    let mut cursor = body;
    let id = take_i32(&mut cursor)?;
    let _attrs = read_dict(&mut cursor)?;
    let count = take_i32(&mut cursor)?;
    if count < 0 {
        return None;
    }
    let mut children = Vec::with_capacity(count as usize);
    for _ in 0..count {
        children.push(take_i32(&mut cursor)?);
    }
    Some(VoxNode {
        id,
        kind: VoxKind::Group,
        child: -1,
        children,
        model_id: -1,
        t: [0, 0, 0],
        rot: 4,
        name: String::new(),
    })
}

fn parse_shp(body: &[u8]) -> Option<VoxNode> {
    let mut cursor = body;
    let id = take_i32(&mut cursor)?;
    let attrs = read_dict(&mut cursor)?;
    let count = take_i32(&mut cursor)?;
    if count < 0 {
        return None;
    }
    let mut model_id = -1;
    for index in 0..count {
        let model = take_i32(&mut cursor)?;
        let _model_attrs = read_dict(&mut cursor)?;
        if index == 0 {
            model_id = model;
        }
    }
    Some(VoxNode {
        id,
        kind: VoxKind::Shape,
        child: -1,
        children: Vec::new(),
        model_id,
        t: [0, 0, 0],
        rot: 4,
        name: attrs.get("_name").cloned().unwrap_or_default(),
    })
}

fn parse_translation(text: &str) -> Option<[i32; 3]> {
    let mut parts = text.split_whitespace();
    Some([
        parts.next()?.parse().ok()?,
        parts.next()?.parse().ok()?,
        parts.next()?.parse().ok()?,
    ])
}

struct Placement {
    model_id: i32,
    world_t: [i32; 3],
    world_r: [[i32; 3]; 3],
    name: String,
}

fn place_models(
    models: &[([i32; 3], Vec<(i32, i32, i32, u8)>)],
    nodes: &HashMap<i32, VoxNode>,
) -> Vec<LoadedObject> {
    let placements = if nodes.is_empty() {
        Vec::new()
    } else {
        let root = if nodes.contains_key(&0) {
            0
        } else {
            *nodes.keys().min().unwrap_or(&0)
        };
        let mut out = Vec::new();
        let mut path = HashSet::new();
        walk_nodes(nodes, root, [0, 0, 0], ROT_IDENTITY, &mut path, &mut out);
        out
    };
    let placements = if placements.is_empty() {
        let dims = models.first().map(|(dims, _)| *dims).unwrap_or([0, 0, 0]);
        vec![Placement {
            model_id: 0,
            world_t: [dims[0] / 2, dims[1] / 2, dims[2] / 2],
            world_r: ROT_IDENTITY,
            name: String::new(),
        }]
    } else {
        placements
    };
    let mut world = Vec::new();
    for placement in placements {
        let Some((dims, voxels)) = models.get(placement.model_id as usize) else {
            continue;
        };
        let half = [dims[0] / 2, dims[1] / 2, dims[2] / 2];
        let mut cells = HashMap::new();
        for (x, y, z, color) in voxels {
            if *color == 0 {
                continue;
            }
            let spun = rot_apply(placement.world_r, [x - half[0], y - half[1], z - half[2]]);
            cells.insert(
                (
                    spun[0] + placement.world_t[0],
                    spun[1] + placement.world_t[1],
                    spun[2] + placement.world_t[2],
                ),
                *color,
            );
        }
        world.push((placement.name, cells, placement.world_t));
    }
    if world.is_empty() {
        return vec![LoadedObject {
            name: String::new(),
            cells: HashMap::new(),
            translation: (0, 0, 0),
        }];
    }
    let shift0 = world
        .iter()
        .find_map(|(_, cells, _)| display_shift(cells))
        .unwrap_or((0, 0, 0));
    world
        .into_iter()
        .map(|(name, cells, anchor)| {
            let shift = display_shift(&cells).unwrap_or((0, 0, 0));
            let local = cells
                .into_iter()
                .map(|(cell, color)| {
                    (
                        (cell.0 + shift.0, cell.1 + shift.1, cell.2 + shift.2),
                        color,
                    )
                })
                .collect();
            let translation = if shift == (0, 0, 0) && local_is_empty(&local) {
                (
                    anchor[0] + shift0.0,
                    anchor[1] + shift0.1,
                    anchor[2] + shift0.2,
                )
            } else {
                (shift0.0 - shift.0, shift0.1 - shift.1, shift0.2 - shift.2)
            };
            LoadedObject {
                name,
                cells: local,
                translation,
            }
        })
        .collect()
}

fn local_is_empty(cells: &HashMap<Cell, u8>) -> bool {
    cells.is_empty()
}

fn display_shift(cells: &HashMap<Cell, u8>) -> Option<Cell> {
    let mut keys = cells.keys();
    let first = *keys.next()?;
    let mut min = first;
    let mut max = first;
    for cell in cells.keys() {
        min.0 = min.0.min(cell.0);
        min.1 = min.1.min(cell.1);
        min.2 = min.2.min(cell.2);
        max.0 = max.0.max(cell.0);
        max.1 = max.1.max(cell.1);
        max.2 = max.2.max(cell.2);
    }
    Some((-((min.0 + max.0) / 2), -((min.1 + max.1) / 2), -min.2))
}

fn walk_nodes(
    nodes: &HashMap<i32, VoxNode>,
    id: i32,
    t: [i32; 3],
    r: [[i32; 3]; 3],
    path: &mut HashSet<i32>,
    out: &mut Vec<Placement>,
) {
    if !path.insert(id) {
        return;
    }
    if let Some(node) = nodes.get(&id).cloned() {
        match node.kind {
            VoxKind::Transform => {
                let spun = rot_apply(r, node.t);
                let ct = [t[0] + spun[0], t[1] + spun[1], t[2] + spun[2]];
                let cr = rot_mul(r, rot_from_byte(node.rot));
                let child_is_shape = nodes
                    .get(&node.child)
                    .is_some_and(|child| child.kind == VoxKind::Shape);
                if child_is_shape {
                    if let Some(shape) = nodes.get(&node.child) {
                        if shape.model_id >= 0 {
                            let name = if node.name.is_empty() {
                                shape.name.clone()
                            } else {
                                node.name.clone()
                            };
                            out.push(Placement {
                                model_id: shape.model_id,
                                world_t: ct,
                                world_r: cr,
                                name,
                            });
                        }
                    }
                } else {
                    walk_nodes(nodes, node.child, ct, cr, path, out);
                }
            }
            VoxKind::Group => {
                for child in &node.children {
                    walk_nodes(nodes, *child, t, r, path, out);
                }
            }
            VoxKind::Shape => {
                if node.model_id >= 0 {
                    out.push(Placement {
                        model_id: node.model_id,
                        world_t: t,
                        world_r: r,
                        name: node.name.clone(),
                    });
                }
            }
        }
    }
    path.remove(&id);
}

fn parse_matl(body: &[u8]) -> Option<(usize, Material)> {
    let mut cursor = body;
    let id = take_u32(&mut cursor)? as i32;
    if !(1..=255).contains(&id) {
        return None;
    }
    let count = take_u32(&mut cursor)? as usize;
    let mut dict = HashMap::with_capacity(count);
    for _ in 0..count {
        let key = take_string(&mut cursor)?;
        let value = take_string(&mut cursor)?;
        dict.insert(key, value);
    }
    Some((id as usize, material_from_dict(&dict)))
}

fn take_i32(bytes: &mut &[u8]) -> Option<i32> {
    take_u32(bytes).map(|value| value as i32)
}

fn read_dict(bytes: &mut &[u8]) -> Option<HashMap<String, String>> {
    let count = take_u32(bytes)? as usize;
    let mut dict = HashMap::with_capacity(count);
    for _ in 0..count {
        let key = take_string(bytes)?;
        let value = take_string(bytes)?;
        dict.insert(key, value);
    }
    Some(dict)
}

fn take_u32(bytes: &mut &[u8]) -> Option<u32> {
    if bytes.len() < 4 {
        return None;
    }
    let value = u32::from_le_bytes(bytes[..4].try_into().ok()?);
    *bytes = &bytes[4..];
    Some(value)
}

fn take_string(bytes: &mut &[u8]) -> Option<String> {
    let len = take_u32(bytes)? as usize;
    if bytes.len() < len {
        return None;
    }
    let text = std::str::from_utf8(&bytes[..len]).ok()?.to_string();
    *bytes = &bytes[len..];
    Some(text)
}

fn dict_float(dict: &HashMap<String, String>, key: &str, fallback: f32) -> f32 {
    match dict.get(key) {
        Some(text) => text.parse().unwrap_or(0.0),
        None => fallback,
    }
}

fn material_from_dict(dict: &HashMap<String, String>) -> Material {
    let mut material = Material::default();
    if let Some(ty) = dict.get("_type") {
        material.ty = match ty.as_str() {
            "_metal" => MaterialType::Metal,
            "_glass" => MaterialType::Glass,
            "_emit" => MaterialType::Emissive,
            _ => MaterialType::Diffuse,
        };
    }
    material.roughness = dict_float(dict, "_rough", material.roughness);
    material.metallic = dict_float(dict, "_metal", material.metallic);
    material.ior = 1.0 + dict_float(dict, "_ior", material.ior - 1.0);
    if let Some(alpha) = dict.get("_alpha").or_else(|| dict.get("_trans")) {
        material.transparency = alpha.parse().unwrap_or(0.0);
    }
    if material.ty == MaterialType::Emissive {
        material.emission = dict_float(dict, "_emit", material.emission);
        let flux = dict_float(dict, "_flux", 0.0);
        material.emission_power = (1 + flux as i32).clamp(1, 5);
    }
    material
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

fn ensure_glb(mut path: PathBuf) -> PathBuf {
    let ok = path
        .extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("glb"));
    if !ok {
        path.set_extension("glb");
    }
    path
}

fn remember(list: &mut Vec<PathBuf>, path: &Path) {
    let path = path.to_path_buf();
    list.retain(|stored| stored != &path);
    list.insert(0, path);
    list.truncate(10);
}

fn recent_store_path() -> Option<PathBuf> {
    if cfg!(test) {
        return None;
    }
    let home = PathBuf::from(std::env::var_os("HOME")?);
    let dir = if cfg!(target_os = "macos") {
        home.join("Library/Application Support/MacVoxel")
    } else if let Some(xdg) = std::env::var_os("XDG_DATA_HOME") {
        PathBuf::from(xdg).join("macvoxel")
    } else {
        home.join(".local/share/macvoxel")
    };
    Some(dir.join("egui-recent.txt"))
}

fn load_recent() -> Vec<PathBuf> {
    let Some(file) = recent_store_path() else {
        return Vec::new();
    };
    let Ok(text) = std::fs::read_to_string(file) else {
        return Vec::new();
    };
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(PathBuf::from)
        .take(10)
        .collect()
}

fn store_recent(paths: &[PathBuf]) {
    let Some(file) = recent_store_path() else {
        return;
    };
    if let Some(parent) = file.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let text = paths
        .iter()
        .map(|path| path.display().to_string())
        .collect::<Vec<_>>()
        .join("\n");
    let _ = std::fs::write(file, text);
}

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
    fn flood_select_stops_at_a_different_color() {
        let mut cells = HashMap::new();
        cells.insert((0, 0, 0), 4);
        cells.insert((1, 0, 0), 4);
        cells.insert((2, 0, 0), 9);
        let picked = flood_same(&cells, (0, 0, 0), 4);
        assert_eq!(picked.len(), 2);
        assert!(!picked.contains(&(2, 0, 0)));
    }

    #[test]
    fn box_select_keeps_occupied_cells_inside_the_aabb() {
        let mut cells = HashMap::new();
        cells.insert((0, 0, 0), 1);
        cells.insert((1, 0, 0), 1);
        cells.insert((3, 0, 0), 1);
        let picked = cells_in_aabb(&cells, (0, 0, 0), (1, 0, 0));
        assert!(picked.contains(&(0, 0, 0)));
        assert!(picked.contains(&(1, 0, 0)));
        assert!(!picked.contains(&(3, 0, 0)));
    }

    #[test]
    fn rotate_selection_leaves_the_rest_of_the_volume() {
        let mut session = Session::new();
        session.active_mut().cells.clear();
        session.active_mut().cells.insert((0, 0, 0), 4);
        session.active_mut().cells.insert((1, 0, 0), 1);
        session.active_mut().cells.insert((2, 0, 0), 5);
        session.picked.insert((1, 0, 0));
        session.picked.insert((2, 0, 0));
        let before = session.voxel_count();
        session.rotate_selection(Axis::Z, true);
        assert_eq!(session.voxel_count(), before);
        assert_eq!(session.active().cells.get(&(0, 0, 0)), Some(&4));
        assert!(!session.picked.contains(&(0, 0, 0)));
        assert_eq!(session.active().cells.get(&(1, -1, 0)), Some(&5));
        assert!(session.picked.contains(&(1, -1, 0)));
    }

    #[test]
    fn rotate_object_spins_around_its_center() {
        let mut session = Session::new();
        session.active_mut().cells.clear();
        session.active_mut().cells.insert((0, 0, 0), 1);
        session.active_mut().cells.insert((2, 0, 0), 2);
        session.active_mut().translation = (5, 0, 0);
        session.picked.insert((0, 0, 0));
        session.rotate_object(Axis::Z, false);
        assert_eq!(session.active().translation, (5, 0, 0));
        assert_eq!(session.active().cells.get(&(1, -1, 0)), Some(&1));
        assert_eq!(session.active().cells.get(&(1, 1, 0)), Some(&2));
        assert!(session.picked.is_empty());
        session.undo();
        assert_eq!(session.active().cells.get(&(0, 0, 0)), Some(&1));
        assert_eq!(session.active().cells.get(&(2, 0, 0)), Some(&2));
        assert_eq!(session.active().translation, (5, 0, 0));
    }

    #[test]
    fn flip_object_mirrors_across_the_span_center() {
        let mut session = Session::new();
        session.active_mut().cells.clear();
        session.active_mut().cells.insert((0, 0, 0), 1);
        session.active_mut().cells.insert((1, 0, 0), 2);
        session.active_mut().translation = (4, 1, 0);
        session.flip_object(Axis::X);
        assert_eq!(session.active().translation, (4, 1, 0));
        assert_eq!(session.active().cells.get(&(2, 0, 0)), Some(&1));
        assert_eq!(session.active().cells.get(&(1, 0, 0)), Some(&2));
        session.undo();
        assert_eq!(session.active().cells.get(&(0, 0, 0)), Some(&1));
        assert_eq!(session.active().cells.get(&(1, 0, 0)), Some(&2));
    }

    #[test]
    fn object_band_selects_the_hits_and_a_click_keeps_one() {
        let mut session = Session::new();
        session.objects.push(Volume {
            name: "B".into(),
            cells: HashMap::from([((0, 0, 0), 2)]),
            translation: (4, 0, 0),
        });
        session.finish_object_band(
            &ObjectBand {
                click: false,
                hits: vec![0, 1],
            },
            false,
        );
        assert_eq!(session.object_selection, vec![0, 1]);
        assert_eq!(session.selected, 0);
        session.finish_object_band(
            &ObjectBand {
                click: true,
                hits: Vec::new(),
            },
            false,
        );
        assert_eq!(session.object_selection, vec![0]);
    }

    #[test]
    fn object_drag_moves_every_chosen_object() {
        let mut session = Session::new();
        session.editor_mode = EditorMode::Object;
        session.active_mut().cells.clear();
        session.active_mut().cells.insert((0, 0, 0), 1);
        session.objects.push(Volume {
            name: "B".into(),
            cells: HashMap::from([((0, 0, 0), 2)]),
            translation: (5, 0, 0),
        });
        session.object_selection = vec![0, 1];
        let down = (Vec3::new(0.5, 0.5, 5.0), Vec3::new(0.0, 0.0, -1.0));
        let over = (Vec3::new(2.5, 0.5, 5.0), Vec3::new(0.0, 0.0, -1.0));
        point(&mut session, true, true, false, down);
        point(&mut session, false, false, true, over);
        assert_eq!(session.objects[0].translation, (2, 0, 0));
        assert_eq!(session.objects[1].translation, (7, 0, 0));
        assert_eq!(session.object_selection, vec![0, 1]);
        session.undo();
        assert_eq!(session.objects[0].translation, (0, 0, 0));
        assert_eq!(session.objects[1].translation, (5, 0, 0));
    }

    #[test]
    fn rotate_object_turns_the_whole_selection() {
        let mut session = Session::new();
        session.active_mut().cells.clear();
        session.active_mut().cells.insert((0, 0, 0), 1);
        session.objects.push(Volume {
            name: "B".into(),
            cells: HashMap::from([((0, 0, 0), 2)]),
            translation: (4, 0, 0),
        });
        session.object_selection = vec![0, 1];
        session.rotate_object(Axis::Z, false);
        assert_eq!(session.objects[0].translation, (0, 0, 0));
        assert_eq!(session.objects[0].cells.get(&(2, -2, 0)), Some(&1));
        assert_eq!(session.objects[1].translation, (4, 0, 0));
        assert_eq!(session.objects[1].cells.get(&(-2, 2, 0)), Some(&2));
    }

    #[test]
    fn copy_paste_keeps_unselected_neighbors() {
        let mut session = Session::new();
        session.active_mut().cells.clear();
        session.active_mut().cells.insert((0, 0, 0), 4);
        session.active_mut().cells.insert((1, 0, 0), 5);
        session.active_mut().cells.insert((2, 0, 0), 6);
        session.picked.insert((0, 0, 0));
        session.picked.insert((2, 0, 0));
        session.copy_picked();
        session.delete_picked();
        assert_eq!(session.active().cells.get(&(1, 0, 0)), Some(&5));
        assert!(!session.active().cells.contains_key(&(0, 0, 0)));
        session.paste_clipboard();
        assert_eq!(session.active().cells.get(&(0, 0, 0)), Some(&4));
        assert_eq!(session.active().cells.get(&(1, 0, 0)), Some(&5));
        assert_eq!(session.active().cells.get(&(2, 0, 0)), Some(&6));
        assert!(session.picked.contains(&(0, 0, 0)));
        assert!(session.picked.contains(&(2, 0, 0)));
        assert!(!session.picked.contains(&(1, 0, 0)));
    }

    #[test]
    fn cut_is_one_undo_step() {
        let mut session = Session::new();
        session.active_mut().cells.clear();
        session.active_mut().cells.insert((0, 0, 0), 4);
        session.picked.insert((0, 0, 0));
        session.cut_picked();
        assert!(session.active().cells.is_empty());
        session.undo();
        assert_eq!(session.active().cells.get(&(0, 0, 0)), Some(&4));
        session.paste_clipboard();
        assert_eq!(session.active().cells.get(&(0, 0, 0)), Some(&4));
    }

    #[test]
    fn duplicate_places_the_copy_beside_the_original() {
        let mut session = Session::new();
        session.active_mut().cells.clear();
        session.active_mut().cells.insert((0, 0, 0), 1);
        session.active_mut().cells.insert((2, 0, 0), 1);
        session.duplicate_object();
        assert_eq!(session.objects[0].translation, (0, 0, 0));
        assert_eq!(session.objects[1].translation, (4, 0, 0));
        assert_eq!(session.selected, 1);
        assert_eq!(session.objects[1].cells.len(), 2);
    }

    fn point(session: &mut Session, down: bool, pressed: bool, released: bool, ray: (Vec3, Vec3)) {
        session.pointer(
            true,
            down,
            pressed,
            released,
            false,
            false,
            false,
            false,
            false,
            glam::Vec2::ZERO,
            0.0,
            Some(ray),
            &ToolDrag {
                rays: Vec::new(),
                face_steps: 1,
                marquee: None,
                shift: false,
                object_band: None,
            },
            false,
        );
    }

    #[test]
    fn object_drag_slides_the_translation_and_undoes() {
        let mut session = Session::new();
        session.editor_mode = EditorMode::Object;
        session.active_mut().cells.clear();
        session.active_mut().cells.insert((0, 0, 0), 1);
        session.active_mut().translation = (0, 0, 0);
        let down = (Vec3::new(0.5, 0.5, 5.0), Vec3::new(0.0, 0.0, -1.0));
        let over = (Vec3::new(2.5, 0.5, 5.0), Vec3::new(0.0, 0.0, -1.0));
        point(&mut session, true, true, false, down);
        point(&mut session, false, false, true, over);
        assert_eq!(session.active().translation, (2, 0, 0));
        assert_eq!(session.active().cells.get(&(0, 0, 0)), Some(&1));
        session.undo();
        assert_eq!(session.active().translation, (0, 0, 0));
    }

    #[test]
    fn resize_clips_voxels_past_the_new_size() {
        let mut session = Session::new();
        session.active_mut().cells.clear();
        session.active_mut().cells.insert((0, 0, 0), 1);
        session.active_mut().cells.insert((2, 0, 0), 2);
        assert_eq!(session.size_xyz(), Some((3, 1, 1)));
        session.resize_active(0, 2);
        assert_eq!(session.active().cells.get(&(0, 0, 0)), Some(&1));
        assert!(session.active().cells.get(&(2, 0, 0)).is_none());
        assert_eq!(session.size_xyz(), Some((1, 1, 1)));
        session.resize_active(0, 8);
        assert_eq!(session.size_xyz(), Some((1, 1, 1)));
        session.undo();
        assert_eq!(session.active().cells.get(&(2, 0, 0)), Some(&2));
    }

    #[test]
    fn pick_object_chooses_the_volume_under_the_ray() {
        let mut session = Session::new();
        session.active_mut().cells.clear();
        session.active_mut().cells.insert((0, 0, 0), 1);
        session.duplicate_object();
        let origin = Vec3::new(0.5, 0.5, 5.0);
        let dir = Vec3::new(0.0, 0.0, -1.0);
        assert_eq!(session.pick_object(origin, dir).unwrap().0, 0);
        let origin = Vec3::new(2.5, 0.5, 5.0);
        assert_eq!(session.pick_object(origin, dir).unwrap().0, 1);
    }

    #[test]
    fn palette_range_selects_the_rectangle() {
        let mut session = Session::new();
        session.select_palette_range(0, 31, 1, 30, false);
        assert!(session.palette_slots.contains(&1));
        assert!(session.palette_slots.contains(&2));
        assert!(session.palette_slots.contains(&9));
        assert!(session.palette_slots.contains(&10));
        assert_eq!(session.palette_slots.len(), 4);
        assert_eq!(session.active_slot, 10);
    }

    #[test]
    fn paste_color_and_gradient_undo() {
        let mut session = Session::new();
        session.palette[1] = [0, 0, 0, 255];
        session.palette[2] = [0, 0, 0, 255];
        session.palette[3] = [255, 0, 0, 255];
        session.palette_slots.clear();
        session.palette_slots.insert(1);
        session.palette_slots.insert(2);
        session.palette_slots.insert(3);
        session.copy_palette_color(3);
        session.paste_palette_color(1);
        assert_eq!(session.palette[1][0], 255);
        assert_eq!(session.palette[2][0], 255);
        session.undo();
        assert_eq!(session.palette[1][0], 0);
        assert_eq!(session.palette[2][0], 0);
        session.make_palette_gradient(1);
        assert_eq!(session.palette[2][0], 128);
        assert_eq!(session.palette[1][0], 0);
        assert_eq!(session.palette[3][0], 255);
    }

    #[test]
    fn select_voxels_by_color_matches_the_chosen_slots() {
        let mut session = Session::new();
        session.active_mut().cells.clear();
        session.active_mut().cells.insert((0, 0, 0), 1);
        session.active_mut().cells.insert((1, 0, 0), 2);
        session.active_mut().cells.insert((2, 0, 0), 1);
        session.palette_slots.clear();
        session.palette_slots.insert(1);
        session.select_voxels_by_color(1);
        assert!(session.picked.contains(&(0, 0, 0)));
        assert!(session.picked.contains(&(2, 0, 0)));
        assert!(!session.picked.contains(&(1, 0, 0)));
        session.palette_slots.clear();
        session.palette_slots.insert(9);
        session.paint_picked_with_color(9);
        assert_eq!(session.active().cells.get(&(0, 0, 0)), Some(&9));
        assert_eq!(session.active().cells.get(&(2, 0, 0)), Some(&9));
        session.undo();
        assert_eq!(session.active().cells.get(&(0, 0, 0)), Some(&1));
        session.picked.insert((0, 0, 0));
        session.picked.insert((2, 0, 0));
        session.palette_slots.clear();
        session.palette_slots.insert(1);
        session.palette_slots.insert(2);
        session.paint_picked_with_random_colors(1);
        let a = session.active().cells[&(0, 0, 0)];
        let b = session.active().cells[&(2, 0, 0)];
        assert!(a == 1 || a == 2);
        assert!(b == 1 || b == 2);
    }

    #[test]
    fn paste_lands_on_the_hovered_face() {
        let mut session = Session::new();
        session.active_mut().cells.clear();
        session.active_mut().cells.insert((0, 0, 0), 4);
        session.active_mut().cells.insert((1, 0, 0), 5);
        session.picked.insert((0, 0, 0));
        session.picked.insert((1, 0, 0));
        session.copy_picked();
        session.hover = Some(Hit {
            cell: (5, 0, 0),
            normal: (0, 0, 1),
        });
        session.paste_clipboard();
        assert_eq!(session.active().cells.get(&(5, 0, 1)), Some(&4));
        assert_eq!(session.active().cells.get(&(6, 0, 1)), Some(&5));
        assert_eq!(session.active().cells.get(&(0, 0, 0)), Some(&4));
        assert!(session.picked.contains(&(5, 0, 1)));
        assert!(!session.picked.contains(&(0, 0, 0)));
    }

    #[test]
    fn paste_without_a_hover_uses_the_original_origin() {
        let mut session = Session::new();
        session.active_mut().cells.clear();
        session.active_mut().cells.insert((2, 3, 4), 7);
        session.picked.insert((2, 3, 4));
        session.copy_picked();
        session.active_mut().cells.insert((2, 3, 4), 1);
        session.hover = None;
        session.paste_clipboard();
        assert_eq!(session.active().cells.get(&(2, 3, 4)), Some(&7));
    }

    #[test]
    fn move_slides_on_the_clicked_plane_and_undoes() {
        let mut session = Session::new();
        session.active_mut().cells.clear();
        session.active_mut().cells.insert((0, 0, 0), 4);
        session.active_mut().cells.insert((3, 0, 0), 9);
        session.picked.insert((0, 0, 0));
        let down = (Vec3::new(0.5, 0.5, 5.0), Vec3::new(0.0, 0.0, -1.0));
        let empty = ToolDrag {
            rays: Vec::new(),
            face_steps: 1,
            marquee: None,
            shift: false,
            object_band: None,
        };
        session.pointer(
            true,
            true,
            true,
            false,
            false,
            false,
            false,
            false,
            false,
            glam::Vec2::ZERO,
            0.0,
            Some(down),
            &empty,
            true,
        );
        let shifted = (Vec3::new(2.6, 0.4, 5.0), Vec3::new(0.0, 0.0, -1.0));
        session.pointer(
            true,
            true,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            glam::Vec2::ZERO,
            0.0,
            Some(shifted),
            &empty,
            true,
        );
        assert_eq!(session.active().cells.get(&(2, 0, 0)), Some(&4));
        assert!(!session.active().cells.contains_key(&(0, 0, 0)));
        assert_eq!(session.active().cells.get(&(3, 0, 0)), Some(&9));
        session.pointer(
            true,
            false,
            false,
            true,
            false,
            false,
            false,
            false,
            false,
            glam::Vec2::ZERO,
            0.0,
            Some(shifted),
            &empty,
            true,
        );
        session.undo();
        assert_eq!(session.active().cells.get(&(0, 0, 0)), Some(&4));
        assert!(!session.active().cells.contains_key(&(2, 0, 0)));
    }

    #[test]
    fn plane_delta_locks_the_clicked_axis() {
        let delta = plane_delta(2, Vec3::new(0.5, 0.5, 1.0), Vec3::new(2.4, -0.6, 1.0));
        assert_eq!(delta, (2, -1, 0));
    }

    #[test]
    fn paste_overwrites_the_cell_underneath() {
        let mut session = Session::new();
        session.active_mut().cells.clear();
        session.active_mut().cells.insert((0, 0, 0), 4);
        session.picked.insert((0, 0, 0));
        session.copy_picked();
        session.active_mut().cells.insert((0, 0, 0), 9);
        session.paste_clipboard();
        assert_eq!(session.active().cells.get(&(0, 0, 0)), Some(&4));
        session.undo();
        assert_eq!(session.active().cells.get(&(0, 0, 0)), Some(&9));
    }

    #[test]
    fn delete_picked_removes_only_the_selection() {
        let mut session = Session::new();
        session.active_mut().cells.clear();
        session.active_mut().cells.insert((0, 0, 0), 4);
        session.active_mut().cells.insert((1, 0, 0), 5);
        session.picked.insert((1, 0, 0));
        session.delete_picked();
        assert_eq!(session.active().cells.get(&(0, 0, 0)), Some(&4));
        assert!(!session.active().cells.contains_key(&(1, 0, 0)));
        assert!(session.picked.is_empty());
        session.undo();
        assert_eq!(session.active().cells.get(&(1, 0, 0)), Some(&5));
    }

    #[test]
    fn line_drag_adds_voxels_and_undoes() {
        let mut session = Session::new();
        let before = session.voxel_count();
        session.tool = Tool::Line;
        session.tool_mode = ToolMode::Add;
        session.checkpoint();
        let dir = Vec3::new(0.0, 1.0, -0.35);
        session.preview_tool(Vec3::new(0.5, -30.0, 10.0), dir, &[], 1);
        session.preview_tool(Vec3::new(5.5, -30.0, 10.0), dir, &[], 1);
        assert!(session.voxel_count() > before);
        session.stroke = None;
        session.commit();
        session.undo();
        assert_eq!(session.voxel_count(), before);
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

    fn at_origin(cells: &HashMap<Cell, u8>) -> HashMap<Cell, u8> {
        if cells.is_empty() {
            return HashMap::new();
        }
        let mut min = *cells.keys().next().unwrap();
        for cell in cells.keys() {
            min.0 = min.0.min(cell.0);
            min.1 = min.1.min(cell.1);
            min.2 = min.2.min(cell.2);
        }
        cells
            .iter()
            .map(|(cell, index)| ((cell.0 - min.0, cell.1 - min.1, cell.2 - min.2), *index))
            .collect()
    }

    fn sample() -> (HashMap<Cell, u8>, [[u8; 4]; 256], [Material; 256]) {
        let mut cells = HashMap::new();
        cells.insert((5, -2, 3), 36);
        cells.insert((7, -2, 4), 10);
        cells.insert((5, 0, 3), 20);
        let mut palette = default_palette();
        palette[36] = [11, 22, 33, 255];
        palette[10] = [200, 10, 10, 255];
        palette[20] = [0, 180, 40, 255];
        let mut materials = [Material::default(); 256];
        materials[36] = Material {
            ty: MaterialType::Metal,
            roughness: 0.25,
            metallic: 0.5,
            ..Material::default()
        };
        materials[10] = Material {
            ty: MaterialType::Glass,
            roughness: 0.5,
            transparency: 0.25,
            ior: 2.0,
            ..Material::default()
        };
        materials[20] = Material {
            ty: MaterialType::Emissive,
            emission: 0.5,
            emission_power: 3,
            ..Material::default()
        };
        (cells, palette, materials)
    }

    #[test]
    fn save_round_trips_voxels_palette_and_materials() {
        let (cells, palette, materials) = sample();
        let bytes = save_vox(&cells, &palette, &materials).expect("save");
        let again = save_vox(&cells, &palette, &materials).expect("save");
        assert_eq!(bytes, again);
        assert!(bytes.windows(4).any(|w| w == b"MATL"));

        let loaded = load_vox(&bytes).expect("load");
        assert_eq!(at_origin(&loaded.cells), at_origin(&cells));
        assert_eq!(loaded.palette.unwrap()[36], [11, 22, 33, 255]);
        assert_eq!(loaded.palette.unwrap()[10], [200, 10, 10, 255]);
        assert_eq!(loaded.materials[36], materials[36]);
        assert_eq!(loaded.materials[10], materials[10]);
        assert_eq!(loaded.materials[20], materials[20]);
        assert_eq!(loaded.materials[1], Material::default());

        let defaults = save_vox(&cells, &default_palette(), &[Material::default(); 256]).unwrap();
        assert!(!defaults.windows(4).any(|w| w == b"MATL"));

        if let Ok(path) = std::env::var("MACVOXEL_SAMPLE_VOX") {
            std::fs::write(path, &bytes).unwrap();
        }
    }

    #[test]
    fn save_refuses_empty_and_oversized_volumes() {
        let palette = default_palette();
        let materials = [Material::default(); 256];
        let err = save_vox(&HashMap::new(), &palette, &materials).unwrap_err();
        assert!(err.contains("empty"));

        let mut wide = HashMap::new();
        wide.insert((0, 0, 0), 1);
        wide.insert((256, 0, 0), 1);
        let err = save_vox(&wide, &palette, &materials).unwrap_err();
        assert!(err.contains("256"));
    }

    #[test]
    fn undo_survives_a_save() {
        let mut session = Session::new();
        let before = session.voxel_count();
        session.checkpoint();
        session.stamp(Hit {
            cell: (0, 0, 0),
            normal: (0, 0, 1),
        });
        session.commit();
        let path = std::env::temp_dir().join("macvoxel-egui-undo.vox");
        session.write_vox(&path).unwrap();
        assert!(session.status.starts_with("Saved "));
        session.undo();
        assert_eq!(session.voxel_count(), before);
        let _ = std::fs::remove_file(path);
    }

    fn world_of(object: &LoadedObject, color: u8) -> Cell {
        let (cell, _) = object
            .cells
            .iter()
            .find(|(_, slot)| **slot == color)
            .expect("color");
        (
            cell.0 + object.translation.0,
            cell.1 + object.translation.1,
            cell.2 + object.translation.2,
        )
    }

    #[test]
    fn scene_save_keeps_each_object_in_place() {
        let mut first = HashMap::new();
        first.insert((0, 0, 0), 1);
        let mut second = HashMap::new();
        second.insert((0, 0, 0), 2);
        let objects = vec![
            Volume {
                name: "A".into(),
                cells: first,
                translation: (0, 0, 0),
            },
            Volume {
                name: "B".into(),
                cells: second,
                translation: (5, 0, 0),
            },
        ];
        let bytes = save_scene(&objects, &default_palette(), &[Material::default(); 256]).unwrap();
        let loaded = load_vox(&bytes).expect("scene");
        assert_eq!(loaded.objects.len(), 2);
        assert_eq!(loaded.objects[0].name, "A");
        assert_eq!(loaded.objects[1].name, "B");
        assert_eq!(world_of(&loaded.objects[0], 1), (0, 0, 0));
        assert_eq!(world_of(&loaded.objects[1], 2), (5, 0, 0));
    }

    #[test]
    fn scene_rotation_is_baked_into_the_cells() {
        let mut size = Vec::new();
        for dim in [2u32, 2, 2] {
            size.extend_from_slice(&dim.to_le_bytes());
        }
        let mut xyzi = Vec::new();
        xyzi.extend_from_slice(&2u32.to_le_bytes());
        xyzi.extend_from_slice(&[0, 0, 0, 3]);
        xyzi.extend_from_slice(&[0, 0, 1, 7]);
        let mut rot = Vec::new();
        push_i32(&mut rot, 0);
        push_dict(&mut rot, &[]);
        push_i32(&mut rot, 1);
        push_i32(&mut rot, -1);
        push_i32(&mut rot, -1);
        push_i32(&mut rot, 1);
        push_dict(&mut rot, &[("_r", "8")]);
        let mut shape = Vec::new();
        push_i32(&mut shape, 1);
        push_dict(&mut shape, &[]);
        push_i32(&mut shape, 1);
        push_i32(&mut shape, 0);
        push_dict(&mut shape, &[]);
        let mut children = chunk(b"SIZE", &size);
        children.extend(chunk(b"XYZI", &xyzi));
        children.extend(chunk(b"nTRN", &rot));
        children.extend(chunk(b"nSHP", &shape));
        let file = wrap_vox(children);
        let loaded = load_vox(&file).expect("rotated");
        let object = &loaded.objects[0];
        let low = object.cells.iter().find(|(_, slot)| **slot == 3).unwrap().0;
        let high = object.cells.iter().find(|(_, slot)| **slot == 7).unwrap().0;
        assert_eq!((high.0 - low.0, high.1 - low.1, high.2 - low.2), (0, 1, 0));
    }

    /// After `MacVoxel voxrt --output` resaves a sample, the geometry,
    /// palette, and materials must still match. Skipped unless
    /// `MACVOXEL_RESAVE_VOX` points at that file.
    #[test]
    fn macvoxel_resave_keeps_the_sample() {
        let Ok(path) = std::env::var("MACVOXEL_RESAVE_VOX") else {
            return;
        };
        let (cells, palette, materials) = sample();
        let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("read {path}: {e}"));
        let loaded = load_vox(&bytes).expect("resave");
        assert_eq!(at_origin(&loaded.cells), at_origin(&cells));
        let loaded_palette = loaded.palette.expect("rgba");
        assert_eq!(loaded_palette[36], palette[36]);
        assert_eq!(loaded_palette[10], palette[10]);
        assert_eq!(loaded_palette[20], palette[20]);
        assert_eq!(loaded.materials[36], materials[36]);
        assert_eq!(loaded.materials[10], materials[10]);
        assert_eq!(loaded.materials[20], materials[20]);
    }

    #[test]
    fn face_click_on_an_empty_wall_paints_empty_cells() {
        let mut session = Session::new();
        session.objects[0].cells.clear();
        for x in 0..4 {
            for y in 0..4 {
                session.objects[0].cells.insert((x, y, 0), 1);
            }
        }
        session.objects[0].cells.insert((0, 0, 4), 2);
        session.tool = Tool::Face;
        session.tool_mode = ToolMode::Add;
        session.active_slot = 9;
        session.editor_mode = EditorMode::Model;
        session.render_mode = RenderMode::Edit;
        let ray = (Vec3::new(1.5, -5.0, 2.5), Vec3::new(0.0, 1.0, 0.0));
        session.click_viewport(ray);
        assert_eq!(session.active().cells.get(&(1, 3, 2)), Some(&9));
        assert_eq!(session.active().cells.get(&(1, 0, 0)), Some(&1));
        assert_eq!(session.active().cells.get(&(0, 0, 4)), Some(&2));
    }

    #[test]
    fn recent_paths_keep_the_newest_ten() {
        let mut list = Vec::new();
        for i in 0..12 {
            remember(&mut list, Path::new(&format!("/tmp/m{i}.vox")));
        }
        assert_eq!(list.len(), 10);
        assert_eq!(list[0], PathBuf::from("/tmp/m11.vox"));
        remember(&mut list, Path::new("/tmp/m5.vox"));
        assert_eq!(list[0], PathBuf::from("/tmp/m5.vox"));
        assert_eq!(
            list.iter().filter(|path| path.ends_with("m5.vox")).count(),
            1
        );
    }

    #[test]
    fn ui_click_selects_the_registered_tool() {
        let mut session = Session::new();
        session.note_ui(
            "viewport",
            "Viewport",
            egui::Rect::from_min_size(egui::pos2(0.0, 0.0), egui::vec2(100.0, 100.0)),
            UiAction::Viewport,
        );
        session.note_ui(
            "tool.line",
            "Line",
            egui::Rect::from_min_size(egui::pos2(0.0, 0.0), egui::vec2(20.0, 20.0)),
            UiAction::Tool(Tool::Line),
        );
        let hit = session.ui_target(5.0, 5.0).unwrap();
        assert_eq!(hit.id, "tool.line");
        session.activate_ui(&hit).unwrap();
        assert!(session.tool == Tool::Line);
        let described = session.describe_ui();
        assert_eq!(described["tool"], "Line");
        assert_eq!(described["regions"][1]["id"], "tool.line");
    }
}
