#include "RenderPanel.h"

#include "../EditorContext.h"
#include "Document.h"
#include "EditHistory.h"
#include "Fonts.h"
#include "Material.h"
#include "Palette.h"
#include "PanelState.h"
#include "RenderState.h"
#include "ToolState.h"

#include "imgui.h"

#include <algorithm>
#include <cfloat>
#include <cstdio>

namespace macvoxel {
namespace {
const char* TypeName(MaterialType t) {
    switch (t) {
        case MaterialType::Diffuse:  return "Diffuse";
        case MaterialType::Metal:    return "Metal";
        case MaterialType::Emissive: return "Emissive";
        case MaterialType::Glass:    return "Glass";
    }
    return "Diffuse";
}
}  // namespace

bool ConsumeSaveRenderClick(EditorContext& ctx) {
    bool& flag = ctx.panel.save_render_clicked;
    const bool was = flag;
    flag = false;
    return was;
}

void DrawRenderPanel(EditorContext& ctx, const RenderStats& stats) {
    Document& doc = ctx.document;
    ImGui::SetNextWindowSize(ImVec2(280, 240), ImGuiCond_FirstUseEver);
    ImGui::Begin("Render");

    RenderSettings& rs = ctx.render_settings;
    const RenderProgress& rp = ctx.render_progress;

    ImGui::PushFont(Fonts().header);
    ImGui::TextUnformatted("Mode");
    ImGui::PopFont();
    ImGui::Indent();
    ImGui::Checkbox("Path traced", &rs.path_traced);
    if (rs.path_traced) {
        ImGui::Checkbox("ACES tonemap", &rs.aces_tonemap);

        const char* kGlassNames[] = {"Probabilistic", "Absorption"};
        int gm = static_cast<int>(rs.glass_mode);
        if (ImGui::Combo("Glass mode", &gm, kGlassNames,
                         IM_ARRAYSIZE(kGlassNames))) {
            rs.glass_mode = static_cast<GlassMode>(gm);
        }
        if (ImGui::IsItemHovered()) {
            ImGui::SetTooltip(
                "Probabilistic: transparency picks refract vs diffuse, "
                "tint = surface color regardless.\n"
                "Absorption: always refracts; transparency interpolates "
                "tint from full color (0) to clear (1).");
        }

        ImGui::Checkbox("Match window resolution",
                        &rs.resolution_match_window);
        ImGui::BeginDisabled(rs.resolution_match_window);
        int wh[2] = {rs.render_width, rs.render_height};
        if (ImGui::DragInt2("Resolution", wh, 4.0f, 16, 16384)) {
            rs.render_width  = std::max(16, std::min(wh[0], 16384));
            rs.render_height = std::max(16, std::min(wh[1], 16384));
        }
        ImGui::EndDisabled();
        // Logarithmic feel — fine control at the low end where the user
        // is iterating, coarse at the upper end where they're committing
        // to a long render.
        ImGui::SliderInt("Sample target", &rs.max_samples, 16, 8192,
                         "%d", ImGuiSliderFlags_Logarithmic);

        const int target = std::max(1, rs.max_samples);
        const float fraction =
            std::min(1.0f, static_cast<float>(rp.sample_count) /
                               static_cast<float>(target));
        char overlay[32];
        std::snprintf(overlay, sizeof(overlay), "%u / %d",
                      rp.sample_count, target);
        ImGui::ProgressBar(fraction, ImVec2(-FLT_MIN, 0), overlay);
        if (rp.sample_count >= static_cast<uint32_t>(target)) {
            ImGui::TextDisabled("converged — adjust target or move camera "
                                "to keep sampling");
        }

        ImGui::Spacing();
        const bool can_save = rp.sample_count > 0;
        ImGui::BeginDisabled(!can_save);
        if (ImGui::Button("Save render…")) {
            ctx.panel.save_render_clicked = true;
        }
        ImGui::EndDisabled();
    }
    ImGui::Unindent();
    ImGui::Spacing();

    // -----------------------------------------------------------------
    // Material editor. The active palette index drives what the sliders
    // *display*, but writes propagate to every selected palette slot —
    // so a multi-select in the Palette panel turns this into a bulk
    // editor. Index 0 (the empty slot) is intentionally excluded from
    // writes; it's not paintable and has no material meaning.
    // -----------------------------------------------------------------
    ImGui::PushFont(Fonts().header);
    ImGui::TextUnformatted("Material");
    ImGui::PopFont();
    ImGui::Indent();
    {
        ToolSettings& tool = ctx.tool;
        const uint8_t idx = tool.palette_idx;
        const size_t sel_count = tool.selected_slots.count();
        if (sel_count > 1) {
            ImGui::Text("Index %u  (+%zu more selected)", idx, sel_count - 1);
        } else {
            ImGui::Text("Index %u", idx);
        }

        Material m = doc.palette.GetMaterial(idx);
        bool dirty = false;
        {
            const char* current = TypeName(m.type);
            if (ImGui::BeginCombo("Type", current)) {
                const MaterialType opts[] = {
                    MaterialType::Diffuse, MaterialType::Metal,
                    MaterialType::Emissive, MaterialType::Glass,
                };
                for (MaterialType opt : opts) {
                    const bool selected = m.type == opt;
                    if (ImGui::Selectable(TypeName(opt), selected)) {
                        if (m.type != opt) {
                            m.type = opt;
                            dirty = true;
                        }
                    }
                    if (selected) ImGui::SetItemDefaultFocus();
                }
                ImGui::EndCombo();
            }
        }
        if (ImGui::SliderFloat("Roughness", &m.roughness, 0.0f, 1.0f)) dirty = true;
        if (ImGui::SliderFloat("Metallic",  &m.metallic,  0.0f, 1.0f)) dirty = true;
        {
            float emit_pct = m.emission * 100.0f;
            if (ImGui::SliderFloat("Emission", &emit_pct, 0.0f, 100.0f, "%.0f")) {
                m.emission = emit_pct * 0.01f;
                dirty = true;
            }
        }
        if (ImGui::SliderInt("Power",        &m.emissionPower, 1, 5)) dirty = true;
        if (ImGui::SliderFloat("Transparency", &m.transparency, 0.0f, 1.0f)) dirty = true;
        if (ImGui::SliderFloat("IoR",        &m.ior,        1.0f, 3.0f)) dirty = true;
        // Coalesce the multi-widget gesture into one EditHistory op so
        // a slider drag (or a Combo pick) becomes a single Cmd-Z step.
        // Pre-drag values are snapshotted on the first dirty frame and
        // held until ImGui reports no widget is active any more — at
        // which point we commit. State lives on PanelState so a future
        // SwiftUI port has a real owner; doc reload calls
        // History.Clear() which is harmless here.
        auto& me = ctx.panel.material_edit;

        if (dirty) {
            EditHistory& hist = ctx.history;
            if (!me.drag) {
                me.drag = true;
                for (auto& v : me.pre) v.reset();
                for (size_t i = 1; i < tool.selected_slots.size(); ++i) {
                    if (tool.selected_slots.test(i)) {
                        me.pre[i] = doc.palette.GetMaterial(
                            static_cast<uint8_t>(i));
                    }
                }
                // Always include the active slot too — single-slot edits
                // work even if the selection somehow lost the active idx.
                if (idx != 0 && !me.pre[idx].has_value()) {
                    me.pre[idx] = doc.palette.GetMaterial(idx);
                }
                hist.BeginOp();
            }
            auto apply_to = [&](uint8_t s) {
                if (!me.pre[s].has_value()) return;
                doc.palette.SetMaterial(s, m);
                hist.RecordMaterial(s, *me.pre[s], m);
            };
            for (size_t i = 1; i < tool.selected_slots.size(); ++i) {
                if (tool.selected_slots.test(i)) {
                    apply_to(static_cast<uint8_t>(i));
                }
            }
            if (idx != 0) apply_to(idx);
            doc.BumpMaterials();
        }
        // Drag end: no widget is currently being interacted with and
        // there was no value change this frame. Close the op so the
        // next gesture starts a fresh undo step.
        if (me.drag && !dirty && !ImGui::IsAnyItemActive()) {
            ctx.history.CommitOp();
            me.drag = false;
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
