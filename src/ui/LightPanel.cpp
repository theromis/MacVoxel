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

    // ReSTIR-DI candidate count. M=1 reduces to single-candidate NEE
    // (the pre-RIS behavior); M>1 enables the RIS reservoir loop. The
    // shadow-ray cost is the same either way (one per pixel per frame);
    // the per-candidate cost is just a CDF binary search + 4 rands +
    // a few dot products, so M=8 is essentially free.
    ImGui::SliderInt("RIS candidates (M)", &rs.nee_ris_count, 1, 32);
    if (ImGui::IsItemHovered()) {
        ImGui::SetTooltip(
            "Number of NEE candidates per pixel per frame. The reservoir "
            "weighted-samples one of them by target_pdf / source_pdf, "
            "then fires a single shadow ray.\n"
            "M=1: equivalent to pre-RIS single-candidate NEE.\n"
            "M=8: standard ReSTIR-DI starting point — visible variance "
            "drop on emitter-heavy scenes.\n"
            "Higher M: diminishing returns; spatial / temporal reuse "
            "(future work) would multiply effective M further.");
    }
    ImGui::Unindent();

    ImGui::Spacing();
    ImGui::PushFont(Fonts().header);
    ImGui::TextUnformatted("Sky");
    ImGui::PopFont();
    ImGui::Indent();
    // Multiplier on the hardcoded sky tint. Drop to 0 to kill ambient
    // hemisphere fill so emitter contributions read clearly; raise
    // above 1 for an HDR-like overcast. Replaced once the sun/sky
    // model in Phase 14 ships.
    ImGui::SliderFloat("Intensity", &rs.sky_intensity, 0.0f, 4.0f, "%.2f");
    ImGui::Unindent();

    // Sky / sun model, power-weighted NEE, and the eventual ReSTIR
    // toggles will land here as those phases ship — keeping a single
    // home for everything that controls the light field, separate from
    // Render which is for output / format / sampling-budget controls.

    ImGui::End();
}

}  // namespace macvoxel
