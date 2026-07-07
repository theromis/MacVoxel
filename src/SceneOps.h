#pragma once

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

// Unlink the selected object (nodes stay resident for undo; the writer
// GCs unreachable models at save). Deleting the active object switches
// to a survivor first — both land in ONE op. False when it's the last
// object or the selection is invalid.
bool DeleteObject(EditorContext& ctx);

// Selected object → the whole-object clipboard.
bool CopyObject(EditorContext& ctx);

// Clipboard → a new object under the root group at its copied world
// transform (nudged +8x when an object already sits at that exact
// translation). Returns the new object index or -1.
int PasteObject(EditorContext& ctx);

}  // namespace scene_ops
}  // namespace macvoxel
