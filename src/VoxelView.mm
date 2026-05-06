#import "VoxelView.h"

#import "AppDelegate.h"
#import "PathTraceRenderer.h"
#import "RaycastRenderer.h"

#import <Metal/Metal.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <cstdio>
#include <algorithm>
#include <unordered_set>

#include "imgui.h"
#include "imgui_impl_metal.h"
#include "imgui_impl_osx.h"
#include "imgui_internal.h"  // DockBuilder API

#include "Camera.h"
#include "Document.h"
#include "EditHistory.h"
#include "Raycast.h"
#include "RenderState.h"
#include "Selection.h"
#include "ToolState.h"
#include "ui/Fonts.h"
#include "ui/ModelPanel.h"
#include "ui/PalettePanel.h"
#include "ui/RenderPanel.h"
#include "ui/Theme.h"
#include "ui/ToolPanel.h"

namespace {
enum class DragMode { None, Orbit, Pan, Paint, Select };

struct Vec3i { int32_t x, y, z; };

constexpr Vec3i kInvalidCell{INT32_MIN, INT32_MIN, INT32_MIN};

bool SameCell(const Vec3i& a, const Vec3i& b) {
    return a.x == b.x && a.y == b.y && a.z == b.z;
}
}

@implementation VoxelView {
    id<MTLCommandQueue> _commandQueue;
    RaycastRenderer* _raycastRenderer;
    PathTraceRenderer* _pathTraceRenderer;
    macvoxel::Camera _camera;
    DragMode _dragMode;
    macvoxel::ToolMode _paintMode;
    Vec3i _selectionAnchor;
    Vec3i _lastDragEditCell;
    NSPoint _lastDragLocation;
    NSPoint _hoverWindowPoint;
    BOOL _hoverHasPoint;
    // Cells placed during the current drag-Add stroke. The raycast
    // ignores these so the cursor keeps targeting the *original*
    // surface; otherwise each new voxel becomes the next event's hit
    // and the target marches outward along the face normal.
    std::unordered_set<int64_t> _dragSkipCells;
    NSTrackingArea* _trackingArea;
    BOOL _imguiAlive;
    bool _wasPathTraced;
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
    _pathTraceRenderer = [[PathTraceRenderer alloc] initWithDevice:device
                                                       colorFormat:self.colorPixelFormat];
    if (_pathTraceRenderer == nil) {
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
            ImGui::DockBuilderDockWindow("Palette", left_bottom);
            ImGui::DockBuilderDockWindow("Model", right_top);
            ImGui::DockBuilderDockWindow("Render", right_bottom);
            ImGui::DockBuilderFinish(dock_id);
        }
    }

    ImGui::End();
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

    [self setupDockspace];

    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc != nullptr) {
        macvoxel::RenderStats stats;
        stats.chunk_count = [_raycastRenderer lastChunkCount];
        stats.gpu_bytes = [_raycastRenderer lastGPUBytes];
        macvoxel::DrawModelPanel(*doc, stats);
        macvoxel::DrawRenderPanel(*doc, stats);
        macvoxel::DrawToolPanel();
        macvoxel::DrawPalettePanel(*doc);
        [self drawSelectionOverlay];
        [self drawHoverOverlay];

        if (macvoxel::ConsumeSaveRenderClick()) {
            [self runSaveRenderPanel];
        }
    }

    ImGui::Render();

    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
    cmd.label = @"MacVoxel Frame";

    const bool pt_now = macvoxel::CurrentRenderState().path_traced;
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
                                document:doc
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
                                   document:doc];
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
    _hoverWindowPoint = event.locationInWindow;
    _hoverHasPoint = YES;
}

- (void)mouseExited:(NSEvent*)__unused event {
    _hoverHasPoint = NO;
}

- (void)runSaveRenderPanel {
    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.title = @"Save render";
    panel.allowedContentTypes = @[ UTTypePNG ];
    panel.nameFieldStringValue = @"render.png";
    panel.canCreateDirectories = YES;

    PathTraceRenderer* renderer = _pathTraceRenderer;
    id<MTLCommandQueue> queue = _commandQueue;
    [panel beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        NSURL* url = panel.URL;
        if (url == nil) return;
        NSError* err = nil;
        if (![renderer exportPNGToURL:url commandQueue:queue error:&err]) {
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
        _paintMode = hasCommand ? macvoxel::ToolMode::Remove
                                : macvoxel::CurrentTool().mode;
        _lastDragEditCell = kInvalidCell;
        _dragSkipCells.clear();
        macvoxel::CurrentHistory().BeginOp();
        [self performEditAtPoint:event.locationInWindow mode:_paintMode];
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
        case DragMode::Paint: [self performEditAtPoint:p mode:_paintMode]; break;
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
    _dragSkipCells.clear();
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
    if (!_hoverHasPoint) return;
    if (_dragMode != DragMode::None) return;
    if (ImGui::GetIO().WantCaptureMouse) return;

    const macvoxel::ToolState& t = macvoxel::CurrentTool();
    if (t.tool != macvoxel::ToolKind::Brush) return;

    Vec3i cell;
    if (![self computeTargetCellAtPoint:_hoverWindowPoint mode:t.mode into:&cell]) {
        return;
    }
    ImU32 color;
    switch (t.mode) {
        case macvoxel::ToolMode::Add:    color = IM_COL32(120, 230, 140, 220); break;
        case macvoxel::ToolMode::Remove: color = IM_COL32(240, 110, 110, 220); break;
        case macvoxel::ToolMode::Paint:  color = IM_COL32(120, 180, 240, 220); break;
    }
    [self drawCellWireAtX:cell.x y:cell.y z:cell.z color:color];
}

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

- (BOOL)gridRayAtPoint:(NSPoint)windowPoint
                origin:(simd::float3*)out_origin
             direction:(simd::float3*)out_dir {
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
    const simd::float3 far_world  = unproject(1.0f);
    const simd::float3 dir_world = simd::normalize(far_world - near_world);
    const simd::float3 origin_world = _camera.Position();

    // World -> grid: invert the renderer's R = (gx, gz, -gy).
    *out_origin = simd::float3{origin_world.x, -origin_world.z, origin_world.y};
    *out_dir    = simd::float3{dir_world.x,    -dir_world.z,    dir_world.y};
    return YES;
}

- (BOOL)computeTargetCellAtPoint:(NSPoint)windowPoint
                            mode:(macvoxel::ToolMode)mode
                            into:(Vec3i*)out {
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) return NO;

    simd::float3 ray_origin_grid, ray_dir_grid;
    if (![self gridRayAtPoint:windowPoint
                       origin:&ray_origin_grid
                    direction:&ray_dir_grid]) {
        return NO;
    }

    macvoxel::RayHit hit;
    bool hit_voxel;
    // During a drag-Add stroke, skip cells we just placed so the raycast
    // keeps hitting the original surface. Other modes (Remove, Paint)
    // and non-drag interactions raycast against the live grid.
    if (mode == macvoxel::ToolMode::Add &&
        _dragMode == DragMode::Paint && !_dragSkipCells.empty()) {
        hit_voxel = macvoxel::RaycastIgnoring(doc->grid, ray_origin_grid,
                                              ray_dir_grid, 4096.0f,
                                              _dragSkipCells, &hit);
    } else {
        hit_voxel = macvoxel::Raycast(doc->grid, ray_origin_grid,
                                      ray_dir_grid, 4096.0f, &hit);
    }

    int target_x = 0;
    int target_y = 0;
    int target_z = 0;
    if (hit_voxel) {
        target_x = hit.x;
        target_y = hit.y;
        target_z = hit.z;
        if (mode == macvoxel::ToolMode::Add) {
            if (hit.axis < 0) return NO;  // ray started inside a voxel
            if (hit.axis == 0) target_x += hit.sign;
            else if (hit.axis == 1) target_y += hit.sign;
            else if (hit.axis == 2) target_z += hit.sign;
        }
    } else {
        // Empty-space click. Add falls back to the implicit ground plane
        // (grid z=0, matching MagicaVoxel's convention). Remove/Paint need
        // a real voxel to act on, so they no-op here.
        if (mode != macvoxel::ToolMode::Add) return NO;
        if (std::abs(ray_dir_grid.z) < 1e-6f) return NO;
        const float t = -ray_origin_grid.z / ray_dir_grid.z;
        if (t < 0.0f || t > 4096.0f) return NO;
        const float hx = ray_origin_grid.x + t * ray_dir_grid.x;
        const float hy = ray_origin_grid.y + t * ray_dir_grid.y;
        target_x = static_cast<int>(std::floor(hx));
        target_y = static_cast<int>(std::floor(hy));
        target_z = 0;
    }

    *out = Vec3i{target_x, target_y, target_z};
    return YES;
}

- (void)performEditAtPoint:(NSPoint)windowPoint mode:(macvoxel::ToolMode)mode {
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) return;

    Vec3i target;
    if (![self computeTargetCellAtPoint:windowPoint mode:mode into:&target]) {
        return;
    }
    const int target_x = target.x;
    const int target_y = target.y;
    const int target_z = target.z;

    macvoxel::ToolState& tool = macvoxel::CurrentTool();
    const int radius = std::max(1, tool.brush_radius);
    const int span = radius - 1;

    // Drag-paint dedupe: only fire when the target cell changes. Without
    // this, every pointer-move event during a drag (many per frame) would
    // re-apply the brush to the same cell, which is harmless for Add but
    // bloats the undo history and can produce N²-style work for Paint.
    if (_dragMode == DragMode::Paint && SameCell(target, _lastDragEditCell)) {
        return;
    }
    _lastDragEditCell = target;

    macvoxel::EditHistory& history = macvoxel::CurrentHistory();

    const BOOL track_skip = (_dragMode == DragMode::Paint &&
                             mode == macvoxel::ToolMode::Add);
    auto apply = [&](int x, int y, int z) {
        const uint8_t old_val = doc->grid.Get(x, y, z);
        uint8_t new_val = old_val;
        switch (mode) {
            case macvoxel::ToolMode::Add:
                new_val = tool.palette_idx;
                break;
            case macvoxel::ToolMode::Remove:
                new_val = 0;
                break;
            case macvoxel::ToolMode::Paint:
                if (old_val != 0) new_val = tool.palette_idx;
                break;
        }
        if (new_val == old_val) return;
        doc->grid.Set(x, y, z, new_val);
        history.Record(x, y, z, old_val, new_val);
        if (track_skip) {
            _dragSkipCells.insert(macvoxel::PackCellKey(x, y, z));
        }
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
