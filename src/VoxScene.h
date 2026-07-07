#pragma once

#include "VoxelGrid.h"

#include <cstdint>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace macvoxel {

struct Vec3i32 {
    int32_t x = 0, y = 0, z = 0;

    friend Vec3i32 operator+(const Vec3i32& a, const Vec3i32& b) {
        return Vec3i32{a.x + b.x, a.y + b.y, a.z + b.z};
    }
    friend Vec3i32 operator-(const Vec3i32& a, const Vec3i32& b) {
        return Vec3i32{a.x - b.x, a.y - b.y, a.z - b.z};
    }
    friend bool operator==(const Vec3i32& a, const Vec3i32& b) {
        return a.x == b.x && a.y == b.y && a.z == b.z;
    }
};

// Signed-permutation rotation matrix — one of the axis-aligned orientations
// a .vox scene-graph transform can express. FromByte implements the `_r`
// rotation-byte codec: bits 0-1 select row 0's non-zero column, bits 2-3
// row 1's (row 2 is implied), bits 4/5/6 carry the per-row signs. The
// identity encodes as 4; malformed bytes decode to identity.
struct RotMat {
    int8_t m[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};

    static RotMat FromByte(uint8_t rot);

    // For signed permutations the transpose is the inverse.
    RotMat Transposed() const;

    bool IsIdentity() const;

    friend RotMat operator*(const RotMat& a, const RotMat& b);
    Vec3i32 operator*(const Vec3i32& v) const;
};

using AttrDict = std::map<std::string, std::string>;

// One SIZE/XYZI pair. Voxels live in model-LOCAL coordinates in [0, dims);
// the scene graph places the model's center (floor(dims/2)) at its
// accumulated translation.
struct SceneModel {
    VoxelGrid grid;
    int32_t dims[3] = {0, 0, 0};
};

// One nTRN / nGRP / nSHP chunk, kept faithful to the file so unedited
// structure (names, hidden flags, layers, animation frames, nested groups)
// round-trips verbatim. Frame 0's _t/_r are decoded into `t`/`rot` for
// editing; the raw frame dicts are retained for write-back.
struct SceneNode {
    enum class Kind : uint8_t { Transform, Group, Shape };
    Kind kind = Kind::Transform;
    int32_t id = -1;
    AttrDict attrs;
    // Transform:
    int32_t child = -1;
    int32_t layer_id = -1;
    std::vector<AttrDict> frames;
    Vec3i32 t{};
    uint8_t rot = 4;
    // Group:
    std::vector<int32_t> children;
    // Shape: (model_id, model attrs) pairs; frame 0 is the edited model.
    std::vector<std::pair<int32_t, AttrDict>> models;
};

struct SceneLayer {
    int32_t id = -1;
    AttrDict attrs;
};

// Flat editing view over one leaf nTRN→nSHP pair, derived by
// Scene::RebuildObjects. If a subtree is instanced (two paths reach the
// same leaf), each path yields its own SceneObject sharing trn_id/model_id.
struct SceneObject {
    int32_t trn_id = -1;   // -1 for a bare nSHP not wrapped by an nTRN
    int32_t shp_id = -1;
    int32_t model_id = -1;
    Vec3i32 anc_t{};       // accumulated ancestors, excluding the leaf nTRN
    RotMat anc_r{};
    Vec3i32 world_t{};     // ancestors composed with the leaf nTRN
    RotMat world_r{};
    std::string name;
    bool hidden = false;   // any _hidden along the path
};

struct Scene {
    std::vector<SceneModel> models;
    std::map<int32_t, SceneNode> nodes;
    int32_t root_id = 0;
    std::vector<SceneLayer> layers;
    std::vector<SceneObject> objects;  // derived; DFS order = stable UI order

    // Re-derive `objects` from the node tree (DFS from root). Call after
    // any structural change. Cycle-safe; diamonds (instanced subtrees)
    // produce one object per path.
    void RebuildObjects();

    // Union of every object's transformed tight voxel bounds — matches the
    // bounds a full flatten would produce.
    Bounds3 WorldBounds() const;

    bool empty() const;

    // Uniform world-space translation of the whole scene (root transform,
    // or each top-level child when the root is a bare group).
    void TranslateAll(Vec3i32 offset);

    // One-object scene wrapping an existing world-space grid: canonical
    // nTRN(0)→nGRP(1)→nTRN(2)→nSHP(3) skeleton, model coords rebased to
    // the grid's min corner, leaf `t` chosen so a flatten reproduces the
    // input grid exactly.
    static Scene FromSingleGrid(const VoxelGrid& world_grid);
};

// Rasterize the scene's objects (frame-0 models) into a world-space grid,
// in object order, last-writer-wins. exclude_object < 0 flattens all.
void FlattenScene(const Scene& scene, int exclude_object, VoxelGrid* out);

// Lossless world→model-local inverse map for one object: every non-empty
// cell of world_grid is mapped through the object's inverse transform into
// its model grid. Local bounds are renormalized to a tight [0, dims) box
// and the leaf translation is re-solved so world placement is unchanged.
void SyncModelFromWorldGrid(Scene& scene, int object_index,
                            const VoxelGrid& world_grid);

}  // namespace macvoxel
