#pragma once

#include <cstdint>
#include <string>

namespace macvoxel {

struct Document;

// How palette colors are stored in the glTF material.
enum class MeshColorMode {
    // One material. baseColorTexture is the 256-wide palette; TEXCOORD_0
    // points at the voxel's texel. No COLOR_0 attribute.
    Texture,
    // No image. Each vertex carries the voxel's palette color in COLOR_0
    // and the material's baseColorFactor is white.
    VertexColors,
};

struct MeshExportStats {
    uint32_t quads = 0;
    uint32_t vertices = 0;
    uint32_t triangles = 0;
};

// Write a glTF 2.0 binary (.glb) of every solid voxel in the scene.
// Folds the active object's edits back into the scene graph first, then
// meshes the flattened scene (not only the active grid). Exposed faces
// only. Empty scenes fail. `stats` and `error` may be null.
// `merge` greedy-merges coplanar faces of the same palette slot, then
// splits an edge where a corner of a face on another plane or palette
// slot meets it, so that seam is not a T-junction. Vertices of one merged
// face are shared. False writes one quad per exposed face.
bool ExportSceneGlb(Document& doc, const std::string& path, MeshColorMode mode,
                    MeshExportStats* stats, std::string* error, bool merge = false);

// Headless `MacVoxel export ...`. Argv is positioned past the `export`
// subcommand (argv[0] is "export"). Returns a process exit code.
int RunCliExport(int argc, const char* argv[]);

}  // namespace macvoxel
