//! Open, save, export, and the clickable panel regions.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use glam::Vec3;

use super::geom::*;
use super::vox::*;
use super::*;

impl Session {
    pub fn new_document(&mut self) {
        self.commit();
        self.objects.clear();
        self.objects.push(Volume {
            name: "Tree".into(),
            cells: demo_tree(),
            translation: (0, 0, 0),
            box_min: (0, 0, 0),
            dims: (0, 0, 0),
            rot: ROT_IDENTITY,
            pivot: (0, 0, 0),
            model_dims: (0, 0, 0),
            hidden: false,
            file: None,
            bone: None,
            script: Default::default(),
        });
        self.selected = 0;
        self.focus_object();
        self.next_object = 2;
        self.path = None;
        self.graph = None;
        self.skeleton = Skeleton::default();
        self.selected_bone = None;
        self.palette = default_palette();
        self.materials = [Material::default(); 256];
        self.undo.clear();
        self.redo.clear();
        self.pending = None;
        self.clear_picked();
        self.script_error.clear();
        self.script_due = None;
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
            let mut file = object.file;
            if let Some(link) = file.as_mut() {
                link.name = name.clone();
            }
            self.objects.push(Volume {
                name,
                cells: object.cells,
                translation: object.translation,
                box_min: object.box_min,
                dims: object.dims,
                rot: object.rot,
                pivot: object.pivot,
                model_dims: object.model_dims,
                hidden: object.hidden,
                file,
                bone: object.bone,
                script: object.script,
            });
        }
        if self.objects.is_empty() {
            self.objects.push(Volume {
                name: stem,
                cells: HashMap::new(),
                translation: (0, 0, 0),
                box_min: (0, 0, 0),
                dims: (0, 0, 0),
                rot: ROT_IDENTITY,
                pivot: (0, 0, 0),
                model_dims: (0, 0, 0),
                hidden: false,
                file: None,
                bone: None,
                script: Default::default(),
            });
        }
        self.selected = 0;
        self.focus_object();
        self.next_object = (self.objects.len() as u32).saturating_add(1).max(2);
        self.palette = loaded.palette.unwrap_or_else(default_palette);
        self.materials = loaded.materials;
        self.graph = loaded.graph;
        self.skeleton = loaded.skeleton;
        self.selected_bone = None;
        self.path = Some(path.to_path_buf());
        self.undo.clear();
        self.redo.clear();
        self.pending = None;
        self.clear_picked();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.frame_camera();
        let file = path.file_name().unwrap_or_default().to_string_lossy();
        self.script_error.clear();
        self.script_due = None;
        self.status = if models > 1 {
            format!("Loaded {n} voxels in {models} objects from {file}.")
        } else {
            format!("Loaded {n} voxels from {file}.")
        };
        if self
            .objects
            .iter()
            .any(|object| !object.script.source.is_empty())
        {
            self.status.push_str(" This file carries a script.");
        }
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
            box_min: (0, 0, 0),
            dims: (0, 0, 0),
            rot: ROT_IDENTITY,
            pivot: (0, 0, 0),
            model_dims: (0, 0, 0),
            hidden: false,
            file: None,
            bone: None,
            script: Default::default(),
        });
        self.selected = 0;
        self.focus_object();
        self.next_object = 2;
        self.path = None;
        self.graph = None;
        self.skeleton = Skeleton::default();
        self.selected_bone = None;
        self.palette = default_palette();
        self.materials = [Material::default(); 256];
        self.undo.clear();
        self.redo.clear();
        self.pending = None;
        self.script_error.clear();
        self.script_due = None;
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

    pub(crate) fn write_palette(&mut self, slots: &[PaletteChange]) -> i64 {
        let mut changed = 0i64;
        for change in slots {
            let index = change.index as usize;
            let material = self.materials[index];
            let motion = change.motion.unwrap_or(material.motion);
            let amount = change.amount.unwrap_or(material.motion_amount);
            if self.palette[index] != change.rgba
                || material.motion != motion
                || material.motion_amount != amount
            {
                changed += 1;
            }
        }
        if changed == 0 {
            return 0;
        }
        self.commit();
        self.checkpoint();
        for change in slots {
            let index = change.index as usize;
            self.palette[index] = change.rgba;
            if let Some(motion) = change.motion {
                self.materials[index].motion = motion;
            }
            if let Some(amount) = change.amount {
                self.materials[index].motion_amount = amount.clamp(0.0, 4.0);
            }
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
        let bytes = match save_document(
            &self.objects,
            &self.palette,
            &self.materials,
            self.graph.as_ref(),
            &self.skeleton,
        ) {
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

    /// Write the current Render-mode frame. The picture is the one on screen.
    pub fn save_render(&mut self) {
        let Some(path) = self.pick_render_path() else {
            return;
        };
        if self.trace_on_gpu {
            self.render_save_path = Some(path);
            return;
        }
        let Some(image) = self.render_preview.clone() else {
            self.status = "Switch to Render and wait for a sample.".into();
            return;
        };
        if image.samples == 0 && image.row_progress() == 0 {
            self.status = "Switch to Render and wait for a sample.".into();
            return;
        }
        match crate::trace::write_png(&path, &image, self) {
            Ok(()) => {
                let file = path
                    .file_name()
                    .map(|s| s.to_string_lossy().into_owned())
                    .unwrap_or_else(|| path.display().to_string());
                self.status = format!("Saved render to {file}.");
            }
            Err(err) => self.status = err,
        }
    }

    pub(super) fn pick_render_path(&self) -> Option<PathBuf> {
        let name = format!("{}.png", self.active().name);
        let path = rfd::FileDialog::new()
            .add_filter("PNG", &["png"])
            .set_file_name(name)
            .save_file()?;
        Some(if path.extension().is_some() {
            path
        } else {
            path.with_extension("png")
        })
    }

    pub fn recent_paths(&self) -> Vec<PathBuf> {
        self.recent.clone()
    }

    pub(super) fn remember_path(&mut self, path: &Path) {
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

    pub fn activate_ui(&mut self, region: &UiRegion, at: Option<(f32, f32)>) -> Result<(), String> {
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
            UiAction::Palette(slot) => self.select_palette_slot(slot, false),
            UiAction::Slider(spec) => {
                let (x, _) = at.ok_or("slider click needs a point")?;
                let t = if region.w <= f32::EPSILON {
                    0.0
                } else {
                    (x - region.x) / region.w
                };
                self.apply_slider(spec, t);
            }
        }
        Ok(())
    }

    pub(super) fn apply_slider(&mut self, spec: SliderSpec, t: f32) {
        let t = t.clamp(0.0, 1.0);
        let value = spec.min + (spec.max - spec.min) * t;
        if spec.target.is_material() {
            self.checkpoint();
        }
        self.write_slider(spec.target, value);
        if spec.target.is_material() {
            self.commit();
        }
    }

    pub(crate) fn write_slider(&mut self, target: SliderTarget, value: f32) {
        let whole = value.round() as i32;
        match target {
            SliderTarget::BrushSize => self.brush_size = whole.clamp(1, 63),
            SliderTarget::FoliageSeed => self.foliage_seed = whole.clamp(1, 255),
            SliderTarget::FoliageDensity => self.foliage_density = value.clamp(0.0, 1.0),
            SliderTarget::TorusTube => self.torus_tube = value.clamp(0.05, 1.0),
            SliderTarget::NoiseScale => self.noise_scale = value.clamp(1.0, 64.0),
            SliderTarget::NoiseThreshold => self.noise_threshold = value.clamp(0.0, 1.0),
            SliderTarget::NoiseOctaves => self.noise_octaves = whole.clamp(1, 6),
            SliderTarget::NoiseSeed => self.noise_seed = whole.clamp(0, 9999),
            SliderTarget::PerlinLo => self.perlin_lo = whole.clamp(1, 255),
            SliderTarget::PerlinHi => self.perlin_hi = whole.clamp(1, 255),
            SliderTarget::TreeDepth => self.tree_depth = whole.clamp(1, 5),
            SliderTarget::TreeWildness => self.tree_wildness = value.clamp(0.0, 1.0),
            SliderTarget::TreeTrunk => self.tree_trunk = value.clamp(0.20, 1.50),
            SliderTarget::TreeLeaf => self.tree_leaf = whole.clamp(1, 255),
            SliderTarget::TreeSeed => self.tree_seed = whole.clamp(0, 9999),
            SliderTarget::HelixTurns => self.helix_turns = value.clamp(0.25, 12.0),
            SliderTarget::HelixRadius => self.helix_radius = value.clamp(0.0, 1.0),
            SliderTarget::HelixTube => self.helix_tube = value.clamp(0.02, 0.90),
            SliderTarget::ConiferTiers => self.conifer_tiers = whole.clamp(2, 5),
            SliderTarget::ConiferRagged => self.conifer_ragged = value.clamp(0.0, 1.0),
            SliderTarget::ConiferClump => self.conifer_clump = value.clamp(2.0, 24.0),
            SliderTarget::ConiferTrunk => self.conifer_trunk = value.clamp(0.20, 1.50),
            SliderTarget::ConiferCrown => self.conifer_crown = value.clamp(0.0, 1.0),
            SliderTarget::ConiferNeedle => self.conifer_needle = whole.clamp(1, 255),
            SliderTarget::ConiferSeed => self.conifer_seed = whole.clamp(0, 9999),
            SliderTarget::MaxSamples => self.max_samples = whole.clamp(16, 8192),
            SliderTarget::Aperture => self.aperture = value.clamp(0.0, 3.0),
            SliderTarget::FocusDistance => self.focus_distance = value.clamp(1.0, 500.0),
            SliderTarget::MaterialRoughness => {
                self.material_mut().roughness = value.clamp(0.0, 1.0)
            }
            SliderTarget::MaterialMetallic => self.material_mut().metallic = value.clamp(0.0, 1.0),
            SliderTarget::MaterialTransparency => {
                self.material_mut().transparency = value.clamp(0.0, 1.0);
            }
            SliderTarget::MaterialIor => self.material_mut().ior = value.clamp(1.0, 3.0),
            SliderTarget::MaterialEmission => {
                self.material_mut().emission = (value / 100.0).clamp(0.0, 1.0);
            }
            SliderTarget::MaterialPower => self.material_mut().emission_power = whole.clamp(1, 5),
            SliderTarget::MotionAmount => {
                self.material_mut().motion_amount = value.clamp(0.0, 4.0);
                self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
            }
            SliderTarget::MaxBounces => self.max_bounces = whole.clamp(1, 8),
            SliderTarget::NeeRis => self.nee_ris = whole.clamp(1, 32),
            SliderTarget::IndirectClamp => self.indirect_clamp = value.clamp(0.0, 32.0),
            SliderTarget::EmaFloor => self.ema_floor = value.clamp(0.0, 1.0),
            SliderTarget::SkyIntensity => self.sky_intensity = value.clamp(0.0, 4.0),
            SliderTarget::HorizonSoftness => self.horizon_softness = value.clamp(0.0, 15.0),
            SliderTarget::SunElevation => self.sun_elevation = value.clamp(-90.0, 90.0),
            SliderTarget::SunAzimuth => self.sun_azimuth = value.clamp(0.0, 360.0),
            SliderTarget::SunDisc => self.sun_disc = value.clamp(0.1, 30.0),
            SliderTarget::SunIntensity => self.sun_intensity = value.clamp(0.0, 10.0),
        }
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
}
