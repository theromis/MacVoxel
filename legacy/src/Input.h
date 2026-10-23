#pragma once

#include <simd/simd.h>

namespace macvoxel {

// AppKit-free modifier-flags packaging. VoxelView decodes
// NSEventModifierFlags at the NSEvent boundary and packs them here.
struct ModifierFlags {
    bool option = false;
    bool command = false;
    bool shift = false;
    bool control = false;
};

// AppKit-free mouse event. Built once in VoxelView's NSEvent
// handlers from the source NSEvent and passed to per-tool gesture
// controllers — they never see NSEvent / CGPoint / NSWindow.
//
// Both window and view-local pixel coordinates are carried so
// callers can pick the space they need without re-doing the
// conversion. window is the raw NSWindow point, local is what
// `[NSView convertPoint:fromView:nil]` returns (origin at the
// view's bottom-left, units in pixels up to viewport_w/h).
struct MouseEvent {
    simd::float2 window{0.0f, 0.0f};
    simd::float2 local{0.0f, 0.0f};
    ModifierFlags mods;
};

}  // namespace macvoxel
