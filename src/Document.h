#pragma once

#include "EditVolume.h"
#include "Palette.h"
#include "VoxelGrid.h"
#include "VoxelVolume.h"

#include <cassert>
#include <cstdint>
#include <string>

namespace macvoxel {

// The single open document. Phase 2 is single-document; we'll grow into
// multi-document if/when there's a real reason.
//
// Mutations bump one (or more) of the typed dirty counters; renderers
// cache against the categories they consume so a palette tweak doesn't
// re-upload the entire chunk pool, and a brush stroke doesn't re-upload
// the palette / material / light buffers.
//
//   geometry_version → grid cell mutations (Set / Clear / load / paste)
//   palette_version  → palette color slot edits
//   material_version → material slot edits (in PalettePanel / RenderPanel)
//
// `version` is the coarse "anything changed" counter — kept as a
// convenience for callers that don't care which category. It's bumped
// alongside any typed bump.
//
// Lights are derived: the path tracer's emissive light list keys off
// (geometry × palette × materials), so it rebuilds whenever any of those
// counters advances. There is no separate `lights_version`.
struct Document {
    VoxelGrid grid;
    Palette palette;
    EditVolume volume;
    // Dense write-through shadow of the in-volume cells of `grid`,
    // sized from `volume`. Phase A1: just a CPU cache. A2 attaches a
    // Metal 3D texture; B1 makes the GPU side authoritative. Reads
    // still go through `grid` until then.
    VoxelVolume volume_shadow{volume};
    std::string path;  // empty => Untitled, never saved
    uint64_t version = 0;
    uint64_t geometry_version = 0;
    uint64_t palette_version = 0;
    uint64_t material_version = 0;

    void BumpGeometry()  { ++geometry_version; ++version; }
    void BumpPalette()   { ++palette_version;  ++version; }
    void BumpMaterials() { ++material_version; ++version; }
    // Single flip-point for routing voxel writes through future
    // GPU-authoritative storage (Phase A1: write-through to VoxelVolume
    // shadow; A2: ping-pong texture upload). All in-process edit paths
    // — brushes, preview commit, selection ops, history undo/redo,
    // floating-buffer commit, paste — must go through here. Loose
    // bounds and version bumping stay the caller's responsibility, so
    // semantics match `grid.Set` exactly until A1 flips the body.
    //
    // Carved out: `VoxFile::LoadVox` writes directly into a passed-in
    // `VoxelGrid&` (no Document). The whole-document load path will
    // grow its own bulk-upload entry point in A1.
    void SetCell(int32_t x, int32_t y, int32_t z, uint8_t v) {
        grid.Set(x, y, z, v);
        volume_shadow.Set(x, y, z, v);
        // A1 invariant: inside the edit volume, the dense shadow tracks
        // `grid` byte-for-byte. Cells outside the volume live in `grid`
        // alone (see VoxelVolume's drop-on-write rule).
        assert(!volume.Contains(x, y, z) ||
               grid.Get(x, y, z) == volume_shadow.Get(x, y, z));
    }

    // Bulk equivalent of SetCell for a CellChange[] array — used by
    // the GPU brush path so a 30k-cell stamp doesn't pay 30k chunk
    // hashmap finds in grid.Set. See VoxelGrid::ApplyChanges for the
    // semantic equivalence note.
    void ApplyChanges(const CellChange* changes, size_t count) {
        grid.ApplyChanges(changes, count);
        volume_shadow.ApplyChanges(changes, count);
    }

    // Whole-document cell wipe — used by New / Open / default seed.
    // Matches the previous `doc.grid.Clear()` pattern but keeps the
    // shadow in sync.
    void ClearCells() {
        grid.Clear();
        volume_shadow.Clear();
    }

    // Re-seed `volume_shadow` from the current `grid`. Required after
    // `LoadVox` populates `grid` directly (the carve-out documented on
    // `SetCell`), or after `grid` is wholesale-replaced (e.g. Open
    // moves a fresh Document in).
    void ReseedVolumeShadow() {
        volume_shadow.RebuildFromGrid(grid);
    }

    // Translate `grid` so the model fits inside `volume`: centered in
    // X/Y, resting on the floor (volume.z0) in Z — the editor's
    // ground-plane convention. Loaded .vox coords are authored
    // arbitrarily (corner-at-origin, or origin-centered scene-graph
    // transforms), so without this a model can land partly outside the
    // fixed edit volume: the path tracer (reads `grid`) shows it whole
    // while the dense shadow / tex_a (which drop out-of-volume cells)
    // show only a truncated corner. Uniform translation preserves
    // relative placement in multi-object scenes; idempotent once fitted;
    // no-op when empty. Call before ReseedVolumeShadow on load.
    void FitGridToVolume() {
        const Bounds3 b = grid.Bounds();
        if (b.empty()) return;
        const int32_t ox =
            volume.x0 + (volume.size_x() - b.size_x()) / 2 - b.min_x;
        const int32_t oy =
            volume.y0 + (volume.size_y() - b.size_y()) / 2 - b.min_y;
        const int32_t oz = volume.z0 - b.min_z;
        if (ox == 0 && oy == 0 && oz == 0) return;
        constexpr int32_t cs = static_cast<int32_t>(VoxelGrid::kChunkSize);
        VoxelGrid moved;
        for (const auto& [coord, chunk] : grid.chunks()) {
            for (int32_t lz = 0; lz < cs; ++lz)
            for (int32_t ly = 0; ly < cs; ++ly)
            for (int32_t lx = 0; lx < cs; ++lx) {
                const uint8_t v = chunk->cells[VoxelGrid::LocalIndex(lx, ly, lz)];
                if (v == 0) continue;
                moved.Set(coord.x * cs + lx + ox,
                          coord.y * cs + ly + oy,
                          coord.z * cs + lz + oz, v);
            }
        }
        grid = std::move(moved);
    }
    // Whole-document replacement (load / new / open). Bumps every
    // typed counter so renderers invalidate all categories at once.
    void BumpAll() {
        ++geometry_version;
        ++palette_version;
        ++material_version;
        ++version;
    }
};

}  // namespace macvoxel
