#include "EditorContext.h"

namespace macvoxel {

EditorContext::EditorContext() {
    // The multi-selection always contains the active palette index when
    // non-empty; pre-seed at construction so the first material edit
    // has somewhere to write before the user touches the palette panel.
    tool.selected_slots.set(tool.palette_idx);
}

}  // namespace macvoxel
