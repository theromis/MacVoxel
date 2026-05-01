#include "RenderState.h"

namespace macvoxel {

RenderState& CurrentRenderState() {
    static RenderState s;
    return s;
}

}  // namespace macvoxel
