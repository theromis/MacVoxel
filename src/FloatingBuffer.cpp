#include "FloatingBuffer.h"

namespace macvoxel {

FloatingBuffer& CurrentFloatingBuffer() {
    static FloatingBuffer s;
    return s;
}

}  // namespace macvoxel
