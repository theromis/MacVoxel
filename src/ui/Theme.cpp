#include "Theme.h"

#include "imgui.h"

namespace macvoxel {
namespace {

constexpr ImVec4 RGB(int r, int g, int b, float a = 1.0f) {
    return ImVec4(r / 255.0f, g / 255.0f, b / 255.0f, a);
}

}  // namespace

void ApplyProTheme() {
    ImGuiStyle& s = ImGui::GetStyle();

    // ----- Layout / metrics -----
    s.WindowRounding         = 6.0f;
    s.ChildRounding          = 4.0f;
    s.FrameRounding          = 4.0f;
    s.GrabRounding           = 4.0f;
    s.PopupRounding          = 4.0f;
    s.ScrollbarRounding      = 6.0f;
    s.TabRounding            = 4.0f;
    s.WindowBorderSize       = 1.0f;
    s.ChildBorderSize        = 1.0f;
    s.PopupBorderSize        = 1.0f;
    s.FrameBorderSize        = 0.0f;
    s.SeparatorTextBorderSize = 1.0f;
    s.TabBarOverlineSize     = 2.0f;  // accent stripe atop selected tab
    s.WindowPadding          = ImVec2(10, 10);
    s.FramePadding           = ImVec2(8, 4);
    s.ItemSpacing            = ImVec2(8, 6);
    s.ItemInnerSpacing       = ImVec2(6, 4);
    s.IndentSpacing          = 14.0f;
    s.ScrollbarSize          = 12.0f;
    s.GrabMinSize            = 10.0f;

    // ----- Color palette -----
    // Greys go very dark; Pro apps live in near-black territory.
    const ImVec4 bg_window  = RGB(0x1B, 0x1B, 0x1F);  // panel background
    const ImVec4 bg_chrome  = RGB(0x14, 0x14, 0x17);  // titlebars, separators
    const ImVec4 bg_input   = RGB(0x26, 0x26, 0x2C);  // sliders, text fields
    const ImVec4 bg_input_h = RGB(0x32, 0x32, 0x39);  // hovered
    const ImVec4 bg_input_a = RGB(0x3D, 0x3D, 0x46);  // pressed

    const ImVec4 accent     = RGB(0x3D, 0x82, 0xC9);  // muted Mac blue
    const ImVec4 accent_h   = RGB(0x4D, 0x95, 0xDC);
    const ImVec4 accent_a   = RGB(0x2E, 0x6E, 0xAB);
    const ImVec4 accent_dim = RGB(0x3D, 0x82, 0xC9, 0.32f);
    // Darker blue for tab/header backgrounds — keeps the "selected"
    // identity without screaming-bright primary blue.
    const ImVec4 accent_deep = RGB(0x24, 0x44, 0x68);

    const ImVec4 text_pri   = RGB(0xE8, 0xE8, 0xEA);
    const ImVec4 text_sec   = RGB(0x99, 0x99, 0xA0);
    const ImVec4 text_dis   = RGB(0x55, 0x55, 0x5C);

    const ImVec4 border     = ImVec4(0.0f, 0.0f, 0.0f, 0.6f);
    const ImVec4 border_lt  = ImVec4(1.0f, 1.0f, 1.0f, 0.04f);

    ImVec4* c = s.Colors;

    c[ImGuiCol_Text]                  = text_pri;
    c[ImGuiCol_TextDisabled]          = text_dis;
    c[ImGuiCol_WindowBg]              = bg_window;
    c[ImGuiCol_ChildBg]               = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_PopupBg]               = ImVec4(bg_chrome.x, bg_chrome.y, bg_chrome.z, 0.96f);
    c[ImGuiCol_Border]                = border;
    c[ImGuiCol_BorderShadow]          = ImVec4(0, 0, 0, 0);

    c[ImGuiCol_FrameBg]               = bg_input;
    c[ImGuiCol_FrameBgHovered]        = bg_input_h;
    c[ImGuiCol_FrameBgActive]         = bg_input_a;

    // Slightly lighter than panel body so the title bar reads as a
    // distinct "lid" on top of the panel.
    c[ImGuiCol_TitleBg]               = RGB(0x24, 0x24, 0x29);
    c[ImGuiCol_TitleBgActive]         = RGB(0x2C, 0x2C, 0x33);
    c[ImGuiCol_TitleBgCollapsed]      = RGB(0x1F, 0x1F, 0x24);
    c[ImGuiCol_MenuBarBg]             = bg_chrome;

    c[ImGuiCol_ScrollbarBg]           = ImVec4(0, 0, 0, 0.30f);
    c[ImGuiCol_ScrollbarGrab]         = bg_input;
    c[ImGuiCol_ScrollbarGrabHovered]  = bg_input_h;
    c[ImGuiCol_ScrollbarGrabActive]   = bg_input_a;

    c[ImGuiCol_CheckMark]             = accent;
    c[ImGuiCol_SliderGrab]            = accent;
    c[ImGuiCol_SliderGrabActive]      = accent_a;

    c[ImGuiCol_Button]                = bg_input;
    c[ImGuiCol_ButtonHovered]         = bg_input_h;
    c[ImGuiCol_ButtonActive]          = accent;

    c[ImGuiCol_Header]                = bg_input;
    c[ImGuiCol_HeaderHovered]         = bg_input_h;
    c[ImGuiCol_HeaderActive]          = accent;

    c[ImGuiCol_Separator]             = border;
    c[ImGuiCol_SeparatorHovered]      = accent_h;
    c[ImGuiCol_SeparatorActive]       = accent;

    c[ImGuiCol_ResizeGrip]            = accent_dim;
    c[ImGuiCol_ResizeGripHovered]     = ImVec4(accent.x, accent.y, accent.z, 0.6f);
    c[ImGuiCol_ResizeGripActive]      = accent;

    c[ImGuiCol_InputTextCursor]       = text_pri;

    // Docked panels' tabs read as title bars: a deeper-blue selected
    // background with a bright accent overline gives the active panel
    // a clear "this one is focused" identity without making the whole
    // tab strip vivid blue.
    c[ImGuiCol_Tab]                   = RGB(0x1B, 0x1B, 0x20);
    c[ImGuiCol_TabHovered]            = RGB(0x2D, 0x2D, 0x34);
    c[ImGuiCol_TabSelected]           = accent_deep;
    c[ImGuiCol_TabSelectedOverline]   = accent_h;
    c[ImGuiCol_TabDimmed]             = bg_chrome;
    c[ImGuiCol_TabDimmedSelected]     = RGB(0x22, 0x2A, 0x33);
    c[ImGuiCol_TabDimmedSelectedOverline] = border_lt;

    c[ImGuiCol_DockingPreview]        = accent_dim;
    c[ImGuiCol_DockingEmptyBg]        = ImVec4(0, 0, 0, 0);

    c[ImGuiCol_PlotLines]             = text_sec;
    c[ImGuiCol_PlotLinesHovered]      = accent_h;
    c[ImGuiCol_PlotHistogram]         = accent;
    c[ImGuiCol_PlotHistogramHovered]  = accent_h;

    c[ImGuiCol_TableHeaderBg]         = bg_chrome;
    c[ImGuiCol_TableBorderStrong]     = border;
    c[ImGuiCol_TableBorderLight]      = border_lt;
    c[ImGuiCol_TableRowBg]            = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_TableRowBgAlt]         = ImVec4(1, 1, 1, 0.02f);

    c[ImGuiCol_TextSelectedBg]        = ImVec4(accent.x, accent.y, accent.z, 0.4f);
    c[ImGuiCol_DragDropTarget]        = accent_h;

    c[ImGuiCol_NavCursor]             = accent;
    c[ImGuiCol_NavWindowingHighlight] = ImVec4(1, 1, 1, 0.6f);
    c[ImGuiCol_NavWindowingDimBg]     = ImVec4(0, 0, 0, 0.4f);
    c[ImGuiCol_ModalWindowDimBg]      = ImVec4(0, 0, 0, 0.55f);
}

}  // namespace macvoxel
