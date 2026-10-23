#pragma once

namespace macvoxel {

// `MacVoxel voxrt --input A.vox [--output B.vox] [--dump]`
// Round-trip harness: load → save → reload → compare (objects, world
// voxels, palette, materials, layers), then a save-fixpoint byte check.
// --dump prints the raw chunk structure instead (for A/B against files
// MagicaVoxel itself saved). Returns a process exit code.
int RunVoxRoundTrip(int argc, const char* argv[]);

}  // namespace macvoxel
