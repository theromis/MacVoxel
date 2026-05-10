#include "PanelState.h"

namespace macvoxel {

PanelState& CurrentPanelState() {
    static PanelState s;
    return s;
}

}  // namespace macvoxel
