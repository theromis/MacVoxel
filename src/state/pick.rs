//! Marquee, box, and flood selection, plus keyboard shortcuts.

use std::collections::{HashMap, HashSet};

use glam::Vec3;

use super::geom::*;
use super::*;

use super::selection::Cmd;

impl Session {
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
            } else if !object_mode && !command && i.key_pressed(egui::Key::T) {
                cmd = Some(Cmd::Mode(ToolMode::Add));
            } else if !object_mode && !command && i.key_pressed(egui::Key::R) {
                cmd = Some(Cmd::Mode(ToolMode::Remove));
            } else if !object_mode && !command && i.key_pressed(egui::Key::G) {
                cmd = Some(Cmd::Mode(ToolMode::Paint));
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
            Some(Cmd::Mode(mode)) => self.tool_mode = mode,
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

    pub(super) fn clear_picked(&mut self) {
        if self.picked.is_empty() {
            return;
        }
        self.picked.clear();
        self.selection_epoch = self.selection_epoch.wrapping_add(1);
    }

    pub(super) fn set_picked(&mut self, next: HashSet<Cell>) {
        if next == self.picked {
            return;
        }
        self.picked = next;
        self.note_selection();
    }

    pub(super) fn note_selection(&mut self) {
        self.selection_epoch = self.selection_epoch.wrapping_add(1);
        let n = self.picked.len();
        self.status = if n == 0 {
            IDLE.into()
        } else {
            format!("{n} voxels selected.")
        };
    }

    pub(super) fn begin_select(&mut self, ray: Option<(Vec3, Vec3)>) {
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

    pub(super) fn drag_select(&mut self, ray: Option<(Vec3, Vec3)>) {
        if self.tool == Tool::BoxSelect {
            self.drag_box(ray);
        }
    }

    pub(super) fn finish_select(&mut self, ray: Option<(Vec3, Vec3)>, drag: &ToolDrag) {
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

    pub(super) fn drag_box(&mut self, ray: Option<(Vec3, Vec3)>) {
        let Some(anchor) = self.select_anchor else {
            return;
        };
        let Some(end) = self.hit_cell(ray) else {
            return;
        };
        self.set_picked(cells_in_aabb(&self.active().cells, anchor, end));
    }

    pub(super) fn flood_at(&mut self, seed: Cell) {
        let Some(&slot) = self.active().cells.get(&seed) else {
            self.set_picked(HashSet::new());
            return;
        };
        self.set_picked(flood_same(&self.active().cells, seed, slot));
    }

    pub(super) fn local_ray(&self, ray: Option<(Vec3, Vec3)>) -> Option<(Vec3, Vec3)> {
        let (origin, dir) = ray?;
        let shift = self.active().translation;
        Some((
            origin - Vec3::new(shift.0 as f32, shift.1 as f32, shift.2 as f32),
            dir,
        ))
    }

    pub(super) fn pick_object(&self, origin: Vec3, dir: Vec3) -> Option<(usize, Hit)> {
        let mut best: Option<(f32, usize, Hit)> = None;
        for (index, object) in self.objects.iter().enumerate() {
            if object.hidden {
                continue;
            }
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

    pub(super) fn hit_cell(&self, ray: Option<(Vec3, Vec3)>) -> Option<Cell> {
        let (origin, dir) = ray?;
        raycast(&self.active().cells, origin, dir).map(|hit| hit.cell)
    }

    pub(super) fn map_picked(&mut self, mut map: impl FnMut(Cell) -> Cell) {
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
