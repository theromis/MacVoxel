#pragma once

namespace macvoxel {

// Apply a theme inspired by Apple's "Pro" apps (Logic, Final Cut, Motion):
// near-black panel chrome, muted secondary surfaces, a single saturated
// blue accent, and very subtle borders. Sets ImGui style colors and
// widget metrics. Call once after ImGui::CreateContext.
void ApplyProTheme();

}  // namespace macvoxel
