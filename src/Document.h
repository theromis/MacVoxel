#pragma once

#include "EditVolume.h"
#include "Palette.h"
#include "VoxScene.h"
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
    // The resident .vox scene graph: per-model local grids + node tree.
    // For now `grid` still holds flatten(all objects); the object-mode
    // pivot narrows it to the active object baked at its world transform.
    Scene scene;
    int32_t active_object = 0;
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
    // Scene-graph structure / transforms (not cell contents) changed.
    uint64_t scene_version = 0;
    // geometry_version value whose grid edits have been folded into the
    // active model (see SyncActiveModel).
    uint64_t synced_geometry_version = 0;

    void BumpGeometry()  { ++geometry_version; ++version; }
    void BumpPalette()   { ++palette_version;  ++version; }
    void BumpMaterials() { ++material_version; ++version; }
    void BumpScene()     { ++scene_version;    ++version; }
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

    // Relocate the edit volume (same 256³ size, new origin) and rebase
    // the dense shadow onto it. `volume` mutates in place — EditEngine
    // holds its address. The rebase leaves every chunk dirty, so the
    // next texture sync re-uploads tex_a in full.
    void MoveEditVolume(const EditVolume& v) {
        volume = v;
        volume_shadow.Rebase(volume, grid);
        BumpGeometry();
    }

    // Bake the active object into `grid` at its world transform and make
    // sure the edit volume covers it (moving the volume only when it has
    // to — the default anchor wins ties so ordinary single-model docs
    // keep the floor-anchored box). Rebuilding the shadow either way
    // leaves every chunk dirty for a full tex_a re-upload.
    void RebakeActiveObject() {
        FlattenObject(scene, active_object, &grid);
        const Bounds3 b = grid.Bounds();
        const bool covered =
            b.empty() || (volume.Contains(b.min_x, b.min_y, b.min_z) &&
                          volume.Contains(b.max_x, b.max_y, b.max_z));
        if (!covered) {
            MoveEditVolume(EditVolume::CenteredOn(b));
        } else {
            ReseedVolumeShadow();
            BumpGeometry();
        }
        // A fresh bake has nothing to fold back.
        synced_geometry_version = geometry_version;
    }

    // Inverse-map the (possibly edited) active-object grid back into its
    // model + leaf transform. Lossless; renormalizes SIZE when the
    // object grew. Guarded by `synced_geometry_version`: once the grid's
    // edits are folded, further calls are no-ops until geometry changes
    // again — this is what makes it safe to move the active object's
    // transform afterwards (a re-sync through the NEW transform would
    // corrupt the model).
    void SyncActiveModel() {
        if (synced_geometry_version == geometry_version) return;
        SyncModelFromWorldGrid(scene, active_object, grid);
        synced_geometry_version = geometry_version;
    }

    // Translate the scene so it fits inside `volume`: centered in X/Y,
    // resting on the floor (volume.z0) in Z — the editor's ground-plane
    // convention. Loaded .vox coords are authored arbitrarily
    // (corner-at-origin, or origin-centered scene-graph transforms), so
    // without this a model can land partly outside the fixed edit
    // volume: the path tracer (reads `grid`) shows it whole while the
    // dense shadow / tex_a (which drop out-of-volume cells) show only a
    // truncated corner. Uniform translation preserves relative placement
    // in multi-object scenes; idempotent once fitted; no-op when empty.
    // Callers re-flatten into `grid` afterwards, then ReseedVolumeShadow.
    void FitSceneToVolume() {
        const Bounds3 b = scene.WorldBounds();
        if (b.empty()) return;
        const int32_t ox =
            volume.x0 + (volume.size_x() - b.size_x()) / 2 - b.min_x;
        const int32_t oy =
            volume.y0 + (volume.size_y() - b.size_y()) / 2 - b.min_y;
        const int32_t oz = volume.z0 - b.min_z;
        if (ox == 0 && oy == 0 && oz == 0) return;
        scene.TranslateAll(Vec3i32{ox, oy, oz});
    }

    // Loaded scenes keep their authored coordinates (round-trip
    // placement preservation); only scenes escaping the world box get
    // re-fitted. Call on load, before the first RebakeActiveObject.
    void EnsureSceneInWorld() {
        const Bounds3 b = scene.WorldBounds();
        if (b.empty()) return;
        const bool in_world =
            b.min_x >= -kWorldHalf && b.min_y >= -kWorldHalf &&
            b.min_z >= -kWorldHalf && b.max_x < kWorldHalf &&
            b.max_y < kWorldHalf && b.max_z < kWorldHalf;
        if (!in_world) FitSceneToVolume();
    }
    // Whole-document replacement (load / new / open). Bumps every
    // typed counter so renderers invalidate all categories at once.
    void BumpAll() {
        ++geometry_version;
        ++palette_version;
        ++material_version;
        ++scene_version;
        ++version;
    }
};

}  // namespace macvoxel
