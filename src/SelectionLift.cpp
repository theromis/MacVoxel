#include "SelectionLift.h"

#include "CellKey.h"
#include "Document.h"
#include "EditEngine.h"
#include "EditHistory.h"
#include "EditorContext.h"
#include "LiftEngine.h"
#include "Selection.h"
#include "SelectionOps.h"
#include "VoxelGrid.h"
#include "VoxelVolume.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <unordered_map>
#include <vector>

namespace macvoxel {
namespace lift {

namespace {

void RotationMatrix(Axis axis, bool cw, int32_t M[9]) {
    for (int i = 0; i < 9; ++i) M[i] = (i == 0 || i == 4 || i == 8) ? 1 : 0;
    switch (axis) {
        case Axis::X:
            M[4] = 0; M[5] = cw ?  1 : -1;
            M[7] = cw ? -1 :  1; M[8] = 0;
            break;
        case Axis::Y:
            M[0] = 0; M[2] = cw ? -1 :  1;
            M[6] = cw ?  1 : -1; M[8] = 0;
            break;
        case Axis::Z:
            M[0] = 0; M[1] = cw ?  1 : -1;
            M[3] = cw ? -1 :  1; M[4] = 0;
            break;
    }
}

void MirrorMatrix(Axis axis, int32_t M[9]) {
    for (int i = 0; i < 9; ++i) M[i] = (i == 0 || i == 4 || i == 8) ? 1 : 0;
    switch (axis) {
        case Axis::X: M[0] = -1; break;
        case Axis::Y: M[4] = -1; break;
        case Axis::Z: M[8] = -1; break;
    }
}

// Inverse 3x3 for the axis-aligned rotation / mirror set. Rotation
// matrices are orthogonal (M^-1 = M^T); mirror matrices are self-
// inverse.
void InverseMatrix(const int32_t M[9], int32_t Minv[9]) {
    const bool self_inverse =
        M[1] == M[3] && M[2] == M[6] && M[5] == M[7];
    if (self_inverse) {
        for (int i = 0; i < 9; ++i) Minv[i] = M[i];
    } else {
        Minv[0] = M[0]; Minv[1] = M[3]; Minv[2] = M[6];
        Minv[3] = M[1]; Minv[4] = M[4]; Minv[5] = M[7];
        Minv[6] = M[2]; Minv[7] = M[5]; Minv[8] = M[8];
    }
}

// Configure params for the lift-transform kernel. Builds the inv_map,
// src/dst centers, and a centered-then-volume-clamped dst bbox.
LiftTransformParams BuildTransformParams(const int32_t Mfwd[9],
                                          const Bounds3& src_bbox,
                                          const EditVolume& vol) {
    const int32_t sdx = src_bbox.max_x - src_bbox.min_x + 1;
    const int32_t sdy = src_bbox.max_y - src_bbox.min_y + 1;
    const int32_t sdz = src_bbox.max_z - src_bbox.min_z + 1;

    auto dst_dim_axis = [&](int row) -> int32_t {
        for (int col = 0; col < 3; ++col) {
            if (Mfwd[row * 3 + col] != 0) {
                if (col == 0) return sdx;
                if (col == 1) return sdy;
                return sdz;
            }
        }
        return 0;
    };
    const int32_t ddx = dst_dim_axis(0);
    const int32_t ddy = dst_dim_axis(1);
    const int32_t ddz = dst_dim_axis(2);

    auto place = [](int32_t src_min, int32_t s_dim, int32_t d_dim,
                    int32_t vlo, int32_t vhi) -> int32_t {
        int32_t v = src_min +
                    static_cast<int32_t>(std::lround((s_dim - d_dim) * 0.5f));
        if (v < vlo) v = vlo;
        if (v + d_dim - 1 > vhi) v = vhi - d_dim + 1;
        return v;
    };
    const int32_t dst_min_x = place(src_bbox.min_x, sdx, ddx, vol.x0, vol.x1);
    const int32_t dst_min_y = place(src_bbox.min_y, sdy, ddy, vol.y0, vol.y1);
    const int32_t dst_min_z = place(src_bbox.min_z, sdz, ddz, vol.z0, vol.z1);

    LiftTransformParams params{};
    params.dst_x0 = dst_min_x;
    params.dst_y0 = dst_min_y;
    params.dst_z0 = dst_min_z;
    params.dst_x1 = dst_min_x + ddx - 1;
    params.dst_y1 = dst_min_y + ddy - 1;
    params.dst_z1 = dst_min_z + ddz - 1;
    int32_t Minv[9];
    InverseMatrix(Mfwd, Minv);
    for (int i = 0; i < 9; ++i) params.inv_map[i] = Minv[i];
    params.src_center[0] = src_bbox.min_x + sdx * 0.5f;
    params.src_center[1] = src_bbox.min_y + sdy * 0.5f;
    params.src_center[2] = src_bbox.min_z + sdz * 0.5f;
    params.dst_center[0] = dst_min_x + ddx * 0.5f;
    params.dst_center[1] = dst_min_y + ddy * 0.5f;
    params.dst_center[2] = dst_min_z + ddz * 0.5f;
    return params;
}

// Build the lift's tight bbox from a CellChange[] of originals (used
// by LiftSelection / LiftSelectionCells). Returns empty if `cells` is
// empty.
Bounds3 TightBoundsOf(const std::vector<CellChange>& cells) {
    Bounds3 b{};
    if (cells.empty()) return b;
    b.min_x = b.max_x = cells[0].x;
    b.min_y = b.max_y = cells[0].y;
    b.min_z = b.max_z = cells[0].z;
    for (size_t i = 1; i < cells.size(); ++i) {
        b.min_x = std::min(b.min_x, cells[i].x);
        b.max_x = std::max(b.max_x, cells[i].x);
        b.min_y = std::min(b.min_y, cells[i].y);
        b.max_y = std::max(b.max_y, cells[i].y);
        b.min_z = std::min(b.min_z, cells[i].z);
        b.max_z = std::max(b.max_z, cells[i].z);
    }
    return b;
}

}  // namespace

void LiftSelection(EditorContext& ctx, const Bounds3& box) {
    if (ctx.engine == nullptr) return;
    if (box.empty()) return;
    Document& doc = ctx.document;
    Selection& sel = ctx.selection;
    if (sel.lift_active()) return;  // caller must commit/cancel first

    // Clip box to volume — selections outside the canvas can't lift.
    Bounds3 clipped = box;
    clipped.min_x = std::max(clipped.min_x, doc.volume.x0);
    clipped.min_y = std::max(clipped.min_y, doc.volume.y0);
    clipped.min_z = std::max(clipped.min_z, doc.volume.z0);
    clipped.max_x = std::min(clipped.max_x, doc.volume.x1);
    clipped.max_y = std::min(clipped.max_y, doc.volume.y1);
    clipped.max_z = std::min(clipped.max_z, doc.volume.z1);
    if (clipped.empty()) return;

    // Scan CPU shadow for non-zero cells in the box; build the
    // pre_lift_originals list and zero those cells in the doc.
    std::vector<CellChange> originals;
    originals.reserve(64);
    for (int32_t z = clipped.min_z; z <= clipped.max_z; ++z)
    for (int32_t y = clipped.min_y; y <= clipped.max_y; ++y)
    for (int32_t x = clipped.min_x; x <= clipped.max_x; ++x) {
        const uint8_t pal = doc.volume_shadow.Get(x, y, z);
        if (pal == 0) continue;
        CellChange c{};
        c.x = x; c.y = y; c.z = z;
        c.old_val = pal;
        c.new_val = 0;
        originals.push_back(c);
        doc.SetCell(x, y, z, 0);
    }
    if (originals.empty()) {
        // No cells to lift — selection becomes inactive.
        sel.Clear();
        return;
    }

    // Dispatch GPU lift (kernel mirrors what we did to the shadow).
    ctx.engine->LiftBox(clipped);
    // Drain shadow dirty bits — the kernel already updated tex_a, so
    // syncFromVolume should not re-upload these chunks.
    ctx.engine->RefreshDocOracle(doc.volume_shadow);

    Bounds3 tight = TightBoundsOf(originals);
    sel.SetLift(tight, std::move(originals));
    doc.BumpGeometry();
}

void LiftSelectionCells(EditorContext& ctx,
                         const std::vector<std::array<int32_t, 3>>& cells) {
    if (ctx.engine == nullptr) return;
    if (cells.empty()) return;
    Document& doc = ctx.document;
    Selection& sel = ctx.selection;
    if (sel.lift_active()) return;

    std::vector<CellChange> originals;
    std::vector<int32_t> kept_cells;
    originals.reserve(cells.size());
    kept_cells.reserve(cells.size() * 3);
    for (const auto& c : cells) {
        const int32_t x = c[0], y = c[1], z = c[2];
        if (!doc.volume.Contains(x, y, z)) continue;
        const uint8_t pal = doc.volume_shadow.Get(x, y, z);
        if (pal == 0) continue;
        CellChange cc{};
        cc.x = x; cc.y = y; cc.z = z;
        cc.old_val = pal;
        cc.new_val = 0;
        originals.push_back(cc);
        kept_cells.push_back(x);
        kept_cells.push_back(y);
        kept_cells.push_back(z);
        doc.SetCell(x, y, z, 0);
    }
    if (originals.empty()) {
        sel.Clear();
        return;
    }

    ctx.engine->LiftCells(kept_cells.data(), originals.size());
    ctx.engine->RefreshDocOracle(doc.volume_shadow);

    Bounds3 tight = TightBoundsOf(originals);
    sel.SetLift(tight, std::move(originals));
    doc.BumpGeometry();
}

void TranslateLift(EditorContext& ctx, int32_t dx, int32_t dy, int32_t dz) {
    if (ctx.engine == nullptr) return;
    Selection& sel = ctx.selection;
    if (!sel.lift_active()) return;
    if (dx == 0 && dy == 0 && dz == 0) return;

    const Bounds3 old_b = sel.bounds();
    Bounds3 new_b = old_b;
    new_b.min_x += dx; new_b.max_x += dx;
    new_b.min_y += dy; new_b.max_y += dy;
    new_b.min_z += dz; new_b.max_z += dz;
    int32_t off[3] = {dx, dy, dz};
    ctx.engine->TranslateLift(old_b, new_b, off);
    sel.UpdateLiftBounds(new_b);
    ctx.document.BumpGeometry();
}

void RotateLift(EditorContext& ctx, Axis axis, bool cw) {
    if (ctx.engine == nullptr) return;
    Selection& sel = ctx.selection;
    if (!sel.lift_active()) return;
    const Bounds3 old_b = sel.bounds();
    int32_t M[9];
    RotationMatrix(axis, cw, M);
    LiftTransformParams params =
        BuildTransformParams(M, old_b, ctx.document.volume);
    ctx.engine->TransformLift(params, old_b);
    Bounds3 new_b{params.dst_x0, params.dst_y0, params.dst_z0,
                  params.dst_x1, params.dst_y1, params.dst_z1};
    sel.UpdateLiftBounds(new_b);
    ctx.document.BumpGeometry();
}

void FlipLift(EditorContext& ctx, Axis axis) {
    if (ctx.engine == nullptr) return;
    Selection& sel = ctx.selection;
    if (!sel.lift_active()) return;
    const Bounds3 old_b = sel.bounds();
    int32_t M[9];
    MirrorMatrix(axis, M);
    LiftTransformParams params =
        BuildTransformParams(M, old_b, ctx.document.volume);
    ctx.engine->TransformLift(params, old_b);
    Bounds3 new_b{params.dst_x0, params.dst_y0, params.dst_z0,
                  params.dst_x1, params.dst_y1, params.dst_z1};
    sel.UpdateLiftBounds(new_b);
    ctx.document.BumpGeometry();
}

void CommitLift(EditorContext& ctx) {
    if (ctx.engine == nullptr) return;
    Selection& sel = ctx.selection;
    if (!sel.lift_active()) return;
    Document& doc = ctx.document;
    EditHistory& hist = ctx.history;

    const Bounds3 lift_b = sel.bounds();
    if (lift_b.empty()) {
        sel.ClearLift();
        return;
    }

    // Read lift contents over current lift bbox + dispatch the commit
    // kernel (kernel writes tex_a, zeroes tex_lift).
    std::vector<uint8_t> lift_bytes;
    ctx.engine->CommitLift(lift_b, &lift_bytes);

    // Build the diff: pre_lift_originals → committed state.
    //   - source cells (in pre_lift_originals): old = pre_pal, new = 0
    //     OR (overridden below) lift_val if a lifted cell ended up at
    //     the original position.
    //   - target cells (where lift_bytes != 0): old = pre_pal if also
    //     in originals, else current shadow value; new = lift_val.
    //   - Result feeds doc.SetCell + history.
    struct Delta { uint8_t old_val; uint8_t new_val; bool set_old; };
    std::unordered_map<int64_t, Delta> changes;
    changes.reserve(sel.pre_lift_originals().size() * 2 + 256);

    for (const auto& orig : sel.pre_lift_originals()) {
        const int64_t k = PackCellKey(orig.x, orig.y, orig.z);
        changes[k] = {orig.old_val, 0, true};
    }

    // Clip the readback bbox to the volume so x-fastest indexing
    // matches the bytes layout the engine returned.
    Bounds3 read_b = lift_b;
    read_b.min_x = std::max(read_b.min_x, doc.volume.x0);
    read_b.min_y = std::max(read_b.min_y, doc.volume.y0);
    read_b.min_z = std::max(read_b.min_z, doc.volume.z0);
    read_b.max_x = std::min(read_b.max_x, doc.volume.x1);
    read_b.max_y = std::min(read_b.max_y, doc.volume.y1);
    read_b.max_z = std::min(read_b.max_z, doc.volume.z1);
    if (!read_b.empty()) {
        const size_t bw = (size_t)read_b.size_x();
        const size_t bh = (size_t)read_b.size_y();
        const size_t bd = (size_t)read_b.size_z();
        const size_t expected = bw * bh * bd;
        if (lift_bytes.size() >= expected) {
            for (size_t z = 0; z < bd; ++z)
            for (size_t y = 0; y < bh; ++y) {
                const size_t row = (z * bh + y) * bw;
                for (size_t x = 0; x < bw; ++x) {
                    const uint8_t v = lift_bytes[row + x];
                    if (v == 0) continue;
                    const int32_t wx = read_b.min_x + (int32_t)x;
                    const int32_t wy = read_b.min_y + (int32_t)y;
                    const int32_t wz = read_b.min_z + (int32_t)z;
                    const int64_t k = PackCellKey(wx, wy, wz);
                    auto it = changes.find(k);
                    if (it != changes.end()) {
                        it->second.new_val = v;
                    } else {
                        changes[k] = {doc.volume_shadow.Get(wx, wy, wz), v, true};
                    }
                }
            }
        }
    }

    hist.BeginOp();
    // Deliberately NOT recording pre/post selection — restoring the
    // lifted Selection on undo would re-instate sel.lift_active=true
    // pointing at an empty tex_lift. The next auto-commit then runs a
    // "lift contents are empty" diff against the original positions,
    // zeroing them out a second time. Leaving the selection slot blank
    // means undo touches the doc only; sel stays whatever it is now
    // (cleared by the click that triggered the commit).

    for (const auto& [k, d] : changes) {
        int32_t x, y, z;
        UnpackCellKey(k, &x, &y, &z);
        if (doc.grid.Get(x, y, z) != d.new_val) {
            doc.SetCell(x, y, z, d.new_val);
        }
        if (d.old_val != d.new_val) {
            hist.Record(x, y, z, d.old_val, d.new_val);
        }
    }
    ctx.engine->RefreshDocOracle(doc.volume_shadow);

    sel.ClearLift();
    hist.CommitOp();
    doc.BumpGeometry();
}

void DeleteLift(EditorContext& ctx) {
    if (ctx.engine == nullptr) return;
    Selection& sel = ctx.selection;
    if (!sel.lift_active()) return;
    Document& doc = ctx.document;
    EditHistory& hist = ctx.history;

    // tex_a is already 0 at the pre_lift_originals positions (lift
    // cleared them when it was created). Push one EditOp recording
    // each as a delete (pre_pal → 0). Drop tex_lift on the GPU.
    // No selection snapshot — see CommitLift for why restoring a
    // lifted Selection on undo causes a phantom-lift double-commit.
    hist.BeginOp();
    for (const auto& orig : sel.pre_lift_originals()) {
        hist.Record(orig.x, orig.y, orig.z, orig.old_val, 0);
    }
    ctx.engine->ClearLift(sel.bounds());
    sel.ClearLift();
    hist.CommitOp();
    doc.BumpGeometry();
}

void CancelLift(EditorContext& ctx) {
    if (ctx.engine == nullptr) return;
    Selection& sel = ctx.selection;
    if (!sel.lift_active()) return;
    Document& doc = ctx.document;

    for (const auto& orig : sel.pre_lift_originals()) {
        doc.SetCell(orig.x, orig.y, orig.z, orig.old_val);
    }
    ctx.engine->ClearLift(sel.bounds());
    sel.ClearLift();
    doc.BumpGeometry();
}

}  // namespace lift
}  // namespace macvoxel
