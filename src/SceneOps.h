#pragma once

#include "VoxScene.h"

#include <cstdint>

namespace macvoxel {

struct EditorContext;

namespace scene_ops {

// Single authority for switching the active object (Tab-return,
// outliner activation, delete-of-active, undo/redo of a switch).
// Preconditions the caller enforces where GPU state exists: lift
// committed, generator gizmo resolved, no drag in flight.
// Sequence: fold outgoing grid → model (no-op when already synced),
// switch index, rebake incoming (recenters the edit volume), clear the
// voxel selection, bump the scene version.
void ActivateObject(EditorContext& ctx, int32_t index);

// Deep-copy the selected object (new model slot + new leaf nTRN/nSHP
// beside the original, name + " copy"), select the copy, record
// AddObject. Returns the new object index or -1.
int DuplicateObject(EditorContext& ctx);

// Append a new empty 40³ object under the root group, resting on the
// floor at the origin (+8x nudge when an object already sits at that
// exact translation), and select it. Returns the new index or -1.
int NewEmptyObject(EditorContext& ctx);

// Unlink the selected object (nodes stay resident for undo; the writer
// GCs unreachable models at save). Deleting the active object switches
// to a survivor first — both land in ONE op. False when it's the last
// object or the selection is invalid.
bool DeleteObject(EditorContext& ctx);

// The object the size fields address: the scene-mode selection when
// one exists, else the active object (so the fields work in Model
// mode too). -1 when neither is a resizable leaf.
int ResizeTargetObject(const EditorContext& ctx);

// True when ResizeTargetObject finds a target.
bool CanResizeSelectedObject(const EditorContext& ctx);

// Resize the selected object's dims box (clamped 1..256 per axis;
// `new_dims` are MODEL-LOCAL — map user input through
// DimsFromWorldExtents first). Local voxel coords stay fixed — content
// anchors at the local min corner, so world growth runs toward the
// +axes — and the leaf translation re-solves so surviving voxels never
// move in world space. Voxels outside the new box are clipped; one
// undo restores size and cells together.
bool ResizeSelectedObject(EditorContext& ctx, Vec3i32 new_dims);

// Selected object → the whole-object clipboard.
bool CopyObject(EditorContext& ctx);

// Clipboard → a new object under the root group at its copied world
// transform (nudged +8x when an object already sits at that exact
// translation). Returns the new object index or -1.
int PasteObject(EditorContext& ctx);

}  // namespace scene_ops
}  // namespace macvoxel
