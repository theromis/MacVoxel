#include "PreviewOps.h"

#include "Document.h"
#include "EditHistory.h"
#include "EditorContext.h"
#include "PreviewOverlay.h"
#include "VoxelGrid.h"

#include <cstdint>

namespace macvoxel {

void CommitPreviewOverlayThroughHistory(EditorContext& ctx) {
    PreviewOverlay& overlay = ctx.preview;
    if (!overlay.active) return;
    Document& doc = ctx.document;

    using VG = VoxelGrid;
    EditHistory& history = ctx.history;
    bool op_open = false;
    bool any_writes = false;
    auto ensure_op = [&]() {
        if (!op_open) {
            history.BeginOp();
            op_open = true;
        }
    };

    // Additions: every non-zero cell in the additions chunk pool is a
    // "write this palette index here". Skip cells whose value already
    // matches the doc — Stamp turns those into ClearAt, so they
    // normally don't appear, but a redundant pass costs nothing and
    // guards against stale chunks from earlier in the gesture.
    for (const auto& [coord, chunk] : overlay.additions.chunks()) {
        if (chunk->filled_count == 0) continue;
        for (uint32_t i = 0; i < VG::kChunkVolume; ++i) {
            const uint8_t new_val = chunk->cells[i];
            if (new_val == 0) continue;
            const uint32_t lx = i & VG::kChunkMask;
            const uint32_t ly = (i >> VG::kChunkBits) & VG::kChunkMask;
            const uint32_t lz = i >> (2 * VG::kChunkBits);
            const int32_t x = (coord.x << VG::kChunkBits) + (int32_t)lx;
            const int32_t y = (coord.y << VG::kChunkBits) + (int32_t)ly;
            const int32_t z = (coord.z << VG::kChunkBits) + (int32_t)lz;
            const uint8_t old_val = doc.grid.Get(x, y, z);
            if (old_val == new_val) continue;
            ensure_op();
            doc.grid.Set(x, y, z, new_val);
            history.Record(x, y, z, old_val, new_val);
            any_writes = true;
        }
    }
    // Removals: every non-zero cell in the removals chunk pool is a
    // "make this doc cell empty". Doc cells already empty are no-ops.
    for (const auto& [coord, chunk] : overlay.removals.chunks()) {
        if (chunk->filled_count == 0) continue;
        for (uint32_t i = 0; i < VG::kChunkVolume; ++i) {
            if (chunk->cells[i] == 0) continue;
            const uint32_t lx = i & VG::kChunkMask;
            const uint32_t ly = (i >> VG::kChunkBits) & VG::kChunkMask;
            const uint32_t lz = i >> (2 * VG::kChunkBits);
            const int32_t x = (coord.x << VG::kChunkBits) + (int32_t)lx;
            const int32_t y = (coord.y << VG::kChunkBits) + (int32_t)ly;
            const int32_t z = (coord.z << VG::kChunkBits) + (int32_t)lz;
            const uint8_t old_val = doc.grid.Get(x, y, z);
            if (old_val == 0) continue;
            ensure_op();
            doc.grid.Set(x, y, z, 0);
            history.Record(x, y, z, old_val, 0);
            any_writes = true;
        }
    }

    if (op_open) history.CommitOp();
    if (any_writes) doc.BumpGeometry();
    overlay.Clear();
}

}  // namespace macvoxel
