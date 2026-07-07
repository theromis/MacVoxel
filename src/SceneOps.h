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

}  // namespace scene_ops
}  // namespace macvoxel
