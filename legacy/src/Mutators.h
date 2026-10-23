#pragma once

#include <cstdint>

namespace macvoxel::mutators {

// What rule a Mutator runs. Each kind is a separate MSL compute kernel,
// hardcoded — the kind selects a PSO, params tune knobs the kernel
// already knows about. New kinds = new kernel + new entry in the
// MutatorEngine's pipeline table.
enum class Kind : uint32_t {
    Foliage = 0,
    Count_,
};

// Foliage rule: for every empty cell in the cursor AOE, if any face-
// neighbor reads `seed_color` (in the live-composited view of tex_a +
// tex_t + preview_rem), roll hash3(cell, stroke_id); if the roll
// passes `density`, write `seed_color` into tex_t. Repeat passes thicken
// the bush — a fresh stroke_id changes the roll for every cell.
struct FoliageParams {
    uint8_t seed_color = 1;
    float   density    = 0.30f;
};

// Single bag every kind reads from. v1 holds only FoliageParams; future
// kinds add their own fields here (kernels just ignore what they don't
// need, same Generator convention).
struct Params {
    FoliageParams foliage{};
};

}  // namespace macvoxel::mutators
