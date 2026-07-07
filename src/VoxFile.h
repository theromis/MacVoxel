#pragma once

#include <string>

namespace macvoxel {

class VoxelGrid;
class Palette;
struct Scene;

// Loads a MagicaVoxel .vox file with its scene graph kept resident:
// per-model local grids plus the nTRN/nGRP/nSHP node tree (attrs, layers,
// and animation frames preserved verbatim). Files without a scene graph
// get a synthesized single-object skeleton. If the file has no RGBA chunk,
// out_palette is reset to the MagicaVoxel default.
//
// Returns true on success. On failure, *out_error (if non-null) is set to a
// human-readable message and the outputs are left unchanged.
bool LoadVoxScene(const std::string& path,
                  Scene* out_scene,
                  Palette* out_palette,
                  std::string* out_error = nullptr);

// Legacy flattened view: LoadVoxScene + FlattenScene(all) into one
// world-space grid.
bool LoadVox(const std::string& path,
             VoxelGrid* out_grid,
             Palette* out_palette,
             std::string* out_error = nullptr);

// Writes a single-model .vox file (header, MAIN, SIZE, XYZI, RGBA, MATL)
// for the given grid and palette. Returns true on success.
bool SaveVox(const std::string& path,
             const VoxelGrid& grid,
             const Palette& palette,
             std::string* out_error = nullptr);

}  // namespace macvoxel
