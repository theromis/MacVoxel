#include "FloatingBufferOps.h"

#include "CellKey.h"
#include "Clipboard.h"
#include "Document.h"
#include "EditHistory.h"
#include "FloatingBuffer.h"
#include "Selection.h"

#include <algorithm>
#include <unordered_map>
#include <vector>

namespace macvoxel {

void LiftSelectionToFloating(Document& doc) {
    Selection& sel = CurrentSelection();
    if (!sel.active || sel.voxels.empty()) return;
    FloatingBuffer& fb = CurrentFloatingBuffer();
    if (fb.active) return;  // caller must commit / discard first

    // Snapshot palettes BEFORE touching the doc grid (a stale selection
    // list could in theory have duplicates; two-pass is the safe form).
    struct Pickup { int32_t x, y, z; uint8_t pal; };
    std::vector<Pickup> picked;
    picked.reserve(sel.voxels.size());
    for (const auto& v : sel.voxels) {
        const uint8_t pal = doc.grid.Get(v[0], v[1], v[2]);
        if (pal == 0) continue;  // selection went stale
        picked.push_back({v[0], v[1], v[2], pal});
    }
    if (picked.empty()) return;

    // Stash the pre-lift state on the buffer so commit can fold the
    // entire move into one EditOp (and undo-while-floating can put
    // cells back without involving history).
    fb.source_originals.clear();
    fb.source_originals.reserve(picked.size());
    fb.pre_lift_sel = sel;

    fb.grid.Clear();
    for (const auto& p : picked) {
        fb.grid.Set(p.x, p.y, p.z, p.pal);
        doc.grid.Set(p.x, p.y, p.z, 0);
        fb.source_originals.push_back({{p.x, p.y, p.z}, p.pal});
    }
    fb.offset_x = fb.offset_y = fb.offset_z = 0;
    fb.active = true;
    fb.originated_from_lift = true;
    ++fb.version;
    ++doc.version;
}

void CommitFloatingBuffer(Document& doc) {
    FloatingBuffer& fb = CurrentFloatingBuffer();
    if (!fb.active) return;

    // Build the pre-lift → post-commit delta as a single EditOp.
    //
    // For lift-style buffers, fb.source_originals holds the cells we
    // cleared from the doc plus their palette, and the doc currently
    // has those cells at 0. For paste-style buffers, source_originals
    // is empty and the doc still has its pre-paste state intact.
    //
    // Targets are the buffer cells re-stamped at fb.offset. For each
    // touched cell we need (old, new):
    //   • Sources cleared but never re-targeted: (orig_palette, 0)
    //   • Targets that aren't sources:           (doc_now, target_pal)
    //   • Cells that are both:                   (orig_palette, target_pal)
    // doc_now equals the pre-lift value at that coord because lift
    // only touched the source coords (which we've already mapped via
    // source_originals).
    struct Delta { uint8_t old_val; uint8_t new_val; };
    std::unordered_map<int64_t, Delta> changes;
    changes.reserve(fb.source_originals.size() * 2 +
                    static_cast<size_t>(fb.grid.FilledCount()));

    for (const auto& [c, pal] : fb.source_originals) {
        const int64_t key = PackCellKey(c[0], c[1], c[2]);
        changes[key] = {pal, 0};
    }

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
            const int32_t tx = base_x + static_cast<int32_t>(lx) + fb.offset_x;
            const int32_t ty = base_y + static_cast<int32_t>(ly) + fb.offset_y;
            const int32_t tz = base_z + static_cast<int32_t>(lz) + fb.offset_z;
            const int64_t key = PackCellKey(tx, ty, tz);
            auto it = changes.find(key);
            if (it != changes.end()) {
                it->second.new_val = pal;
            } else {
                changes[key] = {doc.grid.Get(tx, ty, tz), pal};
            }
        }
    }

    // Apply to doc and emit one EditOp.
    EditHistory& hist = CurrentHistory();
    Selection& sel = CurrentSelection();
    hist.BeginOp();
    if (fb.originated_from_lift) {
        hist.RecordSelectionPre(fb.pre_lift_sel);
    } else {
        hist.RecordSelectionPre(sel);
    }
    for (const auto& [key, d] : changes) {
        if (d.old_val == d.new_val) continue;
        int32_t x, y, z;
        UnpackCellKey(key, &x, &y, &z);
        if (doc.grid.Get(x, y, z) != d.new_val) {
            doc.grid.Set(x, y, z, d.new_val);
        }
        hist.Record(x, y, z, d.old_val, d.new_val);
    }

    // Selection becomes the dropped cells (every entry in `changes`
    // whose new_val is non-zero).
    std::vector<std::array<int32_t, 3>> dropped;
    int32_t bxmin = 0, bxmax = 0, bymin = 0, bymax = 0, bzmin = 0, bzmax = 0;
    bool any = false;
    dropped.reserve(changes.size());
    for (const auto& [key, d] : changes) {
        if (d.new_val == 0) continue;
        int32_t x, y, z;
        UnpackCellKey(key, &x, &y, &z);
        dropped.push_back({x, y, z});
        if (!any) {
            bxmin = bxmax = x; bymin = bymax = y; bzmin = bzmax = z;
            any = true;
        } else {
            bxmin = std::min(bxmin, x); bxmax = std::max(bxmax, x);
            bymin = std::min(bymin, y); bymax = std::max(bymax, y);
            bzmin = std::min(bzmin, z); bzmax = std::max(bzmax, z);
        }
    }
    if (any) {
        sel.voxels = std::move(dropped);
        sel.box.min_x = bxmin; sel.box.max_x = bxmax;
        sel.box.min_y = bymin; sel.box.max_y = bymax;
        sel.box.min_z = bzmin; sel.box.max_z = bzmax;
        sel.active = true;
    } else {
        sel.Clear();
    }

    fb.Clear();
    hist.RecordSelectionPost(sel);
    hist.CommitOp();
    ++doc.version;
}

void CancelFloatingLift(Document& doc) {
    FloatingBuffer& fb = CurrentFloatingBuffer();
    if (!fb.active) return;
    if (fb.originated_from_lift) {
        // Put the cleared source cells back exactly as they were and
        // restore the pre-lift selection. No EditHistory entry to pop
        // — lift never made one.
        for (const auto& [c, pal] : fb.source_originals) {
            doc.grid.Set(c[0], c[1], c[2], pal);
        }
        Selection& sel = CurrentSelection();
        sel = fb.pre_lift_sel;
    } else {
        // Paste-style: just discard, leaving doc untouched. Selection
        // gets cleared too since the pasted cells were the only thing
        // it referenced.
        Selection& sel = CurrentSelection();
        sel.voxels.clear();
        sel.box = Bounds3{};
        sel.active = false;
    }
    fb.Clear();
    ++doc.version;
}

void DiscardFloatingBuffer() {
    FloatingBuffer& fb = CurrentFloatingBuffer();
    if (!fb.active) return;
    Selection& sel = CurrentSelection();
    sel.voxels.clear();
    sel.box = Bounds3{};
    sel.active = false;
    fb.Clear();
}

void LiftClipboardToFloating(Document& /*doc*/,
                             const Clipboard& cb,
                             int32_t origin_x,
                             int32_t origin_y,
                             int32_t origin_z) {
    if (cb.empty()) return;
    FloatingBuffer& fb = CurrentFloatingBuffer();
    if (fb.active) return;  // caller must commit / discard first

    fb.grid.Clear();
    Selection& sel = CurrentSelection();
    sel.voxels.clear();
    int32_t bxmin = 0, bxmax = 0, bymin = 0, bymax = 0, bzmin = 0, bzmax = 0;
    bool any = false;
    for (uint32_t z = 0; z < cb.size_z; ++z) {
        for (uint32_t y = 0; y < cb.size_y; ++y) {
            for (uint32_t x = 0; x < cb.size_x; ++x) {
                const uint8_t v = cb.cells[cb.LinearIndex(x, y, z)];
                if (v == 0) continue;
                const int32_t gx = origin_x + static_cast<int32_t>(x);
                const int32_t gy = origin_y + static_cast<int32_t>(y);
                const int32_t gz = origin_z + static_cast<int32_t>(z);
                fb.grid.Set(gx, gy, gz, v);
                sel.voxels.push_back({gx, gy, gz});
                if (!any) {
                    bxmin = bxmax = gx;
                    bymin = bymax = gy;
                    bzmin = bzmax = gz;
                    any = true;
                } else {
                    bxmin = std::min(bxmin, gx); bxmax = std::max(bxmax, gx);
                    bymin = std::min(bymin, gy); bymax = std::max(bymax, gy);
                    bzmin = std::min(bzmin, gz); bzmax = std::max(bzmax, gz);
                }
            }
        }
    }
    if (!any) {
        fb.Clear();
        return;
    }
    fb.offset_x = fb.offset_y = fb.offset_z = 0;
    fb.active = true;
    fb.originated_from_lift = false;
    ++fb.version;
    sel.box.min_x = bxmin; sel.box.max_x = bxmax;
    sel.box.min_y = bymin; sel.box.max_y = bymax;
    sel.box.min_z = bzmin; sel.box.max_z = bzmax;
    sel.active = true;
}

}  // namespace macvoxel
