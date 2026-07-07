#pragma once

#include <cstdint>

namespace macvoxel {

// Top-level editing mode, MagicaVoxel-style: Model mode edits voxels
// inside the active object (everything the tool system does today);
// Scene mode ("object mode") selects and transforms whole objects.
// Toggled with Tab.
enum class EditorMode : uint8_t {
    Model = 0,
    Scene = 1,
};

}  // namespace macvoxel
