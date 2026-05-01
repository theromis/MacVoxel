#include "Clipboard.h"

namespace macvoxel {

Clipboard& CurrentClipboard() {
    static Clipboard c;
    return c;
}

}  // namespace macvoxel
