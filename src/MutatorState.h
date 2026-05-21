#pragma once

#include "Mutators.h"

namespace macvoxel {

// Live state of the Mutator tool: which kind is active and its tuned
// params. The cursor AOE comes from `ToolSettings.brush_*` (Mutator
// shares the brush footprint controls so the user has one mental model
// for "tool radius").
struct MutatorState {
    mutators::Kind   active_kind = mutators::Kind::Foliage;
    mutators::Params params{};
};

}  // namespace macvoxel
