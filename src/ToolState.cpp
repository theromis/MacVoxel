#include "ToolState.h"

namespace macvoxel {

ToolState& CurrentTool() {
    static ToolState s_state = []{
        ToolState s;
        // Seed the selection with the default active slot so the first
        // material edit has somewhere to write.
        s.selected_slots.set(s.palette_idx);
        return s;
    }();
    return s_state;
}

}  // namespace macvoxel
