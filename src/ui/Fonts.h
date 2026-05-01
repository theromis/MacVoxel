#pragma once

struct ImFont;

namespace macvoxel {

// Two cuts of San Francisco loaded once at ImGui setup: a body weight and
// a heavier (rasterizer-multiplied) display weight for section headers.
struct AppFonts {
    ImFont* body = nullptr;
    ImFont* header = nullptr;
};

AppFonts& Fonts();

}  // namespace macvoxel
