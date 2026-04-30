#import "VoxelView.h"

#import "AppDelegate.h"
#import "VoxelRenderer.h"

#import <Metal/Metal.h>
#import <cstdio>
#include <algorithm>

#include "imgui.h"
#include "imgui_impl_metal.h"
#include "imgui_impl_osx.h"

#include "Camera.h"
#include "Document.h"
#include "Raycast.h"
#include "ui/ModelPanel.h"

namespace {
enum class DragMode { None, Orbit, Pan };
enum class EditAction { Place, Erase };
}

@implementation VoxelView {
    id<MTLCommandQueue> _commandQueue;
    VoxelRenderer* _voxelRenderer;
    macvoxel::Camera _camera;
    uint64_t _lastDocVersion;
    DragMode _dragMode;
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

    _voxelRenderer = [[VoxelRenderer alloc] initWithDevice:device
                                               colorFormat:self.colorPixelFormat
                                               depthFormat:self.depthStencilPixelFormat];
    if (_voxelRenderer == nil) {
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
        if (doc->version != _lastDocVersion) {
            _lastDocVersion = doc->version;
            const macvoxel::Bounds3 b = doc->grid.Bounds();
            const int32_t maxExtent = std::max({b.size_x(), b.size_y(), b.size_z()});
            _camera.Frame(static_cast<float>(maxExtent));
        }
        macvoxel::RenderStats stats;
        stats.vertex_count = [_voxelRenderer lastVertexCount];
        stats.index_count = [_voxelRenderer lastIndexCount];
        stats.quad_count = [_voxelRenderer lastQuadCount];
        macvoxel::DrawModelPanel(*doc, stats);
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

    [_voxelRenderer encodeWithEncoder:enc
                                 view:viewMat
                           projection:projMat
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
    } else {
        _dragMode = DragMode::None;
        const EditAction action = hasCommand ? EditAction::Erase : EditAction::Place;
        [self performEditAtPoint:event.locationInWindow action:action];
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
        case DragMode::None:  break;
    }
}

- (void)mouseUp:(NSEvent*)__unused event {
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

    // World -> grid: invert the renderer's transform
    //   world = (gx, gz, -gy) - center
    // i.e. add center, then apply R^-1 = (wx, -wz, wy).
    const macvoxel::Bounds3 b = doc->grid.Bounds();
    const simd::float3 center = b.empty()
        ? simd::float3{0.0f, 0.0f, 0.0f}
        : simd::float3{
            (static_cast<float>(b.min_x) + static_cast<float>(b.max_x) + 1.0f) * 0.5f,
            (static_cast<float>(b.min_z) + static_cast<float>(b.max_z) + 1.0f) * 0.5f,
            -(static_cast<float>(b.min_y) + static_cast<float>(b.max_y) + 1.0f) * 0.5f,
          };
    const simd::float3 oc = ray_origin_world + center;
    const simd::float3 ray_origin_grid{oc.x, -oc.z, oc.y};
    const simd::float3 ray_dir_grid{ray_dir_world.x, -ray_dir_world.z, ray_dir_world.y};

    macvoxel::RayHit hit;
    if (!macvoxel::Raycast(doc->grid, ray_origin_grid, ray_dir_grid, 4096.0f, &hit)) {
        return;
    }

    if (action == EditAction::Place) {
        if (hit.axis < 0) return;  // started inside a voxel — no neighbor face
        int dx = 0, dy = 0, dz = 0;
        if (hit.axis == 0) dx = hit.sign;
        else if (hit.axis == 1) dy = hit.sign;
        else if (hit.axis == 2) dz = hit.sign;
        // Phase 5.1: hardcoded palette index 1 ("white") until ToolPanel lands.
        doc->grid.Set(hit.x + dx, hit.y + dy, hit.z + dz, 1);
        ++doc->version;
    } else {
        doc->grid.Set(hit.x, hit.y, hit.z, 0);
        ++doc->version;
    }
}

@end
