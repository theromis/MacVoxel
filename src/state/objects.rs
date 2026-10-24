//! Objects, bones, and undo.

use std::collections::HashMap;

use super::geom::*;
use super::vox::*;
use super::*;

impl Session {
    /// Empty object at a world voxel position. `size` is the SIZE box when
    /// set; voxels may still grow it up to the per-axis save limit.
    pub fn add_object(
        &mut self,
        name: Option<&str>,
        position: [i32; 3],
        size: Option<[i32; 3]>,
        make_active: bool,
    ) -> Result<usize, String> {
        if let Some(size) = size {
            for axis in size {
                if !(1..=256).contains(&axis) {
                    return Err("size must be 1..=256 on each axis".into());
                }
            }
        }
        let name = match name {
            Some(name) => check_object_name(name)?,
            None => self.fresh_object_name(),
        };
        self.commit();
        self.checkpoint();
        self.objects.push(Volume {
            name,
            cells: HashMap::new(),
            translation: (position[0], position[1], position[2]),
            box_min: (0, 0, 0),
            dims: size
                .map(|size| (size[0], size[1], size[2]))
                .unwrap_or((0, 0, 0)),
            rot: ROT_IDENTITY,
            pivot: (0, 0, 0),
            model_dims: (0, 0, 0),
            hidden: false,
            file: None,
            bone: None,
            script: Default::default(),
        });
        let index = self.objects.len() - 1;
        if make_active {
            self.selected = index;
            self.focus_object();
        }
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.commit();
        Ok(index)
    }

    pub fn set_object(
        &mut self,
        index: usize,
        name: Option<&str>,
        position: Option<[i32; 3]>,
        hidden: Option<bool>,
    ) -> Result<(), String> {
        if index >= self.objects.len() {
            return Err(format!(
                "object index {index} is out of range ({} objects)",
                self.objects.len()
            ));
        }
        if name.is_none() && position.is_none() && hidden.is_none() {
            return Err("set_object needs a name, position, or hidden".into());
        }
        let next_name = match name {
            Some(name) => check_object_name(name)?,
            None => self.objects[index].name.clone(),
        };
        let next_position = position.unwrap_or([
            self.objects[index].translation.0,
            self.objects[index].translation.1,
            self.objects[index].translation.2,
        ]);
        let next_hidden = hidden.unwrap_or(self.objects[index].hidden);
        let object = &self.objects[index];
        if next_name == object.name
            && next_position
                == [
                    object.translation.0,
                    object.translation.1,
                    object.translation.2,
                ]
            && next_hidden == object.hidden
        {
            return Ok(());
        }
        self.commit();
        self.checkpoint();
        let object = &mut self.objects[index];
        let delta = (
            next_position[0] - object.translation.0,
            next_position[1] - object.translation.1,
            next_position[2] - object.translation.2,
        );
        object.name = next_name;
        object.translation = (next_position[0], next_position[1], next_position[2]);
        if object.model_dims != (0, 0, 0) {
            object.pivot.0 += delta.0;
            object.pivot.1 += delta.1;
            object.pivot.2 += delta.2;
        }
        object.hidden = next_hidden;
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.commit();
        Ok(())
    }

    /// Drop one object. Its bone stays in the skeleton; the binding goes
    /// with the object. Later indices decrease by one.
    pub fn remove_object(&mut self, index: usize) -> Result<(), String> {
        if self.objects.len() < 2 {
            return Err("cannot remove the last object".into());
        }
        if index >= self.objects.len() {
            return Err(format!(
                "object index {index} is out of range ({} objects)",
                self.objects.len()
            ));
        }
        self.commit();
        self.checkpoint();
        self.objects.remove(index);
        self.object_selection = self
            .object_selection
            .iter()
            .filter_map(|found| {
                if *found == index {
                    None
                } else if *found > index {
                    Some(found - 1)
                } else {
                    Some(*found)
                }
            })
            .collect();
        if self.selected == index {
            self.selected = index.min(self.objects.len() - 1);
        } else if self.selected > index {
            self.selected -= 1;
        }
        if self.object_selection.is_empty() {
            self.focus_object();
        }
        self.clear_picked();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.commit();
        Ok(())
    }

    fn fresh_object_name(&mut self) -> String {
        let mut number = self.next_object.max(1);
        let name = loop {
            let candidate = format!("Object {number}");
            if self.objects.iter().all(|object| object.name != candidate) {
                break candidate;
            }
            number += 1;
        };
        self.next_object = number.saturating_add(1);
        name
    }

    pub fn new_object(&mut self) {
        self.commit();
        self.checkpoint();
        let name = self.fresh_object_name();
        let translation = beside(self.active());
        self.objects.push(Volume {
            name,
            cells: HashMap::new(),
            translation,
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
        self.selected = self.objects.len() - 1;
        self.focus_object();
        self.mesh_epoch = self.mesh_epoch.wrapping_add(1);
        self.commit();
    }

    pub fn duplicate_object(&mut self) {
        self.commit();
        self.checkpoint();
        let source = self.active();
        let translation = beside(source);
        let delta = (
            translation.0 - source.translation.0,
            translation.1 - source.translation.1,
            translation.2 - source.translation.2,
        );
        let copy = Volume {
            name: format!("{} copy", source.name),
            cells: source.cells.clone(),
            translation,
            box_min: source.box_min,
            dims: source.dims,
            rot: source.rot,
            pivot: (
                source.pivot.0 + delta.0,
                source.pivot.1 + delta.1,
                source.pivot.2 + delta.2,
            ),
            model_dims: source.model_dims,
            hidden: source.hidden,
            file: None,
            bone: source.bone.clone(),
            script: source.script.clone(),
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

    pub fn add_bone(
        &mut self,
        name: &str,
        parent: Option<&str>,
        pivot: [f32; 3],
        rotation: Option<[f32; 4]>,
    ) -> Result<(), String> {
        let mut next = self.skeleton.clone();
        next.add(name, parent, pivot, rotation)?;
        self.checkpoint();
        self.skeleton = next;
        self.selected_bone = Some(self.skeleton.bones.len() - 1);
        self.commit();
        Ok(())
    }

    pub fn set_bone(
        &mut self,
        name: &str,
        parent: Option<Option<String>>,
        pivot: Option<[f32; 3]>,
        rotation: Option<[f32; 4]>,
        rename: Option<&str>,
    ) -> Result<(), String> {
        let mut next = self.skeleton.clone();
        let renamed = next.set(name, parent, pivot, rotation, rename)?;
        self.checkpoint();
        self.skeleton = next;
        if let Some(next_name) = renamed {
            for object in &mut self.objects {
                if object.bone.as_deref() == Some(name) {
                    object.bone = Some(next_name.clone());
                }
            }
            if let Some(index) = self.skeleton.index_of(&next_name) {
                self.selected_bone = Some(index);
            }
        }
        self.commit();
        Ok(())
    }

    pub fn remove_bone(&mut self, name: &str) -> Result<(), String> {
        let removed = self.skeleton.index_of(name);
        let mut next = self.skeleton.clone();
        next.remove(name)?;
        self.checkpoint();
        self.skeleton = next;
        for object in &mut self.objects {
            if object.bone.as_deref() == Some(name) {
                object.bone = None;
            }
        }
        if let Some(index) = self.selected_bone {
            if Some(index) == removed {
                self.selected_bone = None;
            } else if removed.is_some_and(|gone| index > gone) {
                self.selected_bone = Some(index - 1);
            }
        }
        self.commit();
        Ok(())
    }

    pub fn bind_object(&mut self, index: usize, bone: Option<&str>) -> Result<(), String> {
        if index >= self.objects.len() {
            return Err(format!(
                "object index {index} is out of range ({} objects)",
                self.objects.len()
            ));
        }
        if let Some(name) = bone {
            if self.skeleton.index_of(name).is_none() {
                return Err(format!("unknown bone `{name}`"));
            }
        }
        let next = bone.map(str::to_string);
        if self.objects[index].bone == next {
            return Ok(());
        }
        self.checkpoint();
        self.objects[index].bone = next;
        self.commit();
        Ok(())
    }

    /// One undo step for a numeric pivot drag. The first change snapshots.
    pub fn preview_bone_pivot(&mut self, index: usize, axis: usize, value: f32) {
        if axis > 2 || !value.is_finite() {
            return;
        }
        let Some(current) = self.skeleton.bones.get(index).map(|bone| bone.pivot[axis]) else {
            return;
        };
        if current == value {
            return;
        }
        self.checkpoint();
        self.skeleton.bones[index].pivot[axis] = value;
    }

    pub fn finish_bone_edit(&mut self) {
        self.commit();
    }

    pub fn fresh_bone_name(&self) -> String {
        let mut number = 1;
        loop {
            let name = if number == 1 {
                "Bone".to_string()
            } else {
                format!("Bone {number}")
            };
            if self.skeleton.index_of(&name).is_none() {
                return name;
            }
            number += 1;
        }
    }

    /// Centre of the active object's voxels, in world voxel coordinates.
    pub fn active_bone_pivot(&self) -> [f32; 3] {
        let object = self.active();
        let mut any = false;
        let mut min = [0; 3];
        let mut max = [0; 3];
        for (x, y, z) in object.cells.keys() {
            if !any {
                min = [*x, *y, *z];
                max = [*x, *y, *z];
                any = true;
            } else {
                min[0] = min[0].min(*x);
                min[1] = min[1].min(*y);
                min[2] = min[2].min(*z);
                max[0] = max[0].max(*x);
                max[1] = max[1].max(*y);
                max[2] = max[2].max(*z);
            }
        }
        if !any {
            return [
                object.translation.0 as f32,
                object.translation.1 as f32,
                object.translation.2 as f32,
            ];
        }
        [
            object.translation.0 as f32 + (min[0] + max[0] + 1) as f32 * 0.5,
            object.translation.1 as f32 + (min[1] + max[1] + 1) as f32 * 0.5,
            object.translation.2 as f32 + (min[2] + max[2] + 1) as f32 * 0.5,
        ]
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

    pub(super) fn focus_object(&mut self) {
        if self.objects.is_empty() {
            self.object_selection.clear();
            return;
        }
        self.selected = self.selected.min(self.objects.len() - 1);
        self.object_selection = vec![self.selected];
    }

    pub(super) fn choose_objects(&mut self, mut members: Vec<usize>, primary: usize) {
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

    pub(super) fn toggle_object(&mut self, index: usize) {
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

    pub(super) fn snapshot(&self) -> Snapshot {
        Snapshot {
            objects: self.objects.clone(),
            palette: self.palette,
            materials: self.materials,
            graph: self.graph.clone(),
            skeleton: self.skeleton.clone(),
        }
    }

    pub(super) fn restore(&mut self, snap: Snapshot) -> Snapshot {
        Snapshot {
            objects: std::mem::replace(&mut self.objects, snap.objects),
            palette: std::mem::replace(&mut self.palette, snap.palette),
            materials: std::mem::replace(&mut self.materials, snap.materials),
            graph: std::mem::replace(&mut self.graph, snap.graph),
            skeleton: std::mem::replace(&mut self.skeleton, snap.skeleton),
        }
    }

    pub(super) fn checkpoint(&mut self) {
        if self.pending.is_none() {
            self.pending = Some(self.snapshot());
        }
    }

    pub(super) fn commit(&mut self) {
        if let Some(prev) = self.pending.take() {
            if prev.objects != self.objects
                || prev.palette != self.palette
                || prev.materials != self.materials
                || prev.graph != self.graph
                || prev.skeleton != self.skeleton
            {
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

    pub(super) fn clamp_selection(&mut self) {
        if self.objects.is_empty() {
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
        }
        self.selected = self.selected.min(self.objects.len() - 1);
        if self
            .selected_bone
            .is_some_and(|index| index >= self.skeleton.bones.len())
        {
            self.selected_bone = None;
        }
        self.object_selection
            .retain(|index| *index < self.objects.len());
        if !self.object_selection.contains(&self.selected) {
            self.object_selection.push(self.selected);
        }
    }
}

fn check_object_name(name: &str) -> Result<String, String> {
    let name = name.trim();
    if name.is_empty() {
        return Err("name is empty".into());
    }
    if name.len() > 64 {
        return Err("name is too long".into());
    }
    Ok(name.to_string())
}
