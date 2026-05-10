#import "VoxelView.h"

#import "AppDelegate.h"
#import "GeneratorEngine.h"
#import "PathTraceRenderer.h"
#import "RaycastRenderer.h"

#import <Metal/Metal.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <cstdio>
#include <algorithm>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "imgui.h"
#include "imgui_impl_metal.h"
#include "imgui_impl_osx.h"
#include "imgui_internal.h"  // DockBuilder API

#include "Camera.h"
#include "CellKey.h"
#include "Document.h"
#include "EditHistory.h"
#include "FloatingBuffer.h"
#include "FloatingBufferOps.h"
#include "BoxSelectController.h"
#include "BrushController.h"
#include "BrushOps.h"
#include "FaceController.h"
#include "GeneratorController.h"
#include "PreviewOps.h"
#include "ShapeController.h"
#include "EditorContext.h"
#include "FloodSelectController.h"
#include "GeneratorState.h"
#include "Input.h"
#include "InteractionState.h"
#include "MarqueeController.h"
#include "MoveSelectController.h"
#include "PreviewOverlay.h"
#include "Raycast.h"
#include "RenderState.h"
#include "Selection.h"
#include "SelectionOps.h"
#include "Shapes.h"
#include "ToolState.h"
#include "ViewContext.h"
#include "XformHandleController.h"
#include "ui/Fonts.h"
#include "ui/GeneratorPanel.h"
#include "ui/LightPanel.h"
#include "ui/ModelPanel.h"
#include "ui/PalettePanel.h"
#include "ui/RenderPanel.h"
#include "ui/SelectionPanel.h"
#include "ui/Theme.h"
#include "ui/ToolPanel.h"

namespace {
using DragMode = macvoxel::DragMode;

using Vec3i = macvoxel::shapes::Vec3i;

}  // namespace

@implementation VoxelView {
    // Editor context — non-owning pointer; AppDelegate owns the unique
    // instance. Set in initWithFrame: from [NSApp delegate].context;
    // valid for the view's lifetime since AppDelegate outlives it.
    macvoxel::EditorContext* _ctx;

    // Platform / lifetime — Metal queue, renderer references, ImGui /
    // tracking state. Kept on the view because they're tied to the
    // NSView/MTKView lifecycle, not to any modeling gesture.
    id<MTLCommandQueue> _commandQueue;
    RaycastRenderer* _raycastRenderer;
    PathTraceRenderer* _pathTraceRenderer;
    GeneratorEngine* _generatorEngine;
    macvoxel::Camera _camera;
    NSTrackingArea* _trackingArea;
    BOOL _imguiAlive;
    bool _wasPathTraced;
    // Tracks transitions for auto-committing the floating buffer:
    // switching tools / entering render mode / saving / opening etc.
    // are all "the user moved on" gestures, so we drop whatever's
    // floating before letting the new context see a stale buffer.
    macvoxel::ToolKind _lastToolForFB;
    bool _lastPathTracedForFB;

    // Modeling-side gesture state — drag mode + per-tool sub-structs.
    // See InteractionState.h for the breakdown.
    macvoxel::InteractionState _interaction;
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

    _ctx = [(AppDelegate*)[NSApp delegate] context];

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
    _pathTraceRenderer = [[PathTraceRenderer alloc] initWithDevice:device
                                                       colorFormat:self.colorPixelFormat];
    if (_pathTraceRenderer == nil) {
        return nil;
    }
    _generatorEngine = [[GeneratorEngine alloc] initWithDevice:device
                                                  commandQueue:_commandQueue];
    if (_generatorEngine == nil) {
        return nil;
    }
    _interaction.gen_gizmo.active_drag_face = -1;  // 0 means "the -X face" — explicit nil-state.

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

    // Persist panel positions / collapsed state across launches via
    // imgui.ini in ~/Library/Application Support/MacVoxel/. The string
    // backing io.IniFilename has to outlive ImGui's use of it; static
    // storage keeps it alive for the process lifetime.
    static std::string g_imgui_ini_path;
    if (g_imgui_ini_path.empty()) {
        NSArray<NSString*>* dirs = NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES);
        NSString* support = dirs.firstObject;
        if (support != nil) {
            NSString* appDir = [support stringByAppendingPathComponent:@"MacVoxel"];
            [[NSFileManager defaultManager] createDirectoryAtPath:appDir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
            NSString* ini = [appDir stringByAppendingPathComponent:@"imgui.ini"];
            g_imgui_ini_path = [ini UTF8String];
        }
    }
    io.IniFilename = g_imgui_ini_path.empty() ? nullptr : g_imgui_ini_path.c_str();

    macvoxel::ApplyProTheme();

    // Load San Francisco from /System (Apple's license forbids bundling SF).
    // Render at 2x and scale down for crisp glyphs on Retina. SFNS.ttf is a
    // variable-weight font but stb_truetype loads its default cut; we fake
    // a heavier display weight with RasterizerMultiply for section headers.
    {
        const char* sf_path = "/System/Library/Fonts/SFNS.ttf";
        const float oversample = 2.0f;
        const float body_pt = 13.0f;
        const float header_pt = 15.0f;

        macvoxel::AppFonts& fonts = macvoxel::Fonts();

        // Static ranges array because ImGui retains the pointer across
        // baking. Used by both body and header merges below.
        static const ImWchar kIconRanges[] = {0xF000, 0xF0FF, 0};
        NSString* icon_path = [[NSBundle mainBundle]
                                  pathForResource:@"SF-Symbols-Export"
                                           ofType:@"ttf"];

        // MergeMode merges into the *previously-added* font, so each
        // base font that should carry icons needs its own merge call
        // right after. Without this, icons silently disappear from the
        // font you're rendering with and labels show U+FFFD boxes.
        auto merge_icons_into_previous = [&](float size_px) {
            if (icon_path == nil) return;
            ImFontConfig cfg;
            cfg.MergeMode = true;
            cfg.PixelSnapH = true;
            cfg.GlyphOffset = ImVec2(0.0f, 1.0f);
            cfg.GlyphMinAdvanceX = size_px;
            io.Fonts->AddFontFromFileTTF([icon_path UTF8String], size_px,
                                         &cfg, kIconRanges);
        };

        ImFontConfig body_cfg;
        body_cfg.RasterizerMultiply = 1.18f;  // a touch heavier than regular
        fonts.body = io.Fonts->AddFontFromFileTTF(sf_path, body_pt * oversample,
                                                  &body_cfg);
        merge_icons_into_previous(body_pt * oversample);

        ImFontConfig header_cfg;
        header_cfg.RasterizerMultiply = 1.45f;  // synthetic "bold" for headers
        fonts.header = io.Fonts->AddFontFromFileTTF(sf_path, header_pt * oversample,
                                                    &header_cfg);
        merge_icons_into_previous(header_pt * oversample);

        if (fonts.body == nullptr) {
            fprintf(stderr,
                    "MacVoxel: failed to load %s, falling back to ImGui default\n",
                    sf_path);
            fonts.body = io.Fonts->AddFontDefault();
            fonts.header = fonts.body;
        }
        if (icon_path == nil) {
            fprintf(stderr,
                    "MacVoxel: SF-Symbols-Export.ttf not found in bundle, "
                    "icons will render as missing-glyph boxes\n");
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
// Dockspace: an invisible fullscreen host window whose central node is
// passthrough so the ray-cast scene shows through the empty middle, and
// whose left and right margins are docked with our panels. On first run
// (or after the user deletes imgui.ini) we lay out a default split; on
// subsequent runs ImGui restores whatever the user dragged into place.
// ---------------------------------------------------------------------------

- (void)setupDockspace {
    ImGuiViewport* vp = ImGui::GetMainViewport();
    ImGui::SetNextWindowPos(vp->WorkPos);
    ImGui::SetNextWindowSize(vp->WorkSize);
    ImGui::SetNextWindowViewport(vp->ID);

    const ImGuiWindowFlags host_flags =
        ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoCollapse |
        ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove |
        ImGuiWindowFlags_NoBringToFrontOnFocus | ImGuiWindowFlags_NoNavFocus |
        ImGuiWindowFlags_NoBackground | ImGuiWindowFlags_NoDocking;

    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
    ImGui::Begin("##DockHost", nullptr, host_flags);
    ImGui::PopStyleVar(3);

    const ImGuiID dock_id = ImGui::GetID("MacVoxelDock");
    ImGui::DockSpace(dock_id, ImVec2(0.0f, 0.0f),
                     ImGuiDockNodeFlags_PassthruCentralNode);

    static bool layout_built = false;
    if (!layout_built) {
        layout_built = true;
        ImGuiDockNode* node = ImGui::DockBuilderGetNode(dock_id);
        // Build defaults only on the first launch ever (or after the user
        // deletes imgui.ini). If the saved ini already split the dockspace
        // into children, leave the user's layout alone.
        const bool fresh = (node == nullptr) ||
                           (node->IsLeafNode() && node->Windows.Size == 0);
        if (fresh) {
            ImGui::DockBuilderRemoveNode(dock_id);
            ImGui::DockBuilderAddNode(dock_id,
                                      ImGuiDockNodeFlags_PassthruCentralNode |
                                          ImGuiDockNodeFlags_DockSpace);
            ImGui::DockBuilderSetNodeSize(dock_id, vp->WorkSize);

            ImGuiID center = dock_id;
            ImGuiID left, right;
            ImGui::DockBuilderSplitNode(center, ImGuiDir_Left, 0.22f,
                                        &left, &center);
            ImGui::DockBuilderSplitNode(center, ImGuiDir_Right, 0.22f,
                                        &right, &center);

            // Tool on top (small), Palette below (bigger — swatch grid +
            // material editor want the room).
            ImGuiID left_top, left_bottom;
            ImGui::DockBuilderSplitNode(left, ImGuiDir_Up, 0.30f,
                                        &left_top, &left_bottom);

            // Right column: Model on top (read-only stats), Render
            // below (interactive controls).
            ImGuiID right_top, right_bottom;
            ImGui::DockBuilderSplitNode(right, ImGuiDir_Up, 0.40f,
                                        &right_top, &right_bottom);

            ImGui::DockBuilderDockWindow("Tool", left_top);
            ImGui::DockBuilderDockWindow("Generators", left_top);  // tab w/ Tool
            ImGui::DockBuilderDockWindow("Palette", left_bottom);
            ImGui::DockBuilderDockWindow("Model", right_top);
            ImGui::DockBuilderDockWindow("Render", right_bottom);
            ImGui::DockBuilderDockWindow("Light", right_bottom);   // tab w/ Render
            ImGui::DockBuilderFinish(dock_id);
        }
    }

    ImGui::End();
}

- (void)frameCameraToDocument {
    macvoxel::Document* doc = &_ctx->document;
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

- (void)invalidateRenderers {
    [_raycastRenderer invalidate];
    [_pathTraceRenderer invalidate];
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

    // Cancel a pending shape anchor on Escape or when the user switches
    // tools mid-stroke. ImGui owns keyDown via its hidden KeyEventResponder,
    // so we read the IO-level state instead of overriding -keyDown:.
    // Clearing _interaction.drag_mode too means the upcoming mouseUp won't try to
    // commit the (now anchor-less) shape.
    if (_interaction.anchor.has_anchor) {
        if (_ctx->tool.tool != _interaction.anchor.tool ||
            ImGui::IsKeyPressed(ImGuiKey_Escape, false)) {
            if (_interaction.drag_mode == DragMode::Shape) {
                // Cancel = drop the overlay. The doc was never touched
                // during the preview gesture.
                _ctx->preview.Clear();
                _interaction.drag_mode = DragMode::None;
            }
            _interaction.anchor.has_anchor = NO;
            _interaction.face.seed_cells.clear();
        }
    }

    // Generator gizmo per-frame tick: Esc / tool-switch cancellation
    // and dirty-detection that re-runs the engine on bounds / kind /
    // params / palette changes.
    macvoxel::generator_controller::Tick(
        *_ctx, _interaction, _ctx->tool.tool,
        ImGui::IsKeyPressed(ImGuiKey_Escape, false),
        [self generateFn]);

    [self setupDockspace];

    macvoxel::Document* doc = &_ctx->document;
    if (doc != nullptr) {
        // Auto-commit the floating buffer on "the user moved on"
        // gestures. Tool switch + render-mode toggle are the ones
        // we can detect from the per-frame draw; mouseDown handles
        // "user clicked with a non-move gesture", and AppDelegate
        // handles save / open / new / deselect.
        macvoxel::FloatingBuffer& fb_t = _ctx->floating_buffer;
        const macvoxel::ToolKind cur_tool = _ctx->tool.tool;
        const bool cur_pt = _ctx->render_settings.path_traced;
        if (fb_t.active) {
            if (cur_tool != _lastToolForFB ||
                (cur_pt && !_lastPathTracedForFB)) {
                macvoxel::CommitFloatingBuffer(*_ctx);
            }
        }
        _lastToolForFB = cur_tool;
        _lastPathTracedForFB = cur_pt;

        macvoxel::RenderStats stats;
        stats.chunk_count = [_raycastRenderer lastChunkCount];
        stats.gpu_bytes = [_raycastRenderer lastGPUBytes];
        macvoxel::DrawModelPanel(*_ctx, stats);
        macvoxel::DrawRenderPanel(*_ctx, stats);
        macvoxel::DrawLightPanel(*_ctx);
        macvoxel::DrawToolPanel(*_ctx);
        macvoxel::DrawGeneratorPanel(*_ctx);
        macvoxel::DrawSelectionPanel(*_ctx);
        macvoxel::DrawPalettePanel(*_ctx);
        [self drawSelectionOverlay];
        macvoxel::xform_handle_controller::DrawOverlay(
            _interaction, [self viewContext]);
        macvoxel::marquee_controller::DrawOverlay(_interaction, [self viewContext]);
        [self drawHoverOverlay];
        macvoxel::generator_controller::DrawOverlay(
            _interaction, [self viewContext]);

        if (macvoxel::ConsumeSaveRenderClick(*_ctx)) {
            [self runSaveRenderPanel];
        }
    }

    ImGui::Render();

    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
    cmd.label = @"MacVoxel Frame";

    const bool pt_now = _ctx->render_settings.path_traced;
    if (pt_now != _wasPathTraced) {
        // Toggling either direction invalidates whatever the path tracer
        // had accumulated (or wants to start fresh on enable).
        [_pathTraceRenderer invalidate];
        _wasPathTraced = pt_now;
    }

    if (pt_now) {
        // Path-traced: PathTraceRenderer handles its own accumulation +
        // display passes. ImGui draws on top into a follow-up encoder
        // sharing the same drawable's render-pass descriptor.
        [_pathTraceRenderer renderInView:view
                                     cmd:cmd
                                 context:_ctx
                                  camera:_camera];

        MTLRenderPassDescriptor* imguiPass =
            [MTLRenderPassDescriptor renderPassDescriptor];
        imguiPass.colorAttachments[0].texture = drawable.texture;
        imguiPass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        imguiPass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc =
            [cmd renderCommandEncoderWithDescriptor:imguiPass];
        enc.label = @"ImGui (over PT)";
        ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cmd, enc);
        [enc endEncoding];
    } else {
        // Realtime ray-cast renderer + ImGui share one render encoder.
        const CGSize ds = view.drawableSize;
        const float aspect = ds.height > 0
                                 ? static_cast<float>(ds.width / ds.height)
                                 : 1.0f;
        const simd::float4x4 viewMat = _camera.ViewMatrix();
        const simd::float4x4 projMat = _camera.ProjectionMatrix(aspect);

        id<MTLRenderCommandEncoder> enc =
            [cmd renderCommandEncoderWithDescriptor:pass];
        enc.label = @"MacVoxel Pass";
        [_raycastRenderer encodeWithEncoder:enc
                                       view:viewMat
                                 projection:projMat
                                cameraWorld:_camera.Position()
                                    context:_ctx];
        [enc pushDebugGroup:@"Dear ImGui rendering"];
        ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cmd, enc);
        [enc popDebugGroup];
        [enc endEncoding];
    }

    [cmd presentDrawable:drawable];
    [cmd commit];
}

// ---------------------------------------------------------------------------
// First responder — return NO so AppKit doesn't promote VoxelView to first
// responder when the user clicks on it. ImGui's OSX backend installs a
// hidden KeyEventResponder NSView during ImGui_ImplOSX_Init that needs to
// remain first responder so keyDown events get absorbed and routed through
// interpretKeyEvents: into ImGui's text input. Mouse events still reach
// us regardless of responder status (they route to the view under the
// cursor), and menu shortcuts route through the responder chain via
// target=nil so they fall through to AppDelegate as before.
// ---------------------------------------------------------------------------

- (BOOL)acceptsFirstResponder {
    return NO;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)__unused event {
    return YES;
}

// Absorb keys we use as drag modifiers so they don't continue up the
// responder chain to NSApplication.noResponderFor: — which beeps for
// every keyDown that nobody handled. (Space is held to enable pan;
// without this override, every key-repeat tick beeps.) ImGui sees the
// key independently via its local event monitor, which fires before
// the responder chain, so [self mouseDown:]'s ImGui::IsKeyDown(Space)
// check stays correct.
//
// Reached via NSResponder.noResponderFor: bouncing from the
// KeyEventResponder's [super keyDown:] up through nextResponder. Any
// key we don't claim falls through to super, preserving normal
// responder-chain walking for menu shortcuts etc.
- (void)keyDown:(NSEvent*)event {
    constexpr unsigned short kKeyCodeSpace = 49;  // kVK_Space (HIToolbox)
    if (event.keyCode == kKeyCodeSpace) return;
    [super keyDown:event];
}

// Re-register the tracking area whenever the view's bounds change so
// mouseMoved fires for hover highlight.
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea != nil) {
        [self removeTrackingArea:_trackingArea];
    }
    const NSTrackingAreaOptions opts = NSTrackingMouseMoved
                                     | NSTrackingMouseEnteredAndExited
                                     | NSTrackingActiveInKeyWindow
                                     | NSTrackingInVisibleRect;
    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                  options:opts
                                                    owner:self
                                                 userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseMoved:(NSEvent*)event {
    _interaction.hover.local = [self localFromWindow:event.locationInWindow];
    _interaction.hover.has_point = YES;
}

- (void)mouseExited:(NSEvent*)__unused event {
    _interaction.hover.has_point = NO;
}

- (void)runSaveRenderPanel {
    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.title = @"Save render";
    panel.allowedContentTypes = @[ UTTypePNG ];
    panel.nameFieldStringValue = @"render.png";
    panel.canCreateDirectories = YES;

    PathTraceRenderer* renderer = _pathTraceRenderer;
    id<MTLCommandQueue> queue = _commandQueue;
    const BOOL aces = _ctx->render_settings.aces_tonemap ? YES : NO;
    [panel beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        NSURL* url = panel.URL;
        if (url == nil) return;
        NSError* err = nil;
        if (![renderer exportPNGToURL:url
                          acesTonemap:aces
                         commandQueue:queue
                                error:&err]) {
            NSAlert* alert = [[NSAlert alloc] init];
            alert.messageText = @"Couldn't save render";
            alert.informativeText = err.localizedDescription != nil
                ? err.localizedDescription
                : @"Unknown error.";
            [alert runModal];
        }
    }];
}

// ---------------------------------------------------------------------------
// View-context + input helpers. ViewContext is built fresh per call —
// it owns nothing but a Camera-by-value and an EditorContext pointer,
// so the cost is two pointers and a struct copy. AppKit-aware
// translation (NSWindow → view-local) lives here; ViewContext sees
// only floats.
// ---------------------------------------------------------------------------
- (macvoxel::ViewContext)viewContext {
    return macvoxel::ViewContext{
        _camera,
        static_cast<float>(self.bounds.size.width),
        static_cast<float>(self.bounds.size.height),
        _ctx,
    };
}

- (simd::float2)localFromWindow:(NSPoint)windowPoint {
    const NSPoint p = [self convertPoint:windowPoint fromView:nil];
    return simd::float2{static_cast<float>(p.x), static_cast<float>(p.y)};
}

// Closure binding the Obj-C generator engine into the pure-C++
// signature GeneratorController expects. Built on demand at the
// call site; cheap (one block of captures + a vtable jump).
- (macvoxel::generator_controller::GenerateFn)generateFn {
    GeneratorEngine* engine = _generatorEngine;
    return [engine](macvoxel::generators::Kind kind,
                    macvoxel::generators::Bounds3i bounds,
                    macvoxel::generators::Params params,
                    std::vector<macvoxel::shapes::Vec3i>& out) {
        [engine generateInto:out kind:kind bounds:bounds params:params];
    };
}

- (macvoxel::MouseEvent)mouseEventFromNSEvent:(NSEvent*)event {
    const NSPoint w = event.locationInWindow;
    const simd::float2 local = [self localFromWindow:w];
    const NSEventModifierFlags m = event.modifierFlags;
    macvoxel::MouseEvent out;
    out.window = simd::float2{static_cast<float>(w.x), static_cast<float>(w.y)};
    out.local = local;
    out.mods.option  = (m & NSEventModifierFlagOption) != 0;
    out.mods.command = (m & NSEventModifierFlagCommand) != 0;
    out.mods.shift   = (m & NSEventModifierFlagShift) != 0;
    out.mods.control = (m & NSEventModifierFlagControl) != 0;
    return out;
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
        _interaction.drag_mode = DragMode::None;
        return;
    }
    const NSEventModifierFlags m = event.modifierFlags;
    const BOOL hasOption = (m & NSEventModifierFlagOption) != 0;
    const BOOL hasCommand = (m & NSEventModifierFlagCommand) != 0;
    // Option + left-click = eyedropper. Side-action only — doesn't
    // disturb anchor / gizmo / drag state, just updates the palette.
    if (hasOption) {
        [self eyedropperAtPoint:event.locationInWindow];
        _interaction.drag_mode = DragMode::None;
        return;
    }
    // Space + left-click = pan (the alt to middle-click on trackpads
    // and one-button mice). Camera orbit lives on right-click via
    // rightMouseDown:; pan also lives on otherMouseDown: (middle).
    if (ImGui::IsKeyDown(ImGuiKey_Space)) {
        _interaction.drag_mode = DragMode::Pan;
        _interaction.brush.last_drag_location = event.locationInWindow;
    } else if (_interaction.gen_gizmo.active) {
        macvoxel::generator_controller::OnGizmoClick(
            *_ctx, _interaction, [self viewContext],
            [self mouseEventFromNSEvent:event]);
    } else if (macvoxel::xform_handle_controller::OnMouseDown(
                   *_ctx, _interaction, [self viewContext],
                   [self mouseEventFromNSEvent:event])) {
        // Click on a transform-gizmo face arrow → scale the selection
        // (lifting it into a floating buffer first if needed). The
        // controller set _interaction.drag_mode on success.
    } else if (hasCommand &&
               (_ctx->tool.tool == macvoxel::ToolKind::Marquee ||
                _ctx->tool.tool == macvoxel::ToolKind::BoxSelect ||
                _ctx->tool.tool == macvoxel::ToolKind::FloodSelect) &&
               macvoxel::move_select_controller::OnMouseDown(
                   *_ctx, _interaction, [self viewContext],
                   [self mouseEventFromNSEvent:event])) {
        // Cmd-drag on a selected voxel takes over for the duration of
        // the gesture; the controller set _interaction.drag_mode on success.
    } else if (_ctx->tool.tool == macvoxel::ToolKind::Marquee) {
        [self autoCommitFloatingBuffer];
        macvoxel::marquee_controller::OnMouseDown(
            _interaction, [self mouseEventFromNSEvent:event]);
    } else if (_ctx->tool.tool == macvoxel::ToolKind::BoxSelect) {
        [self autoCommitFloatingBuffer];
        if (!macvoxel::box_select_controller::OnMouseDown(
                *_ctx, _interaction, [self viewContext],
                [self mouseEventFromNSEvent:event])) {
            _interaction.drag_mode = DragMode::None;
        }
    } else if (_ctx->tool.tool == macvoxel::ToolKind::FloodSelect) {
        [self autoCommitFloatingBuffer];
        macvoxel::flood_select_controller::OnMouseDown(
            *_ctx, [self viewContext], [self mouseEventFromNSEvent:event]);
        _interaction.drag_mode = DragMode::None;
    } else if (_ctx->tool.tool == macvoxel::ToolKind::Line ||
               _ctx->tool.tool == macvoxel::ToolKind::Circle ||
               _ctx->tool.tool == macvoxel::ToolKind::Square ||
               _ctx->tool.tool == macvoxel::ToolKind::Box) {
        [self autoCommitFloatingBuffer];
        const macvoxel::MouseEvent me = [self mouseEventFromNSEvent:event];
        if (macvoxel::shape_controller::OnMouseDown(
                *_ctx, _interaction, [self viewContext], me)) {
            // Track the cursor for the live preview while the button is
            // held — mouseMoved doesn't fire during a drag.
            _interaction.hover.local = [self localFromWindow:event.locationInWindow];
            _interaction.hover.has_point = YES;
        } else {
            _interaction.drag_mode = DragMode::None;
        }
    } else if (_ctx->tool.tool == macvoxel::ToolKind::Generator) {
        [self autoCommitFloatingBuffer];
        if (macvoxel::generator_controller::BeginDragOut(
                *_ctx, _interaction, [self viewContext],
                [self mouseEventFromNSEvent:event],
                [self generateFn])) {
            _interaction.hover.local = [self localFromWindow:event.locationInWindow];
            _interaction.hover.has_point = YES;
        } else {
            _interaction.drag_mode = DragMode::None;
        }
    } else if (_ctx->tool.tool == macvoxel::ToolKind::Face) {
        [self autoCommitFloatingBuffer];
        if (macvoxel::face_controller::OnMouseDown(
                *_ctx, _interaction, [self viewContext],
                [self mouseEventFromNSEvent:event])) {
            _interaction.hover.local = [self localFromWindow:event.locationInWindow];
            _interaction.hover.has_point = YES;
        } else {
            _interaction.drag_mode = DragMode::None;
            return;
        }
    } else {
        [self autoCommitFloatingBuffer];
        macvoxel::brush_controller::OnMouseDown(
            *_ctx, _interaction, [self viewContext],
            [self mouseEventFromNSEvent:event]);
    }
}

- (void)mouseDragged:(NSEvent*)event {
    if (_interaction.drag_mode == DragMode::None) {
        return;
    }
    const NSPoint p = event.locationInWindow;
    const float dx = static_cast<float>(p.x - _interaction.brush.last_drag_location.x);
    const float dy = static_cast<float>(p.y - _interaction.brush.last_drag_location.y);
    _interaction.brush.last_drag_location = p;

    switch (_interaction.drag_mode) {
        case DragMode::Orbit: _camera.Orbit(dx, dy); break;
        case DragMode::Pan:   _camera.Pan(dx, dy);   break;
        case DragMode::Paint:
            macvoxel::brush_controller::OnMouseDragged(
                *_ctx, _interaction, [self viewContext],
                [self mouseEventFromNSEvent:event]);
            break;
        case DragMode::Marquee:
            macvoxel::marquee_controller::OnMouseDragged(
                _interaction.marquee, [self mouseEventFromNSEvent:event]);
            break;
        case DragMode::MoveSelect:
            macvoxel::move_select_controller::OnMouseDragged(
                *_ctx, _interaction.move_select, [self viewContext],
                [self mouseEventFromNSEvent:event]);
            break;
        case DragMode::XformHandle:
            macvoxel::xform_handle_controller::OnMouseDragged(
                *_ctx, _interaction, [self viewContext],
                [self mouseEventFromNSEvent:event]);
            break;
        case DragMode::BoxSelect:
            macvoxel::box_select_controller::OnMouseDragged(
                *_ctx, _interaction.box_select, [self viewContext],
                [self mouseEventFromNSEvent:event]);
            break;
        case DragMode::Shape:
            // Re-render the live preview at the new cursor; the actual
            // history entry happens on mouseUp at the release point.
            _interaction.hover.local = [self localFromWindow:p];
            _interaction.hover.has_point = YES;
            if (_interaction.anchor.tool == macvoxel::ToolKind::Line ||
                _interaction.anchor.tool == macvoxel::ToolKind::Circle ||
                _interaction.anchor.tool == macvoxel::ToolKind::Square ||
                _interaction.anchor.tool == macvoxel::ToolKind::Box) {
                macvoxel::shape_controller::OnMouseDragged(
                    *_ctx, _interaction, [self viewContext],
                    [self mouseEventFromNSEvent:event]);
            } else if (_interaction.anchor.tool == macvoxel::ToolKind::Face) {
                macvoxel::face_controller::OnMouseDragged(
                    *_ctx, _interaction, [self viewContext],
                    [self mouseEventFromNSEvent:event]);
            } else if (_interaction.anchor.tool == macvoxel::ToolKind::Generator) {
                macvoxel::generator_controller::UpdateDragOut(
                    *_ctx, _interaction, [self viewContext],
                    [self mouseEventFromNSEvent:event],
                    [self generateFn]);
            }
            break;
        case DragMode::GenHandle:
            macvoxel::generator_controller::UpdateHandleDrag(
                _interaction, [self viewContext],
                [self mouseEventFromNSEvent:event]);
            break;
        case DragMode::None:  break;
    }
}

- (void)mouseUp:(NSEvent*)event {
    if (_interaction.drag_mode == DragMode::Paint) {
        macvoxel::brush_controller::OnMouseUp(*_ctx, _interaction);
    } else if (_interaction.drag_mode == DragMode::Marquee) {
        macvoxel::marquee_controller::OnMouseUp(
            *_ctx, _interaction.marquee, [self viewContext],
            [self mouseEventFromNSEvent:event]);
        _interaction.drag_mode = DragMode::None;
        return;
    } else if (_interaction.drag_mode == DragMode::BoxSelect) {
        macvoxel::box_select_controller::OnMouseUp(*_ctx);
        _interaction.drag_mode = DragMode::None;
        return;
    } else if (_interaction.drag_mode == DragMode::MoveSelect) {
        // Buffer stays floating until an explicit commit gesture
        // (tool switch / render toggle / save / etc.) hits the
        // auto-commit hooks elsewhere.
        _interaction.drag_mode = DragMode::None;
        return;
    } else if (_interaction.drag_mode == DragMode::XformHandle) {
        macvoxel::xform_handle_controller::OnMouseUp(_interaction);
        _interaction.drag_mode = DragMode::None;
        return;
    } else if (_interaction.drag_mode == DragMode::GenHandle) {
        macvoxel::generator_controller::EndHandleDrag(_interaction);
        _interaction.drag_mode = DragMode::None;
    } else if (_interaction.drag_mode == DragMode::Shape) {
        _interaction.drag_mode = DragMode::None;
        switch (_interaction.anchor.tool) {
            case macvoxel::ToolKind::Line:
            case macvoxel::ToolKind::Circle:
            case macvoxel::ToolKind::Square:
            case macvoxel::ToolKind::Box:
                macvoxel::shape_controller::OnMouseUp(*_ctx, _interaction);
                break;
            case macvoxel::ToolKind::Face:
                macvoxel::face_controller::OnMouseUp(
                    *_ctx, _interaction, [self viewContext],
                    [self mouseEventFromNSEvent:event]);
                break;
            case macvoxel::ToolKind::Generator:
                macvoxel::generator_controller::EndDragOut(_interaction);
                break;
            default:
                _interaction.anchor.has_anchor = NO;
                break;
        }
    }
    _interaction.drag_mode = DragMode::None;
    _interaction.brush.drag_skip_cells.clear();
}

// Right-click drives camera orbit, middle (other) click drives pan. Both
// share the dragged-delta math in mouseDragged: by routing through the
// same _interaction.drag_mode state machine — the dragged callbacks just forward to
// the left-button mouseDragged:, since the Orbit / Pan switch cases
// don't care which button generated the event.
- (void)rightMouseDown:(NSEvent*)event {
    if (ImGui::GetIO().WantCaptureMouse) {
        _interaction.drag_mode = DragMode::None;
        return;
    }
    _interaction.drag_mode = DragMode::Orbit;
    _interaction.brush.last_drag_location = event.locationInWindow;
}

- (void)rightMouseDragged:(NSEvent*)event {
    [self mouseDragged:event];
}

- (void)rightMouseUp:(NSEvent*)__unused event {
    if (_interaction.drag_mode == DragMode::Orbit) _interaction.drag_mode = DragMode::None;
}

- (void)otherMouseDown:(NSEvent*)event {
    if (ImGui::GetIO().WantCaptureMouse) {
        _interaction.drag_mode = DragMode::None;
        return;
    }
    _interaction.drag_mode = DragMode::Pan;
    _interaction.brush.last_drag_location = event.locationInWindow;
}

- (void)otherMouseDragged:(NSEvent*)event {
    [self mouseDragged:event];
}

- (void)otherMouseUp:(NSEvent*)__unused event {
    if (_interaction.drag_mode == DragMode::Pan) _interaction.drag_mode = DragMode::None;
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

// Eyedropper: cast a ray from the click into the grid; if it hits a
// non-empty voxel, copy that voxel's palette index into the active
// slot (and reset selected_slots to a single-selection of that index,
// preserving ToolSettings' "palette_idx is always a member of
// selected_slots when non-empty" invariant). Misses leave the
// palette unchanged.
- (BOOL)eyedropperAtPoint:(NSPoint)windowPoint {
    macvoxel::Document* doc = &_ctx->document;
    if (doc == nullptr) return NO;
    const simd::float2 lp = [self localFromWindow:windowPoint];
    simd::float3 ray_origin, ray_dir;
    if (![self viewContext].RayAt(lp.x, lp.y, &ray_origin, &ray_dir)) return NO;
    macvoxel::RayHit hit;
    if (!macvoxel::Raycast(doc->grid, ray_origin, ray_dir, 4096.0f, &hit)) {
        return NO;
    }
    if (hit.color == 0) return NO;
    macvoxel::ToolSettings& tool = _ctx->tool;
    tool.palette_idx = hit.color;
    tool.selected_slots.reset();
    tool.selected_slots.set(hit.color);
    return YES;
}

// ---------------------------------------------------------------------------
// Selection overlay: project the 8 corners of the selection AABB to screen
// space and draw the 12 connecting edges via ImGui's background draw list,
// so it overlays the ray-cast scene but sits underneath ImGui panels.
// ---------------------------------------------------------------------------

// Project a unit cube at grid cell (cx, cy, cz) and draw its 12 edges via
// ImGui's background draw list. Used by both the selection overlay and
// the hover indicator so they look like the same kind of object.
- (void)drawCellWireAtX:(int)cx y:(int)cy z:(int)cz color:(ImU32)color {
    const float w = static_cast<float>(self.bounds.size.width);
    const float h = static_cast<float>(self.bounds.size.height);
    if (w <= 0.0f || h <= 0.0f) return;
    const float aspect = w / h;
    const simd::float4x4 vp = _camera.ProjectionMatrix(aspect) * _camera.ViewMatrix();

    const simd::float3 gmin{static_cast<float>(cx),
                            static_cast<float>(cy),
                            static_cast<float>(cz)};
    const simd::float3 gmax{gmin.x + 1.0f, gmin.y + 1.0f, gmin.z + 1.0f};

    auto to_world = [](simd::float3 g) {
        return simd::float3{g.x, g.z, -g.y};
    };
    simd::float3 corners[8] = {
        {gmin.x, gmin.y, gmin.z}, {gmax.x, gmin.y, gmin.z},
        {gmax.x, gmax.y, gmin.z}, {gmin.x, gmax.y, gmin.z},
        {gmin.x, gmin.y, gmax.z}, {gmax.x, gmin.y, gmax.z},
        {gmax.x, gmax.y, gmax.z}, {gmin.x, gmax.y, gmax.z},
    };
    ImVec2 screen[8];
    bool valid[8];
    for (int i = 0; i < 8; ++i) {
        const simd::float3 wpos = to_world(corners[i]);
        const simd::float4 clip = simd_mul(vp, simd::float4{wpos.x, wpos.y, wpos.z, 1.0f});
        valid[i] = clip.w > 0.001f;
        if (valid[i]) {
            const float ndc_x = clip.x / clip.w;
            const float ndc_y = clip.y / clip.w;
            screen[i].x = (ndc_x * 0.5f + 0.5f) * w;
            screen[i].y = (1.0f - (ndc_y * 0.5f + 0.5f)) * h;
        }
    }
    static const int kEdges[12][2] = {
        {0, 1}, {1, 2}, {2, 3}, {3, 0},
        {4, 5}, {5, 6}, {6, 7}, {7, 4},
        {0, 4}, {1, 5}, {2, 6}, {3, 7},
    };
    ImDrawList* dl = ImGui::GetBackgroundDrawList();
    for (int i = 0; i < 12; ++i) {
        const int a = kEdges[i][0];
        const int b = kEdges[i][1];
        if (!valid[a] || !valid[b]) continue;
        dl->AddLine(screen[a], screen[b], color, 1.5f);
    }
}

// Mode-tinted outline of the cell that a click *would* affect: green-ish
// for Add (placement target = neighbor face), red-ish for Remove, blue-ish
// for Paint. Skipped during drag-paint (the drag itself shows what it's
// doing) and when a panel has captured the mouse.
- (void)drawHoverOverlay {
    if (!_interaction.hover.has_point) return;
    if (_interaction.drag_mode != DragMode::None) return;
    if (ImGui::GetIO().WantCaptureMouse) return;
    // Generator gizmo is the cursor indicator while it's live; the
    // would-place-cell wireframe would compete with it and read as
    // a stray duplicate.
    if (_interaction.gen_gizmo.active) return;

    const macvoxel::ToolSettings& t = _ctx->tool;
    const bool is_brush = t.tool == macvoxel::ToolKind::Brush;
    const bool is_two_click = (t.tool == macvoxel::ToolKind::Line ||
                               t.tool == macvoxel::ToolKind::Circle ||
                               t.tool == macvoxel::ToolKind::Square ||
                               t.tool == macvoxel::ToolKind::Box ||
                               t.tool == macvoxel::ToolKind::Generator);
    if (!is_brush && !is_two_click) return;

    auto color_for_mode = [](macvoxel::ToolMode m) {
        switch (m) {
            case macvoxel::ToolMode::Add:    return IM_COL32(120, 230, 140, 220);
            case macvoxel::ToolMode::Remove: return IM_COL32(240, 110, 110, 220);
            case macvoxel::ToolMode::Paint:  return IM_COL32(120, 180, 240, 220);
        }
        return IM_COL32(255, 255, 255, 220);
    };

    // Single-cell hover (Brush, or shape tools before mouseDown). Shape
    // tools render a live voxel preview during the drag itself, so this
    // overlay only shows the pre-click target indicator. Two-click tools
    // accept empty-space anchors for Remove/Paint, so they use the
    // line-endpoint picker; Brush keeps the stricter behavior.
    Vec3i cell;
    const simd::float2 lp = _interaction.hover.local;
    const macvoxel::ViewContext vc = [self viewContext];
    const bool ok = is_two_click
        ? vc.ComputeLineEndpoint(lp.x, lp.y, t.mode, &cell, nullptr)
        : vc.ComputeTargetCell(lp.x, lp.y, t.mode, &cell, nullptr);
    if (!ok) return;
    [self drawCellWireAtX:cell.x y:cell.y z:cell.z color:color_for_mode(t.mode)];
}

// MoveSelect: Cmd-drag on a selected voxel translates the whole
// selection in the plane of the clicked face, snapped to integer
// voxel offsets. The selection is lifted into the FloatingBuffer if
// not already there (paste / earlier drag may have lifted it
// already), and the per-frame work is just an integer offset bump —
// no document mutation, no chunk dirty queue. Returns YES if the
// gesture took ownership of the drag.
// "User moved on to a different gesture" hook. When the floating
// buffer is alive and the user's about to do anything that's not a
// continuation of the move (new selection / brush stroke / shape
// tool / etc.), drop the buffer onto the document so the next
// gesture sees a settled state. No-op when nothing's floating.
- (void)autoCommitFloatingBuffer {
    if (!_ctx->floating_buffer.active) return;
    macvoxel::Document* doc = &_ctx->document;
    if (doc == nullptr) return;
    macvoxel::CommitFloatingBuffer(*_ctx);
}

- (void)drawSelectionOverlay {
    const macvoxel::Selection& sel = _ctx->selection;
    const macvoxel::FloatingBuffer& fb = _ctx->floating_buffer;
    // Skip both per-voxel highlights and AABB outline when there's
    // nothing to highlight: empty doc selection AND no floating buffer.
    const bool show_doc_sel = sel.active() && !sel.bounds().empty();
    const bool show_floating = fb.active && !fb.grid.empty();
    if (!show_doc_sel && !show_floating) return;

    const float w = static_cast<float>(self.bounds.size.width);
    const float h = static_cast<float>(self.bounds.size.height);
    if (w <= 0.0f || h <= 0.0f) return;
    const float aspect = w / h;
    const simd::float4x4 vp = _camera.ProjectionMatrix(aspect) * _camera.ViewMatrix();

    // 12 edges of a unit cube as pairs of corner indices.
    static const int kEdges[12][2] = {
        {0, 1}, {1, 2}, {2, 3}, {3, 0},  // bottom
        {4, 5}, {5, 6}, {6, 7}, {7, 4},  // top
        {0, 4}, {1, 5}, {2, 6}, {3, 7},  // verticals
    };
    ImDrawList* dl = ImGui::GetBackgroundDrawList();

    auto project_corners = [&](simd::float3 gmin, simd::float3 gmax,
                               ImVec2* screen, bool* valid) {
        // Same R = (gx, gz, -gy) the renderer applies.
        const simd::float3 corners_grid[8] = {
            {gmin.x, gmin.y, gmin.z}, {gmax.x, gmin.y, gmin.z},
            {gmax.x, gmax.y, gmin.z}, {gmin.x, gmax.y, gmin.z},
            {gmin.x, gmin.y, gmax.z}, {gmax.x, gmin.y, gmax.z},
            {gmax.x, gmax.y, gmax.z}, {gmin.x, gmax.y, gmax.z},
        };
        for (int i = 0; i < 8; ++i) {
            const simd::float3 g = corners_grid[i];
            const simd::float3 wpos{g.x, g.z, -g.y};
            const simd::float4 clip =
                simd_mul(vp, simd::float4{wpos.x, wpos.y, wpos.z, 1.0f});
            valid[i] = clip.w > 0.001f;
            if (valid[i]) {
                const float ndc_x = clip.x / clip.w;
                const float ndc_y = clip.y / clip.w;
                screen[i].x = (ndc_x * 0.5f + 0.5f) * w;
                screen[i].y = (1.0f - (ndc_y * 0.5f + 0.5f)) * h;  // ImGui Y-down
            }
        }
    };

    auto stroke_edges = [&](const ImVec2* screen, const bool* valid,
                            const int (*edges)[2], int n,
                            ImU32 color, float thickness) {
        for (int i = 0; i < n; ++i) {
            const int a = edges[i][0];
            const int b = edges[i][1];
            if (!valid[a] || !valid[b]) continue;
            dl->AddLine(screen[a], screen[b], color, thickness);
        }
    };

    // Outer AABB. Voxels span [c, c+1] so the outer faces are at min..max+1.
    // When the floating buffer is active, take its bounds + offset; the
    // doc-side selection bounds are stale during a drag (we don't shift
    // them per frame for performance reasons — the whole point of
    // FloatingBuffer is O(1) drag work).
    {
        macvoxel::Bounds3 b{};
        if (show_floating) {
            const macvoxel::Bounds3 gb = fb.grid.Bounds();
            b.min_x = gb.min_x + fb.offset_x;
            b.min_y = gb.min_y + fb.offset_y;
            b.min_z = gb.min_z + fb.offset_z;
            b.max_x = gb.max_x + fb.offset_x;
            b.max_y = gb.max_y + fb.offset_y;
            b.max_z = gb.max_z + fb.offset_z;
        } else {
            b = sel.bounds();
        }
        const simd::float3 box_min{static_cast<float>(b.min_x),
                                   static_cast<float>(b.min_y),
                                   static_cast<float>(b.min_z)};
        const simd::float3 box_max{static_cast<float>(b.max_x + 1),
                                   static_cast<float>(b.max_y + 1),
                                   static_cast<float>(b.max_z + 1)};
        ImVec2 screen[8];
        bool valid[8];
        project_corners(box_min, box_max, screen, valid);
        stroke_edges(screen, valid, kEdges, 12,
                     IM_COL32(255, 220, 80, 255), 1.5f);
    }

    // Per-voxel highlights for sparse selections. Two passes of
    // hidden-line removal keep the overlay legible when thousands of
    // voxels are selected:
    //  1. Skip faces whose neighbor cell is also selected — internal
    //     boundaries collapse, leaving only the silhouette of the
    //     selected region.
    //  2. Of those, skip back-facing faces (normal pointing away from
    //     the camera) so we don't double-stroke through the silhouette.
    // The 6 faces and their corner-quads, paired with the neighbor
    // offset that would hide them. Order: +X, -X, +Y, -Y, +Z, -Z. Each
    // face's 4 edges live in indices kFaceEdges[face][0..3].
    static const int kFaceEdges[6][4][2] = {
        {{1, 2}, {2, 6}, {6, 5}, {5, 1}},  // +X
        {{0, 3}, {3, 7}, {7, 4}, {4, 0}},  // -X
        {{3, 2}, {2, 6}, {6, 7}, {7, 3}},  // +Y
        {{0, 1}, {1, 5}, {5, 4}, {4, 0}},  // -Y
        {{4, 5}, {5, 6}, {6, 7}, {7, 4}},  // +Z
        {{0, 1}, {1, 2}, {2, 3}, {3, 0}},  // -Z
    };
    static const int kNeighbor[6][3] = {
        {+1, 0, 0}, {-1, 0, 0},
        {0, +1, 0}, {0, -1, 0},
        {0, 0, +1}, {0, 0, -1},
    };
    // Face outward normal in world space (after R = (gx, gz, -gy)):
    // grid +X→world +X, grid +Y→world -Z, grid +Z→world +Y.
    static const simd::float3 kFaceNormalWorld[6] = {
        { 1.0f,  0.0f,  0.0f},
        {-1.0f,  0.0f,  0.0f},
        { 0.0f,  0.0f, -1.0f},
        { 0.0f,  0.0f,  1.0f},
        { 0.0f,  1.0f,  0.0f},
        { 0.0f, -1.0f,  0.0f},
    };

    // Cap only the floating-buffer path — a 256³ lift renders sane
    // silhouette wireframes thanks to the hidden-face cull below, but
    // the O(N) cell scan to *build* them dominates the frame. Doc-side
    // selections already worked uncapped before the FB landed (marquee
    // through a solid model can hit 50K+ cells), so don't regress them.
    constexpr size_t kFloatingWireMax = 200000;

    const simd::float3 cam = _camera.Position();
    const ImU32 voxel_color = IM_COL32(255, 220, 80, 200);

    // Build the cell list + a hash set of cell keys — the doc-side path
    // already worked this way, and the floating-buffer path slots in
    // the same shape (cells = fb.grid contents shifted by offset, set
    // built once for O(1) neighbor membership tests).
    std::vector<std::array<int32_t, 3>> cells;
    std::unordered_set<int64_t> selected_set;
    if (show_floating) {
        const size_t nfilled = static_cast<size_t>(fb.grid.FilledCount());
        if (nfilled == 0 || nfilled > kFloatingWireMax) return;
        cells.reserve(nfilled);
        selected_set.reserve(nfilled * 2);
        constexpr uint32_t kCS = macvoxel::VoxelGrid::kChunkSize;
        for (const auto& [coord, chunk] : fb.grid.chunks()) {
            if (chunk->filled_count == 0) continue;
            const int32_t base_x = coord.x * static_cast<int32_t>(kCS);
            const int32_t base_y = coord.y * static_cast<int32_t>(kCS);
            const int32_t base_z = coord.z * static_cast<int32_t>(kCS);
            for (uint32_t lz = 0; lz < kCS; ++lz)
            for (uint32_t ly = 0; ly < kCS; ++ly)
            for (uint32_t lx = 0; lx < kCS; ++lx) {
                const size_t idx = lx + ly * kCS + lz * kCS * kCS;
                if (chunk->cells[idx] == 0) continue;
                const int32_t cx = base_x + static_cast<int32_t>(lx)
                                   + fb.offset_x;
                const int32_t cy = base_y + static_cast<int32_t>(ly)
                                   + fb.offset_y;
                const int32_t cz = base_z + static_cast<int32_t>(lz)
                                   + fb.offset_z;
                cells.push_back({cx, cy, cz});
                selected_set.insert(macvoxel::PackCellKey(cx, cy, cz));
            }
        }
    } else {
        if (sel.empty()) return;
        cells.reserve(sel.size());
        selected_set.reserve(sel.size() * 2);
        for (const auto& v : sel.voxels()) {
            cells.push_back(v);
            selected_set.insert(macvoxel::PackCellKey(v[0], v[1], v[2]));
        }
    }

    for (const auto& v : cells) {
        const simd::float3 cmin{static_cast<float>(v[0]),
                                static_cast<float>(v[1]),
                                static_cast<float>(v[2])};
        const simd::float3 cmax{cmin.x + 1.0f, cmin.y + 1.0f, cmin.z + 1.0f};
        ImVec2 screen[8];
        bool valid[8];
        project_corners(cmin, cmax, screen, valid);
        const simd::float3 center_world{
            cmin.x + 0.5f, cmin.z + 0.5f, -(cmin.y + 0.5f)};
        for (int f = 0; f < 6; ++f) {
            if (selected_set.count(macvoxel::PackCellKey(
                    v[0] + kNeighbor[f][0],
                    v[1] + kNeighbor[f][1],
                    v[2] + kNeighbor[f][2]))) {
                continue;  // interior face
            }
            const simd::float3 to_cam = cam - center_world;
            if (simd_dot(to_cam, kFaceNormalWorld[f]) <= 0.0f) {
                continue;  // back-facing
            }
            stroke_edges(screen, valid, kFaceEdges[f], 4,
                         voxel_color, 1.0f);
        }
    }
}

@end
