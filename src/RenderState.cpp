#include "RenderState.h"

namespace macvoxel {

RenderSettings& CurrentRenderSettings() {
    static RenderSettings s;
    return s;
}

RenderProgress& CurrentRenderProgress() {
    static RenderProgress p;
    return p;
}

}  // namespace macvoxel
