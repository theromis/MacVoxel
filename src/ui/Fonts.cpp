#include "Fonts.h"

namespace macvoxel {

AppFonts& Fonts() {
    static AppFonts f;
    return f;
}

}  // namespace macvoxel
