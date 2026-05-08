#include "LightPanel.h"

#include "Fonts.h"
#include "RenderState.h"

#include "imgui.h"

namespace macvoxel {

void DrawLightPanel() {
    ImGui::SetNextWindowSize(ImVec2(280, 200), ImGuiCond_FirstUseEver);
    ImGui::Begin("Light");

    RenderState& rs = CurrentRenderState();

    ImGui::PushFont(Fonts().header);
    ImGui::TextUnformatted("Path tracing");
    ImGui::PopFont();
    ImGui::Indent();
    // Path tracer's max bounce depth — gates how far indirect light can
    // reach before Russian-roulette / hard cap kills the path. 1 = direct
    // only; higher values let GI fill in but cost linearly per sample
    // (mitigated by RR after the first couple of bounces).
    ImGui::SliderInt("Bounces", &rs.max_bounces, 1, 8);

    // Direct-lighting NEE distribution. Toggling this flips between the
    // post-P14.5.A power-weighted CDF and the uniform pre-P14.5.A
    // baseline; the accumulator resets on either edge so the comparison
    // is fair from sample 0.
    ImGui::Checkbox("Power-weighted NEE", &rs.power_weighted_nee);
    if (ImGui::IsItemHovered()) {
        ImGui::SetTooltip(
            "On: NEE picks emitters from a CDF weighted by per-light "
            "power, so bright lights get sampled more often.\n"
            "Off: every emitter has equal pick probability — bigger "
            "variance on scenes with widely different light brightnesses.\n"
            "Toggle to A/B; converged image is the same either way.");
    }
    ImGui::Unindent();

    // Sky / sun model, power-weighted NEE, and the eventual ReSTIR
    // toggles will land here as those phases ship — keeping a single
    // home for everything that controls the light field, separate from
    // Render which is for output / format / sampling-budget controls.

    ImGui::End();
}

}  // namespace macvoxel
