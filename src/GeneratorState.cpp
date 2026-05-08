#include "GeneratorState.h"

namespace macvoxel {

GeneratorState& CurrentGeneratorState() {
    static GeneratorState state;
    return state;
}

}  // namespace macvoxel
