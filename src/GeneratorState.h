#pragma once

#include "Generators.h"

namespace macvoxel {

// Live state of the Generators panel: which kind is the user currently
// configuring, and what parameters have they dialed in. The actual
// volume (Bounds3i) lives elsewhere — it's set by the viewport's
// gizmo, not by this panel.
struct GeneratorState {
    generators::Kind active_kind = generators::Kind::Ellipsoid;
    generators::Params params{};
};

}  // namespace macvoxel
