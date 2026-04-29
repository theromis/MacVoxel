#import "VoxelView.h"

#import <Metal/Metal.h>
#import <cstdio>

#include "imgui.h"
#include "imgui_impl_metal.h"
#include "imgui_impl_osx.h"

#include "ui/HelloPanel.h"

@implementation VoxelView {
    id<MTLCommandQueue> _commandQueue;
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
    self.depthStencilPixelFormat = MTLPixelFormatInvalid;
    self.sampleCount = 1;
    self.clearColor = MTLClearColorMake(0.118, 0.118, 0.18, 1.0);  // ~ #1e1e2e

    self.preferredFramesPerSecond = 60;
    self.paused = NO;
    self.enableSetNeedsDisplay = NO;

    self.delegate = self;

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

    macvoxel::DrawHelloPanel();

    ImGui::Render();

    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
    cmd.label = @"MacVoxel Frame";

    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    enc.label = @"MacVoxel ImGui";
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

@end
