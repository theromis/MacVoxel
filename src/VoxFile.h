#pragma once

#include <string>

namespace macvoxel {

class VoxelGrid;
class Palette;

// Loads model 0 from a MagicaVoxel .vox file into out_grid and out_palette.
// Scene-graph and material chunks are recognised but skipped (a brief
// warning is logged to stderr). If the file has no RGBA chunk, out_palette
// is reset to the MagicaVoxel default.
//
// Returns true on success. On failure, *out_error (if non-null) is set to a
// human-readable message and the outputs are left unchanged.
bool LoadVox(const std::string& path,
             VoxelGrid* out_grid,
             Palette* out_palette,
             std::string* out_error = nullptr);

// Writes a single-model .vox file (header, MAIN, SIZE, XYZI, RGBA) for the
// given grid and palette. Returns true on success.
bool SaveVox(const std::string& path,
             const VoxelGrid& grid,
             const Palette& palette,
             std::string* out_error = nullptr);

}  // namespace macvoxel
