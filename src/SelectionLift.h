#pragma once

#include "VoxelGrid.h"  // Bounds3

#include <array>
#include <cstdint>
#include <vector>

namespace macvoxel {

struct EditorContext;

enum class Axis;  // forward — defined in SelectionOps.h

// Pure-C++ façade for the selection-lift pipeline. Wraps the
// EditEngine GPU calls with CPU-side updates to Document (grid +
// shadow), Selection, and EditHistory.
//
// Lifecycle: a selection's contents are lifted into `tex_lift` at
// finalize time, mutated by translate / rotate / flip while the user
// drags or hits keys, and committed back into `tex_a` on deselect /
// save / Esc. Cancel-while-lifted restores the doc from
// `pre_lift_originals` recorded at lift time.
namespace lift {

// Selection finalize: read all non-zero cells in `box` from the
// doc shadow, store as Selection::pre_lift_originals, zero those
// cells in doc.grid + doc.volume_shadow, dispatch the lift kernel on
// the GPU. Sel becomes lift_active with `bounds_ = box-tight`.
void LiftSelection(EditorContext& ctx, const Bounds3& box);

// Selection finalize from a CPU cell list (flood / palette).
void LiftSelectionCells(EditorContext& ctx,
                         const std::vector<std::array<int32_t, 3>>& cells);

// Translate the lift by `delta` (world cells). Updates lift_bounds.
void TranslateLift(EditorContext& ctx, int32_t dx, int32_t dy, int32_t dz);

// Rotate / flip — Magica-form. Computes the dst bbox (centered on
// src, shifted to fit in the volume), sets up the transform params,
// and updates lift_bounds.
void RotateLift(EditorContext& ctx, Axis axis, bool cw);
void FlipLift(EditorContext& ctx, Axis axis);

// Commit lift contents into doc. Reads tex_lift back over
// lift_bounds, builds the (pre_lift_originals → committed cells)
// diff, applies via doc.SetCell, pushes one EditOp. Sel returns to
// inactive.
void CommitLift(EditorContext& ctx);

// Restore the doc from pre_lift_originals; zero tex_lift on the GPU.
// No EditHistory entry — the lift never produced one. Sel returns
// to inactive.
void CancelLift(EditorContext& ctx);

// Delete the active lift: drop tex_lift contents without restoring
// the doc; push one EditOp recording each pre_lift_originals entry
// as a deletion. Sel returns to inactive.
void DeleteLift(EditorContext& ctx);

}  // namespace lift

}  // namespace macvoxel
