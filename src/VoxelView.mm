#import "VoxelView.h"

#import "AppDelegate.h"
#import "RaycastRenderer.h"

#import <Metal/Metal.h>
#import <cstdio>
#include <algorithm>

#include "imgui.h"
#include "imgui_impl_metal.h"
#include "imgui_impl_osx.h"

#include "Camera.h"
#include "Document.h"
#include "EditHistory.h"
#include "Raycast.h"
#include "Selection.h"
#include "ToolState.h"
#include "ui/ModelPanel.h"
#include "ui/ToolPanel.h"

namespace {
enum class DragMode { None, Orbit, Pan, Paint, Select };
enum class EditAction { Place, Erase };

struct Vec3i { int32_t x, y, z; };
}

@implementation VoxelView {
    id<MTLCommandQueue> _commandQueue;
    RaycastRenderer* _raycastRenderer;
    macvoxel::Camera _camera;
    DragMode _dragMode;
    EditAction _paintAction;
    Vec3i _selectionAnchor;
    NSPoint _lastDragLocation;
    BOOL _imguiAlive;
}

- (instancetype)initWithFrame:(NSRect)frame {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) {
        fprintf(stderr, "MacVoxel: no Metal-capable device available\n");
        return nil;
    }

    self = [super initWithFrame:frame device:device];
    if (self == nil) {
        return nil;
    }

    _commandQueue = [device newCommandQueue];

    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    self.sampleCount = 1;
    self.clearColor = MTLClearColorMake(0.118, 0.118, 0.18, 1.0);  // ~ #1e1e2e
    self.clearDepth = 1.0;

    self.preferredFramesPerSecond = 60;
    self.paused = NO;
    self.enableSetNeedsDisplay = NO;

    self.delegate = self;

    _raycastRenderer = [[RaycastRenderer alloc] initWithDevice:device
                                                   colorFormat:self.colorPixelFormat
                                                   depthFormat:self.depthStencilPixelFormat];
    if (_raycastRenderer == nil) {
        return nil;
    }

    [self setupImGuiWithDevice:device];
    return self;
}

// ---------------------------------------------------------------------------
// ImGui lifecycle
// ---------------------------------------------------------------------------

- (void)setupImGuiWithDevice:(id<MTLDevice>)device {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();

    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
    // Multi-viewport is intentionally off for Phase 0 — single-window shell only.
    io.IniFilename = nullptr;  // no imgui.ini file in CWD

    ImGui::StyleColorsDark();

    // Load San Francisco from /System (Apple's license forbids bundling SF).
    // Render at 2x and scale down for crisp glyphs on Retina.
    {
        const char* sf_path = "/System/Library/Fonts/SFNS.ttf";
        const float font_size_pt = 13.0f;
        const float oversample = 2.0f;
        ImFont* font = io.Fonts->AddFontFromFileTTF(sf_path, font_size_pt * oversample);
        if (font == nullptr) {
            fprintf(stderr,
                    "MacVoxel: failed to load %s, falling back to ImGui default\n",
                    sf_path);
            io.Fonts->AddFontDefault();
        }
        io.FontGlobalScale = 1.0f / oversample;
    }

    ImGui_ImplMetal_Init(device);
    ImGui_ImplOSX_Init(self);
    _imguiAlive = YES;
}

- (void)shutdownImGui {
    if (!_imguiAlive) {
        return;
    }
    _imguiAlive = NO;
    ImGui_ImplMetal_Shutdown();
    ImGui_ImplOSX_Shutdown();
    ImGui::DestroyContext();
}

- (void)dealloc {
    [self shutdownImGui];
}

- (void)frameCameraToDocument {
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) return;
    const macvoxel::Bounds3 b = doc->grid.Bounds();
    const int32_t maxExtent = std::max({b.size_x(), b.size_y(), b.size_z()});
    // World position of the bounds midpoint (apply the same rotation the
    // renderer does: world = (gx, gz, -gy)).
    simd::float3 target_world{0.0f, 0.0f, 0.0f};
    if (!b.empty()) {
        const float gcx = (static_cast<float>(b.min_x) +
                           static_cast<float>(b.max_x) + 1.0f) * 0.5f;
        const float gcy = (static_cast<float>(b.min_y) +
                           static_cast<float>(b.max_y) + 1.0f) * 0.5f;
        const float gcz = (static_cast<float>(b.min_z) +
                           static_cast<float>(b.max_z) + 1.0f) * 0.5f;
        target_world = simd::float3{gcx, gcz, -gcy};
    }
    _camera.Frame(target_world, static_cast<float>(maxExtent));
}

// ---------------------------------------------------------------------------
// MTKViewDelegate
// ---------------------------------------------------------------------------

- (void)mtkView:(MTKView*)__unused view drawableSizeWillChange:(CGSize)__unused size {
    // No-op; ImGui reads DisplaySize each frame.
}

- (void)drawInMTKView:(MTKView*)view {
    MTLRenderPassDescriptor* pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (pass == nil || drawable == nil) {
        return;
    }

    // Update ImGui display metrics each frame (handles resize and screen changes).
    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize.x = static_cast<float>(view.bounds.size.width);
    io.DisplaySize.y = static_cast<float>(view.bounds.size.height);

    CGFloat scale = view.window.screen.backingScaleFactor;
    if (scale <= 0.0) {
        scale = NSScreen.mainScreen.backingScaleFactor;
    }
    io.DisplayFramebufferScale = ImVec2(static_cast<float>(scale), static_cast<float>(scale));

    ImGui_ImplMetal_NewFrame(pass);
    ImGui_ImplOSX_NewFrame(self);
    ImGui::NewFrame();

    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc != nullptr) {
        macvoxel::RenderStats stats;
        stats.chunk_count = [_raycastRenderer lastChunkCount];
        stats.gpu_bytes = [_raycastRenderer lastGPUBytes];
        macvoxel::DrawModelPanel(*doc, stats);
        macvoxel::DrawToolPanel();
        [self drawSelectionOverlay];
    }

    ImGui::Render();

    // Aspect from drawableSize (pixels) is robust against mid-frame resizes.
    const CGSize ds = view.drawableSize;
    const float aspect = ds.height > 0 ? static_cast<float>(ds.width / ds.height) : 1.0f;
    const simd::float4x4 viewMat = _camera.ViewMatrix();
    const simd::float4x4 projMat = _camera.ProjectionMatrix(aspect);

    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
    cmd.label = @"MacVoxel Frame";

    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    enc.label = @"MacVoxel Pass";

    [_raycastRenderer encodeWithEncoder:enc
                                   view:viewMat
                             projection:projMat
                            cameraWorld:_camera.Position()
                               document:doc];

    [enc pushDebugGroup:@"Dear ImGui rendering"];
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cmd, enc);
    [enc popDebugGroup];
    [enc endEncoding];

    [cmd presentDrawable:drawable];
    [cmd commit];
}

// ---------------------------------------------------------------------------
// First responder — without this, the view never receives keyboard events
// and ImGui's text input / shortcuts go nowhere.
// ---------------------------------------------------------------------------

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)__unused event {
    return YES;
}

// ---------------------------------------------------------------------------
// Mouse input — gated on ImGui's WantCaptureMouse so dragging inside an
// ImGui window never moves the camera or edits the scene.
//
// Mapping:
//   Option + drag           -> Orbit
//   Option + Shift + drag   -> Pan
//   Scroll / pinch          -> Zoom
//   Bare left-click         -> Place voxel adjacent to picked face
//   Cmd  + left-click       -> Erase picked voxel
// ---------------------------------------------------------------------------

- (void)mouseDown:(NSEvent*)event {
    if (ImGui::GetIO().WantCaptureMouse) {
        _dragMode = DragMode::None;
        return;
    }
    const NSEventModifierFlags m = event.modifierFlags;
    const BOOL hasOption = (m & NSEventModifierFlagOption) != 0;
    const BOOL hasShift = (m & NSEventModifierFlagShift) != 0;
    const BOOL hasCommand = (m & NSEventModifierFlagCommand) != 0;
    if (hasOption && hasShift) {
        _dragMode = DragMode::Pan;
        _lastDragLocation = event.locationInWindow;
    } else if (hasOption) {
        _dragMode = DragMode::Orbit;
        _lastDragLocation = event.locationInWindow;
    } else if (macvoxel::CurrentTool().tool == macvoxel::ToolKind::Select) {
        _dragMode = DragMode::Select;
        Vec3i pick;
        if ([self pickGridCellAtPoint:event.locationInWindow into:&pick]) {
            _selectionAnchor = pick;
            macvoxel::Selection& sel = macvoxel::CurrentSelection();
            sel.box.min_x = sel.box.max_x = pick.x;
            sel.box.min_y = sel.box.max_y = pick.y;
            sel.box.min_z = sel.box.max_z = pick.z;
            sel.active = true;
        } else {
            _dragMode = DragMode::None;
        }
    } else {
        _dragMode = DragMode::Paint;
        _paintAction = hasCommand ? EditAction::Erase : EditAction::Place;
        macvoxel::CurrentHistory().BeginOp();
        [self performEditAtPoint:event.locationInWindow action:_paintAction];
    }
}

- (void)mouseDragged:(NSEvent*)event {
    if (_dragMode == DragMode::None) {
        return;
    }
    const NSPoint p = event.locationInWindow;
    const float dx = static_cast<float>(p.x - _lastDragLocation.x);
    const float dy = static_cast<float>(p.y - _lastDragLocation.y);
    _lastDragLocation = p;

    switch (_dragMode) {
        case DragMode::Orbit: _camera.Orbit(dx, dy); break;
        case DragMode::Pan:   _camera.Pan(dx, dy);   break;
        case DragMode::Paint: [self performEditAtPoint:p action:_paintAction]; break;
        case DragMode::Select: {
            Vec3i pick;
            if ([self pickGridCellAtPoint:p into:&pick]) {
                macvoxel::Selection& sel = macvoxel::CurrentSelection();
                sel.box.min_x = std::min(_selectionAnchor.x, pick.x);
                sel.box.min_y = std::min(_selectionAnchor.y, pick.y);
                sel.box.min_z = std::min(_selectionAnchor.z, pick.z);
                sel.box.max_x = std::max(_selectionAnchor.x, pick.x);
                sel.box.max_y = std::max(_selectionAnchor.y, pick.y);
                sel.box.max_z = std::max(_selectionAnchor.z, pick.z);
                sel.active = true;
            }
            break;
        }
        case DragMode::None:  break;
    }
}

- (void)mouseUp:(NSEvent*)__unused event {
    if (_dragMode == DragMode::Paint) {
        macvoxel::CurrentHistory().CommitOp();
    }
    _dragMode = DragMode::None;
}

- (void)scrollWheel:(NSEvent*)event {
    if (ImGui::GetIO().WantCaptureMouse) {
        return;
    }
    // scrollingDeltaY is preferred over deltaY for trackpads; positive when
    // the user scrolls upward in macOS natural-scroll mode.
    const float ticks = static_cast<float>(event.scrollingDeltaY) * 0.1f;
    _camera.Zoom(ticks);
}

- (void)magnifyWithEvent:(NSEvent*)event {
    if (ImGui::GetIO().WantCaptureMouse) {
        return;
    }
    // event.magnification is in [-1, 1] per gesture frame; scale so a typical
    // pinch sweep is comparable to a few scroll ticks.
    _camera.Zoom(static_cast<float>(event.magnification) * 8.0f);
}

// ---------------------------------------------------------------------------
// Picking: cast a ray from a window-space point and return the grid cell
// the user is targeting. Falls back to the ground plane (grid z=0) when
// the ray misses all voxels.
// ---------------------------------------------------------------------------

- (BOOL)pickGridCellAtPoint:(NSPoint)windowPoint into:(Vec3i*)outCell {
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) return NO;

    const NSPoint local = [self convertPoint:windowPoint fromView:nil];
    const float w = static_cast<float>(self.bounds.size.width);
    const float h = static_cast<float>(self.bounds.size.height);
    if (w <= 0.0f || h <= 0.0f) return NO;

    const float ndc_x = (static_cast<float>(local.x) / w) * 2.0f - 1.0f;
    const float ndc_y = (static_cast<float>(local.y) / h) * 2.0f - 1.0f;

    const float aspect = w / h;
    const simd::float4x4 vmat = _camera.ViewMatrix();
    const simd::float4x4 pmat = _camera.ProjectionMatrix(aspect);
    const simd::float4x4 inv_vp = simd_inverse(pmat * vmat);
    auto unproject = [&](float z) -> simd::float3 {
        simd::float4 clip{ndc_x, ndc_y, z, 1.0f};
        simd::float4 wh = simd_mul(inv_vp, clip);
        return simd::float3{wh.x / wh.w, wh.y / wh.w, wh.z / wh.w};
    };
    const simd::float3 near_world = unproject(0.0f);
    const simd::float3 far_world = unproject(1.0f);
    const simd::float3 ray_dir_world = simd::normalize(far_world - near_world);
    const simd::float3 ray_origin_world = _camera.Position();

    const simd::float3 ray_origin_grid{ray_origin_world.x,
                                       -ray_origin_world.z,
                                       ray_origin_world.y};
    const simd::float3 ray_dir_grid{ray_dir_world.x,
                                    -ray_dir_world.z,
                                    ray_dir_world.y};

    macvoxel::RayHit hit;
    if (macvoxel::Raycast(doc->grid, ray_origin_grid, ray_dir_grid, 4096.0f, &hit)) {
        outCell->x = hit.x;
        outCell->y = hit.y;
        outCell->z = hit.z;
        return YES;
    }
    if (std::abs(ray_dir_grid.z) < 1e-6f) return NO;
    const float t = -ray_origin_grid.z / ray_dir_grid.z;
    if (t < 0.0f || t > 4096.0f) return NO;
    outCell->x = static_cast<int32_t>(std::floor(ray_origin_grid.x + t * ray_dir_grid.x));
    outCell->y = static_cast<int32_t>(std::floor(ray_origin_grid.y + t * ray_dir_grid.y));
    outCell->z = 0;
    return YES;
}

// ---------------------------------------------------------------------------
// Selection overlay: project the 8 corners of the selection AABB to screen
// space and draw the 12 connecting edges via ImGui's background draw list,
// so it overlays the ray-cast scene but sits underneath ImGui panels.
// ---------------------------------------------------------------------------

- (void)drawSelectionOverlay {
    const macvoxel::Selection& sel = macvoxel::CurrentSelection();
    if (!sel.active || sel.box.empty()) return;

    const float w = static_cast<float>(self.bounds.size.width);
    const float h = static_cast<float>(self.bounds.size.height);
    if (w <= 0.0f || h <= 0.0f) return;
    const float aspect = w / h;
    const simd::float4x4 vp = _camera.ProjectionMatrix(aspect) * _camera.ViewMatrix();

    // Selection box in grid voxel coords; voxels span [c, c+1] so the
    // outer faces are at min .. max+1.
    const simd::float3 gmin{static_cast<float>(sel.box.min_x),
                            static_cast<float>(sel.box.min_y),
                            static_cast<float>(sel.box.min_z)};
    const simd::float3 gmax{static_cast<float>(sel.box.max_x + 1),
                            static_cast<float>(sel.box.max_y + 1),
                            static_cast<float>(sel.box.max_z + 1)};

    auto to_world = [](simd::float3 g) {
        // Same R = (gx, gz, -gy) the renderer applies.
        return simd::float3{g.x, g.z, -g.y};
    };

    simd::float3 corners_grid[8] = {
        {gmin.x, gmin.y, gmin.z}, {gmax.x, gmin.y, gmin.z},
        {gmax.x, gmax.y, gmin.z}, {gmin.x, gmax.y, gmin.z},
        {gmin.x, gmin.y, gmax.z}, {gmax.x, gmin.y, gmax.z},
        {gmax.x, gmax.y, gmax.z}, {gmin.x, gmax.y, gmax.z},
    };
    ImVec2 screen[8];
    bool valid[8];
    for (int i = 0; i < 8; ++i) {
        const simd::float3 wpos = to_world(corners_grid[i]);
        const simd::float4 clip = simd_mul(vp, simd::float4{wpos.x, wpos.y, wpos.z, 1.0f});
        valid[i] = clip.w > 0.001f;
        if (valid[i]) {
            const float ndc_x = clip.x / clip.w;
            const float ndc_y = clip.y / clip.w;
            screen[i].x = (ndc_x * 0.5f + 0.5f) * w;
            screen[i].y = (1.0f - (ndc_y * 0.5f + 0.5f)) * h;  // ImGui Y-down
        }
    }

    // 12 edges as pairs of corner indices.
    static const int kEdges[12][2] = {
        {0, 1}, {1, 2}, {2, 3}, {3, 0},  // bottom
        {4, 5}, {5, 6}, {6, 7}, {7, 4},  // top
        {0, 4}, {1, 5}, {2, 6}, {3, 7},  // verticals
    };
    ImDrawList* dl = ImGui::GetBackgroundDrawList();
    const ImU32 color = IM_COL32(255, 220, 80, 255);
    for (int i = 0; i < 12; ++i) {
        const int a = kEdges[i][0];
        const int b = kEdges[i][1];
        if (!valid[a] || !valid[b]) continue;
        dl->AddLine(screen[a], screen[b], color, 1.5f);
    }
}

// ---------------------------------------------------------------------------
// Editing — raycast a click into the grid, then place or erase.
// ---------------------------------------------------------------------------

- (void)performEditAtPoint:(NSPoint)windowPoint action:(EditAction)action {
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) return;

    const NSPoint local = [self convertPoint:windowPoint fromView:nil];
    const float w = static_cast<float>(self.bounds.size.width);
    const float h = static_cast<float>(self.bounds.size.height);
    if (w <= 0.0f || h <= 0.0f) return;

    // NDC: x, y in [-1, 1]. Cocoa Y-up matches Metal NDC y-up — no flip.
    const float ndc_x = (static_cast<float>(local.x) / w) * 2.0f - 1.0f;
    const float ndc_y = (static_cast<float>(local.y) / h) * 2.0f - 1.0f;

    // World-space ray through this NDC point: take inverse of the view-
    // projection matrix and unproject the near and far plane points.
    const float aspect = w / h;
    const simd::float4x4 vmat = _camera.ViewMatrix();
    const simd::float4x4 pmat = _camera.ProjectionMatrix(aspect);
    const simd::float4x4 vp = pmat * vmat;
    const simd::float4x4 inv_vp = simd_inverse(vp);

    auto unproject = [&](float z) -> simd::float3 {
        simd::float4 clip{ndc_x, ndc_y, z, 1.0f};
        simd::float4 wh = simd_mul(inv_vp, clip);
        return simd::float3{wh.x / wh.w, wh.y / wh.w, wh.z / wh.w};
    };
    const simd::float3 near_world = unproject(0.0f);  // Metal NDC near
    const simd::float3 far_world  = unproject(1.0f);  // Metal NDC far
    const simd::float3 ray_dir_world = simd::normalize(far_world - near_world);
    const simd::float3 ray_origin_world = _camera.Position();

    // World -> grid: invert the renderer's rotation R = (gx, gz, -gy).
    // R^-1 (wx, wy, wz) = (wx, -wz, wy). No translation now that the
    // renderer no longer centers the model on the world origin.
    const simd::float3 ray_origin_grid{ray_origin_world.x,
                                       -ray_origin_world.z,
                                       ray_origin_world.y};
    const simd::float3 ray_dir_grid{ray_dir_world.x,
                                    -ray_dir_world.z,
                                    ray_dir_world.y};

    macvoxel::ToolState& tool = macvoxel::CurrentTool();
    const int radius = std::max(1, tool.brush_radius);
    const int span = radius - 1;

    // Cmd+click forces erase regardless of selected tool — quick override
    // matching the Phase 5.1 behavior. Otherwise the tool drives.
    const macvoxel::ToolKind effective = action == EditAction::Erase
                                             ? macvoxel::ToolKind::Erase
                                             : tool.tool;

    macvoxel::RayHit hit;
    const bool hit_voxel = macvoxel::Raycast(doc->grid, ray_origin_grid,
                                             ray_dir_grid, 4096.0f, &hit);

    int target_x = 0;
    int target_y = 0;
    int target_z = 0;
    if (hit_voxel) {
        target_x = hit.x;
        target_y = hit.y;
        target_z = hit.z;
        if (effective == macvoxel::ToolKind::Place) {
            if (hit.axis < 0) return;  // ray started inside a voxel — no neighbor
            if (hit.axis == 0) target_x += hit.sign;
            else if (hit.axis == 1) target_y += hit.sign;
            else if (hit.axis == 2) target_z += hit.sign;
        }
    } else {
        // Empty-space click. Place falls back to the implicit ground plane
        // (grid z=0, matching MagicaVoxel's convention). Erase/Paint need a
        // real voxel to act on, so they no-op here.
        if (effective != macvoxel::ToolKind::Place) return;
        if (std::abs(ray_dir_grid.z) < 1e-6f) return;
        const float t = -ray_origin_grid.z / ray_dir_grid.z;
        if (t < 0.0f || t > 4096.0f) return;
        const float hx = ray_origin_grid.x + t * ray_dir_grid.x;
        const float hy = ray_origin_grid.y + t * ray_dir_grid.y;
        target_x = static_cast<int>(std::floor(hx));
        target_y = static_cast<int>(std::floor(hy));
        target_z = 0;
    }

    macvoxel::EditHistory& history = macvoxel::CurrentHistory();

    auto apply = [&](int x, int y, int z) {
        const uint8_t old_val = doc->grid.Get(x, y, z);
        uint8_t new_val = old_val;
        switch (effective) {
            case macvoxel::ToolKind::Place:
                new_val = tool.palette_idx;
                break;
            case macvoxel::ToolKind::Erase:
                new_val = 0;
                break;
            case macvoxel::ToolKind::Paint:
                if (old_val != 0) new_val = tool.palette_idx;
                break;
            case macvoxel::ToolKind::Select:
                return;  // Select tool doesn't edit cells; handled in mouseDown
        }
        if (new_val == old_val) return;
        doc->grid.Set(x, y, z, new_val);
        history.Record(x, y, z, old_val, new_val);
    };

    for (int dz = -span; dz <= span; ++dz) {
        for (int dy = -span; dy <= span; ++dy) {
            for (int dx = -span; dx <= span; ++dx) {
                apply(target_x + dx, target_y + dy, target_z + dz);
            }
        }
    }

    ++doc->version;
}

@end
