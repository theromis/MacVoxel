#include "SceneOps.h"

#include "EditorContext.h"

namespace macvoxel::scene_ops {

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

}  // namespace macvoxel::scene_ops
