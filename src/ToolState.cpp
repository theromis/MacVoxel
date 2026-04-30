#include "ToolState.h"

namespace macvoxel {

ToolState& CurrentTool() {
    static ToolState s_state;
    return s_state;
}

}  // namespace macvoxel
