#include "VoxScene.h"

#include <algorithm>
#include <unordered_set>

namespace macvoxel {

RotMat RotMat::FromByte(uint8_t rot) {
    const int c0 = rot & 0x3;
    const int c1 = (rot >> 2) & 0x3;
    const int c2 = 3 - c0 - c1;
    if (c0 == c1 || c2 < 0 || c2 > 2) return RotMat{};
    const int s0 = (rot & (1 << 4)) ? -1 : 1;
    const int s1 = (rot & (1 << 5)) ? -1 : 1;
    const int s2 = (rot & (1 << 6)) ? -1 : 1;
    RotMat out;
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) out.m[i][j] = 0;
    out.m[0][c0] = static_cast<int8_t>(s0);
    out.m[1][c1] = static_cast<int8_t>(s1);
    out.m[2][c2] = static_cast<int8_t>(s2);
    return out;
}

uint8_t RotMat::ToByte() const {
    int c0 = 0, c1 = 1;
    int s0 = 1, s1 = 1, s2 = 1;
    for (int j = 0; j < 3; ++j) {
        if (m[0][j] != 0) { c0 = j; s0 = m[0][j]; }
        if (m[1][j] != 0) { c1 = j; s1 = m[1][j]; }
        if (m[2][j] != 0) {          s2 = m[2][j]; }
    }
    return static_cast<uint8_t>(c0 | (c1 << 2) | ((s0 < 0 ? 1 : 0) << 4) |
                                ((s1 < 0 ? 1 : 0) << 5) |
                                ((s2 < 0 ? 1 : 0) << 6));
}

RotMat RotMat::Transposed() const {
    RotMat out;
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) out.m[i][j] = m[j][i];
    return out;
}

bool RotMat::IsIdentity() const {
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) {
            if (m[i][j] != (i == j ? 1 : 0)) return false;
        }
    return true;
}

RotMat operator*(const RotMat& a, const RotMat& b) {
    RotMat out;
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            int v = 0;
            for (int k = 0; k < 3; ++k) v += a.m[i][k] * b.m[k][j];
            out.m[i][j] = static_cast<int8_t>(v);
        }
    }
    return out;
}

Vec3i32 RotMat::operator*(const Vec3i32& v) const {
    return Vec3i32{
        m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
        m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
        m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z,
    };
}

namespace {

bool AttrHidden(const AttrDict& attrs) {
    auto it = attrs.find("_hidden");
    return it != attrs.end() && it->second == "1";
}

Vec3i32 HalfDims(const SceneModel& model) {
    return Vec3i32{model.dims[0] / 2, model.dims[1] / 2, model.dims[2] / 2};
}

// DFS with path-based cycle detection: `path` blocks true cycles while
// still allowing diamonds (an instanced subtree yields one object per
// route it is reached through).
void WalkForObjects(const Scene& scene, int32_t node_id, const Vec3i32& t,
                    const RotMat& r, bool hidden,
                    std::unordered_set<int32_t>& path,
                    std::vector<SceneObject>* out) {
    if (!path.insert(node_id).second) return;
    auto it = scene.nodes.find(node_id);
    if (it == scene.nodes.end()) {
        path.erase(node_id);
        return;
    }
    const SceneNode& n = it->second;
    switch (n.kind) {
        case SceneNode::Kind::Transform: {
            const bool h = hidden || AttrHidden(n.attrs);
            const Vec3i32 ct = t + r * n.t;
            const RotMat cr = r * RotMat::FromByte(n.rot);
            auto cit = scene.nodes.find(n.child);
            if (cit != scene.nodes.end() &&
                cit->second.kind == SceneNode::Kind::Shape) {
                const SceneNode& shp = cit->second;
                if (!shp.models.empty()) {
                    SceneObject o;
                    o.trn_id = n.id;
                    o.shp_id = shp.id;
                    o.model_id = shp.models[0].first;
                    o.anc_t = t;
                    o.anc_r = r;
                    o.world_t = ct;
                    o.world_r = cr;
                    auto name_it = n.attrs.find("_name");
                    if (name_it != n.attrs.end()) o.name = name_it->second;
                    o.hidden = h || AttrHidden(shp.attrs);
                    out->push_back(std::move(o));
                }
            } else {
                WalkForObjects(scene, n.child, ct, cr, h, path, out);
            }
            break;
        }
        case SceneNode::Kind::Group: {
            const bool h = hidden || AttrHidden(n.attrs);
            for (int32_t c : n.children) {
                WalkForObjects(scene, c, t, r, h, path, out);
            }
            break;
        }
        case SceneNode::Kind::Shape: {
            // Malformed file: an nSHP not wrapped by an nTRN. Surface it
            // (trn_id = -1) so it still renders; transform edits need the
            // wrapper and are rejected upstream.
            if (!n.models.empty()) {
                SceneObject o;
                o.shp_id = n.id;
                o.model_id = n.models[0].first;
                o.anc_t = t;
                o.anc_r = r;
                o.world_t = t;
                o.world_r = r;
                o.hidden = hidden || AttrHidden(n.attrs);
                out->push_back(std::move(o));
            }
            break;
        }
    }
    path.erase(node_id);
}

bool ValidObject(const Scene& scene, const SceneObject& o) {
    return o.model_id >= 0 &&
           static_cast<size_t>(o.model_id) < scene.models.size();
}

}  // namespace

void Scene::RebuildObjects() {
    objects.clear();
    if (nodes.empty()) return;
    std::unordered_set<int32_t> path;
    WalkForObjects(*this, root_id, Vec3i32{}, RotMat{}, false, path, &objects);
}

namespace {

bool ObjectBoundsImpl(const Scene& scene, const SceneObject& o,
                      Bounds3* out) {
    if (!ValidObject(scene, o)) return false;
    const SceneModel& model = scene.models[static_cast<size_t>(o.model_id)];
    const Bounds3 lb = model.grid.Bounds();
    if (lb.empty()) return false;
    const Vec3i32 h = HalfDims(model);
    const Vec3i32 a =
        o.world_r * (Vec3i32{lb.min_x, lb.min_y, lb.min_z} - h) + o.world_t;
    const Vec3i32 b =
        o.world_r * (Vec3i32{lb.max_x, lb.max_y, lb.max_z} - h) + o.world_t;
    *out = Bounds3{std::min(a.x, b.x), std::min(a.y, b.y), std::min(a.z, b.z),
                   std::max(a.x, b.x), std::max(a.y, b.y), std::max(a.z, b.z)};
    return true;
}

}  // namespace

bool ObjectWorldBounds(const Scene& scene, int object_index, Bounds3* out) {
    if (object_index < 0 ||
        static_cast<size_t>(object_index) >= scene.objects.size()) {
        return false;
    }
    return ObjectBoundsImpl(
        scene, scene.objects[static_cast<size_t>(object_index)], out);
}

void SetObjectWorldTransform(Scene& scene, int object_index,
                             const RotMat& world_r, const Vec3i32& world_t) {
    if (object_index < 0 ||
        static_cast<size_t>(object_index) >= scene.objects.size()) {
        return;
    }
    const SceneObject& o =
        scene.objects[static_cast<size_t>(object_index)];
    if (o.trn_id < 0) return;
    auto it = scene.nodes.find(o.trn_id);
    if (it == scene.nodes.end()) return;
    const RotMat anc_inv = o.anc_r.Transposed();
    it->second.t = anc_inv * (world_t - o.anc_t);
    it->second.rot = (anc_inv * world_r).ToByte();
    // Cheap full refresh — transform edits don't change DFS order, so
    // object indices stay stable.
    scene.RebuildObjects();
}

Bounds3 Scene::WorldBounds() const {
    Bounds3 out;
    bool any = false;
    for (const SceneObject& o : objects) {
        Bounds3 wb;
        if (!ObjectBoundsImpl(*this, o, &wb)) continue;
        if (!any) {
            out = wb;
            any = true;
        } else {
            out.min_x = std::min(out.min_x, wb.min_x);
            out.min_y = std::min(out.min_y, wb.min_y);
            out.min_z = std::min(out.min_z, wb.min_z);
            out.max_x = std::max(out.max_x, wb.max_x);
            out.max_y = std::max(out.max_y, wb.max_y);
            out.max_z = std::max(out.max_z, wb.max_z);
        }
    }
    return out;
}

bool Scene::empty() const {
    for (const SceneObject& o : objects) {
        if (ValidObject(*this, o) &&
            !models[static_cast<size_t>(o.model_id)].grid.empty()) {
            return false;
        }
    }
    return true;
}

void Scene::TranslateAll(Vec3i32 offset) {
    auto it = nodes.find(root_id);
    if (it == nodes.end()) return;
    SceneNode& root = it->second;
    if (root.kind == SceneNode::Kind::Transform) {
        root.t = root.t + offset;
    } else if (root.kind == SceneNode::Kind::Group) {
        for (int32_t c : root.children) {
            auto cit = nodes.find(c);
            if (cit != nodes.end() &&
                cit->second.kind == SceneNode::Kind::Transform) {
                cit->second.t = cit->second.t + offset;
            }
        }
    }
    RebuildObjects();
}

Scene Scene::FromSingleGrid(const VoxelGrid& world_grid) {
    Scene scene;
    SceneModel model;
    const Bounds3 b = world_grid.Bounds();
    Vec3i32 min{};
    if (!b.empty()) {
        min = Vec3i32{b.min_x, b.min_y, b.min_z};
        model.dims[0] = b.size_x();
        model.dims[1] = b.size_y();
        model.dims[2] = b.size_z();
        for (const auto& [coord, chunk] : world_grid.chunks()) {
            if (chunk->filled_count == 0) continue;
            constexpr int32_t cs =
                static_cast<int32_t>(VoxelGrid::kChunkSize);
            for (int32_t lz = 0; lz < cs; ++lz)
            for (int32_t ly = 0; ly < cs; ++ly)
            for (int32_t lx = 0; lx < cs; ++lx) {
                const uint8_t v =
                    chunk->cells[VoxelGrid::LocalIndex(lx, ly, lz)];
                if (v == 0) continue;
                model.grid.Set(coord.x * cs + lx - min.x,
                               coord.y * cs + ly - min.y,
                               coord.z * cs + lz - min.z, v);
            }
        }
    }
    const Vec3i32 h = HalfDims(model);
    scene.models.push_back(std::move(model));

    SceneNode root;
    root.kind = SceneNode::Kind::Transform;
    root.id = 0;
    root.child = 1;
    root.frames.emplace_back();

    SceneNode group;
    group.kind = SceneNode::Kind::Group;
    group.id = 1;
    group.children.push_back(2);

    SceneNode leaf;
    leaf.kind = SceneNode::Kind::Transform;
    leaf.id = 2;
    leaf.child = 3;
    leaf.frames.emplace_back();
    // Flatten computes world = (l − h) + t; local l = world − min, so
    // t = min + h reproduces the input grid exactly.
    leaf.t = min + h;

    SceneNode shape;
    shape.kind = SceneNode::Kind::Shape;
    shape.id = 3;
    shape.models.emplace_back(0, AttrDict{});

    scene.nodes[0] = std::move(root);
    scene.nodes[1] = std::move(group);
    scene.nodes[2] = std::move(leaf);
    scene.nodes[3] = std::move(shape);
    scene.root_id = 0;
    scene.RebuildObjects();
    return scene;
}

namespace {

void BakeObjectCells(const Scene& scene, const SceneObject& o,
                     VoxelGrid* out) {
    if (!ValidObject(scene, o)) return;
    const SceneModel& model = scene.models[static_cast<size_t>(o.model_id)];
    const Vec3i32 h = HalfDims(model);
    constexpr int32_t cs = static_cast<int32_t>(VoxelGrid::kChunkSize);
    for (const auto& [coord, chunk] : model.grid.chunks()) {
        if (chunk->filled_count == 0) continue;
        for (int32_t lz = 0; lz < cs; ++lz)
        for (int32_t ly = 0; ly < cs; ++ly)
        for (int32_t lx = 0; lx < cs; ++lx) {
            const uint8_t v = chunk->cells[VoxelGrid::LocalIndex(lx, ly, lz)];
            if (v == 0) continue;
            const Vec3i32 l{coord.x * cs + lx, coord.y * cs + ly,
                            coord.z * cs + lz};
            const Vec3i32 w = o.world_r * (l - h) + o.world_t;
            out->Set(w.x, w.y, w.z, v);
        }
    }
}

}  // namespace

void FlattenScene(const Scene& scene, int exclude_object, VoxelGrid* out) {
    out->Clear();
    for (size_t i = 0; i < scene.objects.size(); ++i) {
        if (static_cast<int>(i) == exclude_object) continue;
        BakeObjectCells(scene, scene.objects[i], out);
    }
}

void FlattenObject(const Scene& scene, int object_index, VoxelGrid* out) {
    out->Clear();
    if (object_index < 0 ||
        static_cast<size_t>(object_index) >= scene.objects.size()) {
        return;
    }
    BakeObjectCells(scene, scene.objects[static_cast<size_t>(object_index)],
                    out);
}

void SyncModelFromWorldGrid(Scene& scene, int object_index,
                            const VoxelGrid& world_grid) {
    if (object_index < 0 ||
        static_cast<size_t>(object_index) >= scene.objects.size()) {
        return;
    }
    SceneObject& o = scene.objects[static_cast<size_t>(object_index)];
    if (!ValidObject(scene, o)) return;
    SceneModel& model = scene.models[static_cast<size_t>(o.model_id)];

    if (world_grid.empty()) {
        model.grid.Clear();
        return;
    }

    const RotMat rinv = o.world_r.Transposed();
    const Vec3i32 h = HalfDims(model);

    // Map every world cell into the current local frame, tracking bounds.
    struct LocalCell { Vec3i32 l; uint8_t v; };
    std::vector<LocalCell> cells;
    cells.reserve(world_grid.FilledCount());
    Vec3i32 lmin{INT32_MAX, INT32_MAX, INT32_MAX};
    Vec3i32 lmax{INT32_MIN, INT32_MIN, INT32_MIN};
    constexpr int32_t cs = static_cast<int32_t>(VoxelGrid::kChunkSize);
    for (const auto& [coord, chunk] : world_grid.chunks()) {
        if (chunk->filled_count == 0) continue;
        for (int32_t lz = 0; lz < cs; ++lz)
        for (int32_t ly = 0; ly < cs; ++ly)
        for (int32_t lx = 0; lx < cs; ++lx) {
            const uint8_t v = chunk->cells[VoxelGrid::LocalIndex(lx, ly, lz)];
            if (v == 0) continue;
            const Vec3i32 w{coord.x * cs + lx, coord.y * cs + ly,
                            coord.z * cs + lz};
            const Vec3i32 l = rinv * (w - o.world_t) + h;
            lmin = Vec3i32{std::min(lmin.x, l.x), std::min(lmin.y, l.y),
                           std::min(lmin.z, l.z)};
            lmax = Vec3i32{std::max(lmax.x, l.x), std::max(lmax.y, l.y),
                           std::max(lmax.z, l.z)};
            cells.push_back(LocalCell{l, v});
        }
    }

    // Renormalize to a tight [0, dims) box and re-solve the translation so
    // world placement is bit-identical: w = R(l − h) + T = R(l + s − h') + T'
    // ⇒ T' = T + R(h' − h − s), with s shifting the local min to zero.
    const Vec3i32 s{-lmin.x, -lmin.y, -lmin.z};
    model.dims[0] = lmax.x - lmin.x + 1;
    model.dims[1] = lmax.y - lmin.y + 1;
    model.dims[2] = lmax.z - lmin.z + 1;
    const Vec3i32 h2 = HalfDims(model);

    model.grid.Clear();
    for (const LocalCell& c : cells) {
        model.grid.Set(c.l.x + s.x, c.l.y + s.y, c.l.z + s.z, c.v);
    }

    if (!(s == Vec3i32{}) || !(h2 == h)) {
        const Vec3i32 world_t2 = o.world_t + o.world_r * (h2 - h - s);
        if (o.trn_id >= 0) {
            auto it = scene.nodes.find(o.trn_id);
            if (it != scene.nodes.end()) {
                it->second.t = o.anc_r.Transposed() * (world_t2 - o.anc_t);
            }
        }
        o.world_t = world_t2;
    }
}

}  // namespace macvoxel
