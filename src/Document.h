#pragma once

#include "Palette.h"
#include "VoxelGrid.h"

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
    std::string path;  // empty => Untitled, never saved
    uint64_t version = 0;
    uint64_t geometry_version = 0;
    uint64_t palette_version = 0;
    uint64_t material_version = 0;

    void BumpGeometry()  { ++geometry_version; ++version; }
    void BumpPalette()   { ++palette_version;  ++version; }
    void BumpMaterials() { ++material_version; ++version; }
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
