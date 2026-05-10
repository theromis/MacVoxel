#include "SelectionOps.h"

#include "CellKey.h"
#include "Document.h"
#include "EditHistory.h"
#include "FloatingBuffer.h"
#include "Selection.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <functional>
#include <unordered_map>
#include <vector>

namespace macvoxel {
namespace {

// Apply a per-cell coordinate mapping to the active selection: clear
// each source cell, write its palette to the mapped target cell, then
// commit the whole batch as one EditHistory op (with pre/post selection
// snapshots so undo / redo restore the marquee alongside the voxels).
//
// Two-pass clear-then-write so source / target overlap (rotation and
// flip routinely produce overlapping sets) keeps the right palette at
// the overlap cells: try_emplace traps the *original* pre-op value as
// each cell's rollback target, regardless of how many writes happen.
void ApplyMappingToSelection(
    Document& doc,
    const std::function<std::array<int32_t, 3>(int32_t, int32_t, int32_t)>& map)
{
    Selection& sel = CurrentSelection();
    if (!sel.active || sel.voxels.empty()) return;

    struct Source {
        int32_t x, y, z;
        uint8_t pal;
    };
    std::vector<Source> src;
    src.reserve(sel.voxels.size());
    for (const auto& v : sel.voxels) {
        const uint8_t pal = doc.grid.Get(v[0], v[1], v[2]);
        if (pal == 0) continue;  // selection went stale
        src.push_back({v[0], v[1], v[2], pal});
    }
    if (src.empty()) return;

    // changes: cell → original-value-before-this-op. Keys are packed
    // for the same O(1) dedupe the EditHistory uses internally.
    std::unordered_map<int64_t, uint8_t> changes;
    changes.reserve(src.size() * 2);
    auto touch = [&](int32_t x, int32_t y, int32_t z, uint8_t new_val) {
        const int64_t key = PackCellKey(x, y, z);
        changes.try_emplace(key, doc.grid.Get(x, y, z));
        doc.grid.Set(x, y, z, new_val);
    };
    for (const auto& s : src) touch(s.x, s.y, s.z, 0);
    for (const auto& s : src) {
        const auto t = map(s.x, s.y, s.z);
        touch(t[0], t[1], t[2], s.pal);
    }

    EditHistory& hist = CurrentHistory();
    hist.BeginOp();
    hist.RecordSelectionPre(sel);
    for (const auto& [key, orig] : changes) {
        int32_t x, y, z;
        UnpackCellKey(key, &x, &y, &z);
        const uint8_t now = doc.grid.Get(x, y, z);
        hist.Record(x, y, z, orig, now);
    }

    sel.voxels.clear();
    sel.voxels.reserve(src.size());
    int32_t bxmin = 0, bxmax = 0, bymin = 0, bymax = 0, bzmin = 0, bzmax = 0;
    bool any = false;
    for (const auto& s : src) {
        const auto t = map(s.x, s.y, s.z);
        sel.voxels.push_back({t[0], t[1], t[2]});
        if (!any) {
            bxmin = bxmax = t[0];
            bymin = bymax = t[1];
            bzmin = bzmax = t[2];
            any = true;
        } else {
            bxmin = std::min(bxmin, t[0]); bxmax = std::max(bxmax, t[0]);
            bymin = std::min(bymin, t[1]); bymax = std::max(bymax, t[1]);
            bzmin = std::min(bzmin, t[2]); bzmax = std::max(bzmax, t[2]);
        }
    }
    sel.box.min_x = bxmin; sel.box.max_x = bxmax;
    sel.box.min_y = bymin; sel.box.max_y = bymax;
    sel.box.min_z = bzmin; sel.box.max_z = bzmax;
    sel.active = true;

    hist.RecordSelectionPost(sel);
    hist.CommitOp();
    doc.BumpGeometry();
}

// Same two-pass clear-then-write applied directly to fb.grid (no
// document mutation, no EditHistory entry — mutations of the floating
// buffer don't go through history; the buffer is the user's transient
// staging area until commit). Version bump tells the renderer to
// rebuild its chunk-pool upload.
void ApplyMappingToFloatingBuffer(
    FloatingBuffer& fb,
    const std::function<std::array<int32_t, 3>(int32_t, int32_t, int32_t)>& map)
{
    if (!fb.active || fb.grid.empty()) return;

    struct Source { int32_t x, y, z; uint8_t pal; };
    std::vector<Source> src;
    src.reserve(static_cast<size_t>(fb.grid.FilledCount()));
    constexpr uint32_t kCS = VoxelGrid::kChunkSize;
    for (const auto& [coord, chunk] : fb.grid.chunks()) {
        if (chunk->filled_count == 0) continue;
        const int32_t base_x = coord.x * static_cast<int32_t>(kCS);
        const int32_t base_y = coord.y * static_cast<int32_t>(kCS);
        const int32_t base_z = coord.z * static_cast<int32_t>(kCS);
        for (uint32_t lz = 0; lz < kCS; ++lz)
        for (uint32_t ly = 0; ly < kCS; ++ly)
        for (uint32_t lx = 0; lx < kCS; ++lx) {
            const size_t idx = lx + ly * kCS + lz * kCS * kCS;
            const uint8_t pal = chunk->cells[idx];
            if (pal == 0) continue;
            src.push_back({base_x + static_cast<int32_t>(lx),
                           base_y + static_cast<int32_t>(ly),
                           base_z + static_cast<int32_t>(lz), pal});
        }
    }
    if (src.empty()) return;

    fb.grid.Clear();
    for (const auto& s : src) {
        const auto t = map(s.x, s.y, s.z);
        fb.grid.Set(t[0], t[1], t[2], s.pal);
    }
    ++fb.version;
}

}  // namespace

void RotateSelection(Document& doc, Axis axis, bool cw) {
    FloatingBuffer& fb = CurrentFloatingBuffer();
    const bool floating = fb.active && !fb.grid.empty();
    if (!floating) {
        const Selection& sel = CurrentSelection();
        if (!sel.active || sel.voxels.empty()) return;
    }

    // Pivot at the AABB's continuous center. The voxel cell at (cx, cy, cz)
    // covers [cx, cx+1] in each axis, so the box center sits at
    // (xmin + xmax + 1) / 2 — possibly half-integer, which is fine: cell
    // centers (c + 0.5) sit on the same half-step lattice and 90° rotation
    // round-trips them to integer cell coords (modulo lattice parity).
    const Bounds3 b = floating ? fb.grid.Bounds() : CurrentSelection().box;
    const float px = (b.min_x + b.max_x + 1) * 0.5f;
    const float py = (b.min_y + b.max_y + 1) * 0.5f;
    const float pz = (b.min_z + b.max_z + 1) * 0.5f;

    auto map = [=](int32_t cx, int32_t cy, int32_t cz)
            -> std::array<int32_t, 3>
    {
        const float fx = static_cast<float>(cx) + 0.5f;
        const float fy = static_cast<float>(cy) + 0.5f;
        const float fz = static_cast<float>(cz) + 0.5f;
        const float rx = fx - px, ry = fy - py, rz = fz - pz;
        float nx = rx, ny = ry, nz = rz;
        // 90° rotations around each axis. CCW is the "viewed from +axis,
        // counter-clockwise" sense; CW is the opposite.
        switch (axis) {
            case Axis::X:
                ny = cw ?  rz : -rz;
                nz = cw ? -ry :  ry;
                break;
            case Axis::Y:
                nx = cw ? -rz :  rz;
                nz = cw ?  rx : -rx;
                break;
            case Axis::Z:
                nx = cw ?  ry : -ry;
                ny = cw ? -rx :  rx;
                break;
        }
        return {
            static_cast<int32_t>(std::lround(px + nx - 0.5f)),
            static_cast<int32_t>(std::lround(py + ny - 0.5f)),
            static_cast<int32_t>(std::lround(pz + nz - 0.5f)),
        };
    };
    if (floating) ApplyMappingToFloatingBuffer(fb, map);
    else ApplyMappingToSelection(doc, map);
}

void FlipSelection(Document& doc, Axis axis) {
    FloatingBuffer& fb = CurrentFloatingBuffer();
    const bool floating = fb.active && !fb.grid.empty();
    if (!floating) {
        const Selection& sel = CurrentSelection();
        if (!sel.active || sel.voxels.empty()) return;
    }

    // Cell-coord mirror through the AABB center. For x, the mirror plane
    // sits at x = (xmin + xmax + 1) / 2, which sends a cell at cx to
    // (xmin + xmax) - cx — an exact integer regardless of dimension parity.
    const Bounds3 b = floating ? fb.grid.Bounds() : CurrentSelection().box;
    const int32_t sx = b.min_x + b.max_x;
    const int32_t sy = b.min_y + b.max_y;
    const int32_t sz = b.min_z + b.max_z;

    auto map = [=](int32_t cx, int32_t cy, int32_t cz)
            -> std::array<int32_t, 3>
    {
        switch (axis) {
            case Axis::X: return {sx - cx, cy, cz};
            case Axis::Y: return {cx, sy - cy, cz};
            case Axis::Z: return {cx, cy, sz - cz};
        }
        return {cx, cy, cz};
    };
    if (floating) ApplyMappingToFloatingBuffer(fb, map);
    else ApplyMappingToSelection(doc, map);
}

}  // namespace macvoxel
