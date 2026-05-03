#include "RenderPanel.h"

#include "Fonts.h"
#include "RenderState.h"

#include "imgui.h"

#include <algorithm>
#include <cfloat>
#include <cstdio>

namespace macvoxel {

void DrawRenderPanel(const RenderStats& stats) {
    ImGui::SetNextWindowSize(ImVec2(280, 240), ImGuiCond_FirstUseEver);
    ImGui::Begin("Render");

    RenderState& rs = CurrentRenderState();

    ImGui::PushFont(Fonts().header);
    ImGui::TextUnformatted("Mode");
    ImGui::PopFont();
    ImGui::Indent();
    ImGui::Checkbox("Path traced", &rs.path_traced);
    if (rs.path_traced) {
        ImGui::SliderInt("Bounces", &rs.max_bounces, 1, 8);
        // Logarithmic feel — fine control at the low end where the user
        // is iterating, coarse at the upper end where they're committing
        // to a long render.
        ImGui::SliderInt("Sample target", &rs.max_samples, 16, 8192,
                         "%d", ImGuiSliderFlags_Logarithmic);

        const int target = std::max(1, rs.max_samples);
        const float fraction =
            std::min(1.0f, static_cast<float>(rs.sample_count) /
                               static_cast<float>(target));
        char overlay[32];
        std::snprintf(overlay, sizeof(overlay), "%u / %d",
                      rs.sample_count, target);
        ImGui::ProgressBar(fraction, ImVec2(-FLT_MIN, 0), overlay);
        if (rs.sample_count >= static_cast<uint32_t>(target)) {
            ImGui::TextDisabled("converged — adjust target or move camera "
                                "to keep sampling");
        }
    }
    ImGui::Unindent();
    ImGui::Spacing();

    ImGui::PushFont(Fonts().header);
    ImGui::TextUnformatted("Performance");
    ImGui::PopFont();
    ImGui::Indent();
    {
        const ImGuiIO& io = ImGui::GetIO();
        ImGui::Text("%.1f FPS  (%.2f ms/frame)", io.Framerate,
                    io.Framerate > 0.0f ? 1000.0f / io.Framerate : 0.0f);
        ImGui::Text("chunks  %u", stats.chunk_count);
        const double mb = static_cast<double>(stats.gpu_bytes) / (1024.0 * 1024.0);
        ImGui::Text("GPU mem %.1f MB", mb);
    }
    ImGui::Unindent();

    ImGui::End();
}

}  // namespace macvoxel
