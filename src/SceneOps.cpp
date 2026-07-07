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
    doc.SyncActiveModel();
    doc.active_object = index;
    doc.RebakeActiveObject();
    ctx.selection.Clear();
    doc.BumpScene();
}

}  // namespace macvoxel::scene_ops
