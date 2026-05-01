#include "Selection.h"

namespace macvoxel {

Selection& CurrentSelection() {
    static Selection s;
    return s;
}

}  // namespace macvoxel
