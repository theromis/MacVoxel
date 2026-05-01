#include "MaterialPanel.h"

#include "Document.h"
#include "Material.h"
#include "Palette.h"
#include "ToolState.h"

#include "imgui.h"

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

void DrawMaterialPanel(Document& doc) {
    const ToolState& tool = CurrentTool();
    const uint8_t idx = tool.palette_idx;

    ImGui::SetNextWindowSize(ImVec2(280, 380), ImGuiCond_FirstUseEver);
    ImGui::Begin("Material");

    ImGui::Text("Palette index: %u", idx);

    // Color editor — feeds straight back into the palette and bumps
    // doc.version so the renderer's signature check picks up the change.
    {
        Color c = doc.palette.Get(idx);
        float rgba[4] = {c.r / 255.0f, c.g / 255.0f, c.b / 255.0f, c.a / 255.0f};
        if (ImGui::ColorEdit4("Color", rgba, ImGuiColorEditFlags_AlphaBar)) {
            Color nc;
            nc.r = static_cast<uint8_t>(rgba[0] * 255.0f + 0.5f);
            nc.g = static_cast<uint8_t>(rgba[1] * 255.0f + 0.5f);
            nc.b = static_cast<uint8_t>(rgba[2] * 255.0f + 0.5f);
            nc.a = static_cast<uint8_t>(rgba[3] * 255.0f + 0.5f);
            if (!(nc == c)) {
                doc.palette.Set(idx, nc);
                ++doc.version;
            }
        }
    }

    ImGui::Spacing();
    ImGui::Separator();
    ImGui::TextUnformatted("Material");
    ImGui::TextDisabled("Stored now; consumed by Phase 8 path tracer.");

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

    if (ImGui::SliderFloat("Roughness",    &m.roughness,    0.0f,  1.0f)) dirty = true;
    if (ImGui::SliderFloat("Metallic",     &m.metallic,     0.0f,  1.0f)) dirty = true;
    if (ImGui::SliderFloat("Emission",     &m.emission,     0.0f, 16.0f)) dirty = true;
    if (ImGui::SliderFloat("Transparency", &m.transparency, 0.0f,  1.0f)) dirty = true;
    if (ImGui::SliderFloat("IoR",          &m.ior,          1.0f,  3.0f)) dirty = true;

    if (dirty) {
        doc.palette.SetMaterial(idx, m);
        ++doc.version;
    }

    ImGui::End();
}

}  // namespace macvoxel
