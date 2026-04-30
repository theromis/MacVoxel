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
#include "ui/ModelPanel.h"

namespace {
enum class DragMode { None, Orbit, Pan };
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
// Camera input — gated on ImGui's WantCaptureMouse so dragging inside an
// ImGui window never moves the scene camera.
//
// Mapping:
//   Option + drag         -> Orbit
//   Option + Shift + drag -> Pan
//   Scroll / pinch        -> Zoom
//
// Bare left-drag is intentionally unbound; reserved for the future
// voxel-placement tool (Phase 5+).
// ---------------------------------------------------------------------------

- (void)mouseDown:(NSEvent*)event {
    if (ImGui::GetIO().WantCaptureMouse) {
        _dragMode = DragMode::None;
        return;
    }
    const NSEventModifierFlags m = event.modifierFlags;
    const BOOL hasOption = (m & NSEventModifierFlagOption) != 0;
    const BOOL hasShift = (m & NSEventModifierFlagShift) != 0;
    if (hasOption && hasShift) {
        _dragMode = DragMode::Pan;
    } else if (hasOption) {
        _dragMode = DragMode::Orbit;
    } else {
        _dragMode = DragMode::None;
    }
    _lastDragLocation = event.locationInWindow;
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

@end
