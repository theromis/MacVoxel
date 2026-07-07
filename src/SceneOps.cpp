#include "SceneOps.h"

#include "EditorContext.h"

#include <algorithm>
#include <utility>

namespace macvoxel::scene_ops {
namespace {

bool ValidSelection(EditorContext& ctx, int* out_index) {
    const int i = ctx.selected_object;
    if (i < 0 ||
        static_cast<size_t>(i) >= ctx.document.scene.objects.size()) {
        return false;
    }
    *out_index = i;
    return true;
}

// Link a freshly-built leaf (trn → shp → model) into `parent` at `pos`,
// select it, and record AddObject as one op. Returns the new object's
// index. Assumes trn/shp/model are fully formed and ids are fresh.
int InsertLeaf(EditorContext& ctx, SceneModel&& model, SceneNode&& trn,
               SceneNode&& shp, int32_t parent, int32_t pos) {
    Document& doc = ctx.document;
    Scene& scene = doc.scene;
    auto git = scene.nodes.find(parent);
    if (git == scene.nodes.end() ||
        git->second.kind != SceneNode::Kind::Group) {
        return -1;
    }
    // The model must be current before anything reads it from the graph.
    doc.SyncActiveModel();

    const int32_t trn_id = trn.id;
    scene.models.push_back(std::move(model));
    scene.nodes[trn.id] = std::move(trn);
    scene.nodes[shp.id] = std::move(shp);

    const int active = doc.active_object;
    const int32_t active_trn =
        (active >= 0 && static_cast<size_t>(active) < scene.objects.size())
            ? scene.objects[static_cast<size_t>(active)].trn_id
            : -1;
    auto& kids = git->second.children;
    const size_t at = std::min(
        static_cast<size_t>(std::max(pos, 0)), kids.size());
    kids.insert(kids.begin() + static_cast<ptrdiff_t>(at), trn_id);
    scene.RebuildObjects();
    if (active_trn >= 0) {
        const int relocated = FindObjectByTrn(scene, active_trn);
        if (relocated >= 0) doc.active_object = relocated;
    }

    EditOp::SceneChange sc;
    sc.kind = EditOp::SceneChange::Kind::AddObject;
    sc.parent_group = parent;
    sc.child_pos = static_cast<int32_t>(at);
    sc.child_trn = trn_id;
    ctx.history.BeginOp();
    ctx.history.RecordSceneChange(sc);
    ctx.history.CommitOp();

    doc.BumpScene();
    const int new_index = FindObjectByTrn(scene, trn_id);
    ctx.selected_object = new_index;
    return new_index;
}

}  // namespace

void ActivateObject(EditorContext& ctx, int32_t index) {
    Document& doc = ctx.document;
    if (index < 0 ||
        static_cast<size_t>(index) >= doc.scene.objects.size()) {
        return;
    }
    if (index == doc.active_object) return;
    const int32_t old_active = doc.active_object;
    doc.SyncActiveModel();
    doc.active_object = index;
    doc.RebakeActiveObject();
    ctx.selection.Clear();
    doc.BumpScene();

    // Every activation lands in history — undoing past a switch must
    // re-activate the prior object before its cell ops replay.
    EditOp::SceneChange sc;
    sc.kind = EditOp::SceneChange::Kind::ActiveSwitch;
    sc.old_active = old_active;
    sc.new_active = index;
    ctx.history.BeginOp();
    ctx.history.RecordSceneChange(sc);
    ctx.history.CommitOp();
}

int DuplicateObject(EditorContext& ctx) {
    int i;
    if (!ValidSelection(ctx, &i)) return -1;
    Document& doc = ctx.document;
    Scene& scene = doc.scene;
    const SceneObject obj = scene.objects[static_cast<size_t>(i)];
    if (obj.trn_id < 0 || obj.model_id < 0 ||
        static_cast<size_t>(obj.model_id) >= scene.models.size()) {
        return -1;
    }
    // The source model must hold the latest edits before cloning.
    doc.SyncActiveModel();

    SceneModel clone;
    const SceneModel& src = scene.models[static_cast<size_t>(obj.model_id)];
    clone.grid = src.grid.Clone();
    clone.dims[0] = src.dims[0];
    clone.dims[1] = src.dims[1];
    clone.dims[2] = src.dims[2];
    const int32_t new_model =
        static_cast<int32_t>(scene.models.size());

    const SceneNode& src_trn = scene.nodes.at(obj.trn_id);
    const SceneNode& src_shp = scene.nodes.at(obj.shp_id);
    SceneNode trn = src_trn;      // attrs, t, rot, layer, frames
    SceneNode shp;
    shp.kind = SceneNode::Kind::Shape;
    shp.attrs = src_shp.attrs;
    shp.models.emplace_back(new_model, AttrDict{});
    trn.id = NextNodeId(scene);
    shp.id = trn.id + 1;
    trn.child = shp.id;
    auto name_it = trn.attrs.find("_name");
    trn.attrs["_name"] =
        (name_it != trn.attrs.end() ? name_it->second : "Object") + " copy";

    int32_t parent = -1, pos = -1;
    if (!ParentGroupOf(scene, obj.trn_id, &parent, &pos)) {
        parent = RootGroupId(scene);
        pos = -1;
    }
    if (parent < 0) return -1;
    return InsertLeaf(ctx, std::move(clone), std::move(trn), std::move(shp),
                      parent, pos + 1);
}

int NewEmptyObject(EditorContext& ctx) {
    Document& doc = ctx.document;
    Scene& scene = doc.scene;
    const int32_t parent = RootGroupId(scene);
    if (parent < 0) return -1;

    constexpr int32_t kNewObjectDim = 40;  // matches the default doc cube
    SceneModel model;
    model.dims[0] = model.dims[1] = model.dims[2] = kNewObjectDim;

    SceneNode trn;
    trn.kind = SceneNode::Kind::Transform;
    trn.frames.emplace_back();
    trn.id = NextNodeId(scene);
    trn.attrs["_name"] =
        "Object " + std::to_string(scene.objects.size() + 1);
    SceneNode shp;
    shp.kind = SceneNode::Kind::Shape;
    shp.id = trn.id + 1;
    shp.models.emplace_back(static_cast<int32_t>(scene.models.size()),
                            AttrDict{});
    trn.child = shp.id;

    // Rest on the floor at the origin, nudged +8x off exact
    // translation collisions (PasteObject's rule).
    Vec3i32 target_t{0, 0, kNewObjectDim / 2};
    bool collides = true;
    while (collides) {
        collides = false;
        for (const SceneObject& o : scene.objects) {
            if (o.world_t == target_t) {
                target_t.x += 8;
                collides = true;
                break;
            }
        }
    }

    const int new_index = InsertLeaf(
        ctx, std::move(model), std::move(trn), std::move(shp), parent,
        static_cast<int32_t>(scene.nodes.at(parent).children.size()));
    if (new_index < 0) return -1;
    SetObjectWorldTransform(scene, new_index, RotMat{}, target_t);
    doc.BumpScene();
    return new_index;
}

bool DeleteObject(EditorContext& ctx) {
    int i;
    if (!ValidSelection(ctx, &i)) return false;
    Document& doc = ctx.document;
    Scene& scene = doc.scene;
    if (scene.objects.size() <= 1) return false;  // never delete the last
    const SceneObject obj = scene.objects[static_cast<size_t>(i)];
    if (obj.trn_id < 0) return false;
    int32_t parent = -1, pos = -1;
    if (!ParentGroupOf(scene, obj.trn_id, &parent, &pos)) return false;

    doc.SyncActiveModel();
    ctx.history.BeginOp();

    if (i == doc.active_object) {
        const int32_t survivor =
            (static_cast<size_t>(i + 1) < scene.objects.size()) ? i + 1
                                                                : i - 1;
        doc.active_object = survivor;
        doc.RebakeActiveObject();
        ctx.selection.Clear();
        EditOp::SceneChange sw;
        sw.kind = EditOp::SceneChange::Kind::ActiveSwitch;
        sw.old_active = i;
        sw.new_active = survivor;
        ctx.history.RecordSceneChange(sw);
    }

    const int active = doc.active_object;
    const int32_t active_trn =
        (active >= 0 && static_cast<size_t>(active) < scene.objects.size())
            ? scene.objects[static_cast<size_t>(active)].trn_id
            : -1;
    auto& kids = scene.nodes.at(parent).children;
    kids.erase(kids.begin() + pos);
    scene.RebuildObjects();
    if (active_trn >= 0) {
        const int relocated = FindObjectByTrn(scene, active_trn);
        if (relocated >= 0) doc.active_object = relocated;
    }

    EditOp::SceneChange rm;
    rm.kind = EditOp::SceneChange::Kind::RemoveObject;
    rm.parent_group = parent;
    rm.child_pos = pos;
    rm.child_trn = obj.trn_id;
    ctx.history.RecordSceneChange(rm);
    ctx.history.CommitOp();

    ctx.selected_object = -1;
    doc.BumpScene();
    return true;
}

int ResizeTargetObject(const EditorContext& ctx) {
    const Scene& scene = ctx.document.scene;
    int i = ctx.selected_object;
    if (i < 0 || static_cast<size_t>(i) >= scene.objects.size()) {
        i = ctx.document.active_object;
    }
    if (i < 0 || static_cast<size_t>(i) >= scene.objects.size()) {
        return -1;
    }
    const SceneObject& o = scene.objects[static_cast<size_t>(i)];
    const bool ok = o.trn_id >= 0 && o.model_id >= 0 &&
                    static_cast<size_t>(o.model_id) < scene.models.size();
    return ok ? i : -1;
}

bool CanResizeSelectedObject(const EditorContext& ctx) {
    return ResizeTargetObject(ctx) >= 0;
}

bool ResizeSelectedObject(EditorContext& ctx, Vec3i32 new_dims) {
    const int i = ResizeTargetObject(ctx);
    if (i < 0) return false;
    Document& doc = ctx.document;
    Scene& scene = doc.scene;
    new_dims.x = std::clamp(new_dims.x, 1, 256);
    new_dims.y = std::clamp(new_dims.y, 1, 256);
    new_dims.z = std::clamp(new_dims.z, 1, 256);

    // Pending grid edits must land in the model before it's read.
    doc.SyncActiveModel();

    const SceneObject obj = scene.objects[static_cast<size_t>(i)];
    SceneModel& model = scene.models[static_cast<size_t>(obj.model_id)];
    const Vec3i32 old_dims{model.dims[0], model.dims[1], model.dims[2]};
    if (new_dims == old_dims) return false;

    // Voxels falling outside the new box get clipped (recorded below so
    // the resize undoes as one step).
    std::vector<EditOp::SceneChange::ClippedCell> clipped;
    constexpr int32_t cs = static_cast<int32_t>(VoxelGrid::kChunkSize);
    for (const auto& [coord, chunk] : model.grid.chunks()) {
        if (chunk->filled_count == 0) continue;
        for (int32_t lz = 0; lz < cs; ++lz)
        for (int32_t ly = 0; ly < cs; ++ly)
        for (int32_t lx = 0; lx < cs; ++lx) {
            const uint8_t v =
                chunk->cells[VoxelGrid::LocalIndex(lx, ly, lz)];
            if (v == 0) continue;
            const Vec3i32 l{coord.x * cs + lx, coord.y * cs + ly,
                            coord.z * cs + lz};
            if (l.x >= 0 && l.x < new_dims.x && l.y >= 0 &&
                l.y < new_dims.y && l.z >= 0 && l.z < new_dims.z) {
                continue;
            }
            clipped.push_back({l, v});
        }
    }
    for (const auto& c : clipped) {
        model.grid.Set(c.l.x, c.l.y, c.l.z, 0);
    }
    model.dims[0] = new_dims.x;
    model.dims[1] = new_dims.y;
    model.dims[2] = new_dims.z;

    // Local coords stay fixed across the resize, so the pivot shift
    // must be absorbed by the translation to keep surviving voxels in
    // place: w = R(l − h) + T ⇒ T' = T + R(h2 − h).
    const Vec3i32 h{old_dims.x / 2, old_dims.y / 2, old_dims.z / 2};
    const Vec3i32 h2{new_dims.x / 2, new_dims.y / 2, new_dims.z / 2};
    Vec3i32 world_t2 = obj.world_t + obj.world_r * (h2 - h);

    // Keep the grown dims box inside the world.
    {
        const Vec3i32 a = obj.world_r * (Vec3i32{} - h2) + world_t2;
        const Vec3i32 b =
            obj.world_r * (Vec3i32{new_dims.x - 1, new_dims.y - 1,
                                   new_dims.z - 1} -
                           h2) +
            world_t2;
        auto nudge = [](int32_t lo, int32_t hi) {
            if (lo < -kWorldHalf) return -kWorldHalf - lo;
            if (hi > kWorldHalf - 1) return (kWorldHalf - 1) - hi;
            return 0;
        };
        world_t2 = world_t2 +
                   Vec3i32{nudge(std::min(a.x, b.x), std::max(a.x, b.x)),
                           nudge(std::min(a.y, b.y), std::max(a.y, b.y)),
                           nudge(std::min(a.z, b.z), std::max(a.z, b.z))};
    }

    const Vec3i32 old_leaf_t = scene.nodes.at(obj.trn_id).t;
    SetObjectWorldTransform(scene, i, obj.world_r, world_t2);

    EditOp::SceneChange sc;
    sc.kind = EditOp::SceneChange::Kind::ModelResize;
    sc.trn_id = obj.trn_id;
    sc.model_id = obj.model_id;
    sc.old_t = old_leaf_t;
    sc.new_t = scene.nodes.at(obj.trn_id).t;
    sc.old_dims = old_dims;
    sc.new_dims = new_dims;
    sc.clipped = std::move(clipped);
    ctx.history.BeginOp();
    ctx.history.RecordSceneChange(sc);
    ctx.history.CommitOp();

    doc.BumpScene();
    if (i == doc.active_object) doc.RebakeActiveObject();
    return true;
}

bool CopyObject(EditorContext& ctx) {
    int i;
    if (!ValidSelection(ctx, &i)) return false;
    Document& doc = ctx.document;
    Scene& scene = doc.scene;
    const SceneObject& obj = scene.objects[static_cast<size_t>(i)];
    if (obj.trn_id < 0 || obj.model_id < 0 ||
        static_cast<size_t>(obj.model_id) >= scene.models.size()) {
        return false;
    }
    doc.SyncActiveModel();

    const SceneModel& src = scene.models[static_cast<size_t>(obj.model_id)];
    const SceneNode& trn = scene.nodes.at(obj.trn_id);
    const SceneNode& shp = scene.nodes.at(obj.shp_id);
    ObjectClipboard& cb = ctx.object_clipboard;
    cb.model.grid = src.grid.Clone();
    cb.model.dims[0] = src.dims[0];
    cb.model.dims[1] = src.dims[1];
    cb.model.dims[2] = src.dims[2];
    cb.trn_attrs = trn.attrs;
    cb.frames = trn.frames;
    cb.layer_id = trn.layer_id;
    cb.shp_attrs = shp.attrs;
    cb.world_r = obj.world_r;
    cb.world_t = obj.world_t;
    cb.valid = true;
    return true;
}

int PasteObject(EditorContext& ctx) {
    ObjectClipboard& cb = ctx.object_clipboard;
    if (!cb.valid) return -1;
    Document& doc = ctx.document;
    Scene& scene = doc.scene;
    const int32_t parent = RootGroupId(scene);
    if (parent < 0) return -1;

    // Land beside the source if something already sits exactly there.
    Vec3i32 target_t = cb.world_t;
    bool collides = true;
    while (collides) {
        collides = false;
        for (const SceneObject& o : scene.objects) {
            if (o.world_t == target_t) {
                target_t.x += 8;
                collides = true;
                break;
            }
        }
    }

    SceneModel model;
    model.grid = cb.model.grid.Clone();
    model.dims[0] = cb.model.dims[0];
    model.dims[1] = cb.model.dims[1];
    model.dims[2] = cb.model.dims[2];
    const int32_t new_model = static_cast<int32_t>(scene.models.size());

    SceneNode trn;
    trn.kind = SceneNode::Kind::Transform;
    trn.attrs = cb.trn_attrs;
    trn.frames = cb.frames;
    if (trn.frames.empty()) trn.frames.emplace_back();
    trn.layer_id = cb.layer_id;
    trn.id = NextNodeId(scene);
    SceneNode shp;
    shp.kind = SceneNode::Kind::Shape;
    shp.attrs = cb.shp_attrs;
    shp.id = trn.id + 1;
    shp.models.emplace_back(new_model, AttrDict{});
    trn.child = shp.id;

    const int new_index =
        InsertLeaf(ctx, std::move(model), std::move(trn), std::move(shp),
                   parent, static_cast<int32_t>(
                               scene.nodes.at(parent).children.size()));
    if (new_index < 0) return -1;
    // Re-solve the copied world transform through the new ancestors.
    SetObjectWorldTransform(scene, new_index, cb.world_r, target_t);
    doc.BumpScene();
    return new_index;
}

}  // namespace macvoxel::scene_ops
