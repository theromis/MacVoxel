#include "PreviewOverlay.h"

namespace macvoxel {

PreviewOverlay& CurrentPreview() {
    static PreviewOverlay s;
    return s;
}

}  // namespace macvoxel
