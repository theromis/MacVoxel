#include "LightPanel.h"

#include "Fonts.h"
#include "RenderState.h"

#include "imgui.h"

namespace macvoxel {

void DrawLightPanel() {
    ImGui::SetNextWindowSize(ImVec2(280, 200), ImGuiCond_FirstUseEver);
    ImGui::Begin("Light");

    RenderSettings& rs = CurrentRenderSettings();

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
    ImGui::Checkbox("Atmospheric (Nishita)", &rs.atmospheric_sky);
    if (ImGui::IsItemHovered()) {
        ImGui::SetTooltip(
            "Single-scatter Nishita atmospheric scattering: per-pixel "
            "Rayleigh + Mie integral driven by the sun direction. Gives "
            "a natural blue zenith / warm horizon gradient and a sun "
            "halo for free; bottom-line cost is ~256 atmosphere ops "
            "per missed sky ray.\n\n"
            "When off, the sky is the simpler constant tint × intensity "
            "below.");
    }
    ImGui::BeginDisabled(rs.atmospheric_sky);
    // Multiplier on the constant sky tint. Drop to 0 to kill ambient
    // hemisphere fill so emitter contributions read clearly; raise
    // above 1 for an HDR-like overcast. Ignored when Atmospheric is on.
    ImGui::SliderFloat("Intensity##sky", &rs.sky_intensity, 0.0f, 4.0f,
                       "%.2f");
    ImGui::EndDisabled();
    // Aerial-perspective fade where ground meets sky. The value is the
    // angular extent (degrees) the fade is concentrated within — so
    // 1° is a tight band right at the horizon, 10° spreads it well
    // into the floor. 0 disables the softening (sharp horizon).
    ImGui::SliderFloat("Horizon", &rs.horizon_softness_deg, 0.0f, 15.0f,
                       "%.1f°");
    if (ImGui::IsItemHovered()) {
        ImGui::SetTooltip(
            "Softens the line where the floor meets the sky by blending "
            "the limit-direction sky color into grazing-angle ground "
            "rays. Value is the angular extent of the fade — at this "
            "many degrees below the horizon the floor returns ~5%% sky.\n"
            "0° disables it (sharp horizon); ~3° is subtle aerial "
            "perspective; 10°+ is a hazy distant ground.");
    }
    ImGui::Unindent();

    ImGui::Spacing();
    ImGui::PushFont(Fonts().header);
    ImGui::TextUnformatted("Sun");
    ImGui::PopFont();
    ImGui::Indent();
    // Direction is exposed in elevation/azimuth (degrees) since
    // sliding "X / Y / Z" components of a normalized vector is fiddly
    // — both axes wrap intuitively. Elevation = 0 lays the sun on the
    // horizon, 90 sticks it at zenith. Below-horizon sun is allowed
    // (negative elevation) but contributes nothing meaningful since
    // the only currently-visible-via-sun rays are those that escape
    // upward to the sky.
    ImGui::SliderFloat("Elevation",
                       &rs.sun_elevation_deg, -90.0f, 90.0f, "%.1f°");
    ImGui::SliderFloat("Azimuth",
                       &rs.sun_azimuth_deg, 0.0f, 360.0f, "%.1f°");
    ImGui::SliderFloat("Angular size",
                       &rs.sun_angular_diameter_deg, 0.1f, 30.0f, "%.2f°");
    ImGui::ColorEdit3("Color", rs.sun_color);
    // Intensity is irradiance, not radiance — the per-direction
    // radiance the shader actually uses is `color × intensity /
    // solid_angle`, which decouples surface brightness from angular
    // size. So intensity=1 lights a perpendicular white surface to
    // ≈ 1/π linear (≈ 0.55 display after ACES + sRGB) regardless of
    // whether the sun is 1° or 20°. Range 0–10 covers "subtle accent"
    // through "noon overcast"; logarithmic for fine control near zero.
    ImGui::SliderFloat("Intensity##sun", &rs.sun_intensity, 0.0f, 10.0f,
                       "%.2f", ImGuiSliderFlags_Logarithmic);
    if (ImGui::IsItemHovered()) {
        ImGui::SetTooltip(
            "Irradiance scale — the integrated lighting strength reaching "
            "a surface facing the sun. Independent of angular size, so "
            "a 1° sun and a 10° sun at intensity=1 light surfaces "
            "identically (only the visible disc size changes). 0 "
            "disables the sun (default). The sun is direct-sampled via "
            "NEE on every non-delta bounce and MIS-weighted against the "
            "BSDF, so even a tiny sun converges cleanly.");
    }
    ImGui::Unindent();

    // Sky / sun model, power-weighted NEE, and the eventual ReSTIR
    // toggles will land here as those phases ship — keeping a single
    // home for everything that controls the light field, separate from
    // Render which is for output / format / sampling-budget controls.

    ImGui::End();
}

}  // namespace macvoxel
