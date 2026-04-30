#include "ModelPanel.h"

#include "Document.h"
#include "ToolState.h"

#include "imgui.h"

namespace macvoxel {
namespace {

bool g_show_demo = false;

ImU32 ColorToImU32(Color c) {
    return IM_COL32(c.r, c.g, c.b, c.a);
}

}  // namespace

void DrawModelPanel(const Document& doc, const RenderStats& stats) {
    ImGui::SetNextWindowSize(ImVec2(360, 480), ImGuiCond_FirstUseEver);
    ImGui::Begin("Model");

    ImGui::TextUnformatted("File");
    ImGui::Indent();
    if (doc.path.empty()) {
        ImGui::TextDisabled("(untitled)");
    } else {
        ImGui::TextWrapped("%s", doc.path.c_str());
    }
    ImGui::Unindent();
    ImGui::Spacing();

    ImGui::TextUnformatted("Grid");
    ImGui::Indent();
    const Bounds3 b = doc.grid.Bounds();
    const size_t filled = doc.grid.FilledCount();
    if (b.empty()) {
        ImGui::TextDisabled("(empty)");
    } else {
        ImGui::Text("bounds  X[%d, %d]  Y[%d, %d]  Z[%d, %d]",
                    b.min_x, b.max_x, b.min_y, b.max_y, b.min_z, b.max_z);
        ImGui::Text("extent  %d × %d × %d",
                    b.size_x(), b.size_y(), b.size_z());
        const size_t bbox_cells = static_cast<size_t>(b.size_x()) *
                                  static_cast<size_t>(b.size_y()) *
                                  static_cast<size_t>(b.size_z());
        const float density = bbox_cells > 0
                                  ? 100.0f * static_cast<float>(filled) /
                                        static_cast<float>(bbox_cells)
                                  : 0.0f;
        ImGui::Text("filled  %zu  (%.3f%% of bbox)", filled, density);
    }
    ImGui::Unindent();
    ImGui::Spacing();

    ImGui::TextUnformatted("Palette");
    ImGui::Indent();
    {
        ToolState& tool = CurrentTool();
        const float swatch = 16.0f;
        const float spacing = 1.0f;
        ImDrawList* dl = ImGui::GetWindowDrawList();
        const ImVec2 origin = ImGui::GetCursorScreenPos();
        const float total = 16.0f * (swatch + spacing) - spacing;
        // Reserve the area first so ImGui knows we're consuming it for input.
        ImGui::InvisibleButton("palette_grid", ImVec2(total, total));
        const bool grid_hovered = ImGui::IsItemHovered();
        const bool grid_clicked = ImGui::IsItemClicked(ImGuiMouseButton_Left);
        const ImVec2 mouse = ImGui::GetIO().MousePos;
        for (int i = 0; i < 256; ++i) {
            const int col = i % 16;
            const int row = i / 16;
            const ImVec2 a{origin.x + col * (swatch + spacing),
                           origin.y + row * (swatch + spacing)};
            const ImVec2 b{a.x + swatch, a.y + swatch};
            const Color c = doc.palette.Get(static_cast<uint8_t>(i));
            dl->AddRectFilled(a, b, ColorToImU32(c));

            const bool inside = mouse.x >= a.x && mouse.x < b.x &&
                                mouse.y >= a.y && mouse.y < b.y;
            if (grid_hovered && inside) {
                ImGui::SetTooltip("idx %d  RGBA(%u, %u, %u, %u)", i,
                                  c.r, c.g, c.b, c.a);
                if (grid_clicked) tool.palette_idx = static_cast<uint8_t>(i);
            }
            if (i == tool.palette_idx) {
                // Highlight selected swatch with a contrasting border.
                dl->AddRect(a, b, IM_COL32(255, 255, 255, 255), 0.0f, 0, 2.0f);
            }
        }
    }
    ImGui::Unindent();

    ImGui::Spacing();
    ImGui::TextUnformatted("Render");
    ImGui::Indent();
    {
        const ImGuiIO& io = ImGui::GetIO();
        const uint32_t tris = stats.index_count / 3;
        const float ratio = filled > 0
                                ? static_cast<float>(stats.quad_count) /
                                      static_cast<float>(filled * 6)
                                : 0.0f;
        ImGui::Text("%.1f FPS  (%.2f ms/frame)", io.Framerate,
                    io.Framerate > 0.0f ? 1000.0f / io.Framerate : 0.0f);
        ImGui::Text("quads      %u", stats.quad_count);
        ImGui::Text("triangles  %u", tris);
        ImGui::Text("vertices   %u", stats.vertex_count);
        ImGui::Text("face ratio %.3f  (quads / 6 * filled)", ratio);
    }
    ImGui::Unindent();

    ImGui::Spacing();
    ImGui::Separator();
    ImGui::Checkbox("Show ImGui demo (⌘D)", &g_show_demo);

    ImGui::End();

    if (g_show_demo) {
        ImGui::ShowDemoWindow(&g_show_demo);
    }
}

void ToggleImGuiDemoWindow() {
    g_show_demo = !g_show_demo;
}

}  // namespace macvoxel
