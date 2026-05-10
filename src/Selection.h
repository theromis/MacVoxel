#pragma once

#include "VoxelGrid.h"

#include <array>
#include <cstdint>
#include <optional>
#include <unordered_set>
#include <vector>

namespace macvoxel {

// One voxel-space selection. Sparse-first: the canonical state is a
// list of selected cell coordinates; the AABB is a derived cache,
// recomputed whenever the cell list changes.
//
// Two ways the selection's voxel list gets populated:
//   - Materialized sources (Marquee mouseUp, Box-select mouseUp,
//     Flood, palette "Select voxels by color"): caller hands a
//     vector to SetVoxels; bounds are recomputed.
//   - Box-select mid-drag: only the AABB is known; the cells inside
//     haven't been scanned yet. SetBox stores that AABB and leaves
//     `voxels()` empty until mouseUp materializes it.
//
// Selection-aware operations (copy / cut / delete / paint / move /
// transform) iterate `voxels()`. The bounds are used for clipboard
// origin / extent and for AABB outlines in the renderer.
//
// Membership queries — "is cell (x, y, z) selected?" — go through
// Contains, which builds a hash set the first time it's asked and
// reuses it until the next mutation. Cheap for one-off checks, fast
// for the interactive case where many cells are queried in a frame.
class Selection {
public:
    Selection() = default;
    Selection(const Selection& other);
    Selection(Selection&& other) noexcept;
    Selection& operator=(const Selection& other);
    Selection& operator=(Selection&& other) noexcept;

    bool active() const { return active_; }
    bool empty() const { return voxels_.empty(); }
    size_t size() const { return voxels_.size(); }
    const Bounds3& bounds() const { return bounds_; }
    const std::vector<std::array<int32_t, 3>>& voxels() const {
        return voxels_;
    }

    // O(1) amortized membership. First call after a mutation builds
    // a hash set over `voxels_`; subsequent calls hit the cache.
    bool Contains(int32_t x, int32_t y, int32_t z) const;

    // Replace the selection with a sparse cell list. Computes the
    // tight AABB and marks the selection active iff `voxels` is
    // non-empty. Membership cache is invalidated.
    void SetVoxels(std::vector<std::array<int32_t, 3>> voxels);

    // Set just the AABB (for tools that preview the selection as a
    // box before materializing cells — Box-select mid-drag, eventually
    // Marquee). Leaves the voxel list empty; selection is active.
    void SetBox(const Bounds3& box);

    // Append a single cell. Bounds expand to include it. Used by tools
    // that build the selection one cell at a time (live Marquee
    // accumulation, eventually shift-click extension).
    void AddVoxel(int32_t x, int32_t y, int32_t z);

    void Clear();

private:
    Bounds3 bounds_{};
    std::vector<std::array<int32_t, 3>> voxels_;
    bool active_ = false;
    // Lazy O(1) membership. Built on first Contains() after a
    // mutation; mutators reset() to invalidate.
    mutable std::optional<std::unordered_set<int64_t>> membership_;

    void RecomputeBounds();
};

Selection& CurrentSelection();

}  // namespace macvoxel
