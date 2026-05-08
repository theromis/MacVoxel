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
#include "GeneratorState.h"
#include "Raycast.h"
#include "RenderState.h"
#include "Selection.h"
#include "Shapes.h"
#include "ToolState.h"
#include "ui/Fonts.h"
#include "ui/GeneratorPanel.h"
#include "ui/ModelPanel.h"
#include "ui/PalettePanel.h"
#include "ui/RenderPanel.h"
#include "ui/Theme.h"
#include "ui/ToolPanel.h"

namespace {
enum class DragMode { None, Orbit, Pan, Paint, Select, Shape, GenHandle };

using Vec3i = macvoxel::shapes::Vec3i;
struct LineHit { int32_t x, y, z; int face_axis; };

constexpr Vec3i kInvalidCell{INT32_MIN, INT32_MIN, INT32_MIN};

bool SameCell(const Vec3i& a, const Vec3i& b) {
    return a.x == b.x && a.y == b.y && a.z == b.z;
}

// Per-cell edit arithmetic: return the new cell value given the old
// value, the tool mode, and the active palette color. Add only fills
// empty cells (so a wide brush doesn't recolor neighbors), Remove
// always clears, Paint only repaints existing voxels. Caller checks
// `new == old` to decide whether to actually write.
inline uint8_t ComputeNewCellValue(uint8_t old_val, macvoxel::ToolMode mode,
                                   uint8_t palette_idx) {
    switch (mode) {
        case macvoxel::ToolMode::Add:
            return (old_val == 0) ? palette_idx : old_val;
        case macvoxel::ToolMode::Remove:
            return 0;
        case macvoxel::ToolMode::Paint:
            return (old_val != 0) ? palette_idx : old_val;
    }
    return old_val;
}

// (axis, sign) for face index 0..5. axis/2 = X|Y|Z; sign +1 for "max"
// face, -1 for "min" face. Layout matches kFaceArrowOrder below.
inline void GenFaceAxisSign(int face, int* axis, int* sign) {
    *axis = face / 2;
    *sign = (face & 1) ? +1 : -1;
}

// World-space face center (between cells, after the renderer's
// R = (gx, gz, -gy) transform) and the face's outward normal in world
// space. The "outer surface" of a face on the +axis side is at coord+1
// (voxels span [c, c+1]); on the -axis side it's at coord.
void GizmoFaceWorldGeom(const macvoxel::generators::Bounds3i& b, int face,
                        simd::float3* out_center, simd::float3* out_normal) {
    int axis, sign;
    GenFaceAxisSign(face, &axis, &sign);
    auto mid = [](int32_t a, int32_t b1) {
        return (static_cast<float>(a) + static_cast<float>(b1) + 1.0f) * 0.5f;
    };
    const int32_t face_coord = (sign < 0)
        ? (axis == 0 ? b.x0 : axis == 1 ? b.y0 : b.z0)
        : ((axis == 0 ? b.x1 : axis == 1 ? b.y1 : b.z1) + 1);
    float gx, gy, gz;
    if (axis == 0) {
        gx = static_cast<float>(face_coord);
        gy = mid(b.y0, b.y1);
        gz = mid(b.z0, b.z1);
    } else if (axis == 1) {
        gx = mid(b.x0, b.x1);
        gy = static_cast<float>(face_coord);
        gz = mid(b.z0, b.z1);
    } else {
        gx = mid(b.x0, b.x1);
        gy = mid(b.y0, b.y1);
        gz = static_cast<float>(face_coord);
    }
    *out_center = simd::float3{gx, gz, -gy};
    simd::float3 n_grid{0, 0, 0};
    if (axis == 0) n_grid.x = static_cast<float>(sign);
    else if (axis == 1) n_grid.y = static_cast<float>(sign);
    else n_grid.z = static_cast<float>(sign);
    *out_normal = simd::float3{n_grid.x, n_grid.z, -n_grid.y};
}
}

@implementation VoxelView {
    id<MTLCommandQueue> _commandQueue;
    RaycastRenderer* _raycastRenderer;
    PathTraceRenderer* _pathTraceRenderer;
    GeneratorEngine* _generatorEngine;
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
    // Two-click tools (Line, Circle, …): between click 1 and click 2.
    // Anchor cell + face axis are computed at click 1 (via the line-endpoint
    // picker); the screen-space anchor point is used as one endpoint of the
    // screen-space segment in Line's Project mode. The mode and tool are
    // frozen at click 1 so switching either mid-stroke doesn't surprise the
    // user; the per-frame sweep cancels the anchor when they change.
    BOOL _hasAnchor;
    Vec3i _anchorCell;
    int _anchorFaceAxis;
    macvoxel::ToolMode _anchorMode;
    NSPoint _anchorScreen;
    macvoxel::ToolKind _anchorTool;
    // Face tool only: result of the click-time flood fill (all coplanar
    // same-color cells whose face on (_anchorFaceAxis, _faceSign) is
    // exposed) and the source color used for extrusions. `_faceObservedDrag`
    // is set the first time the cursor produces a non-zero voxel distance
    // from the anchor; while it's still NO, a d=0 commit is treated as
    // d=1 so a click without drag applies a single 1-voxel layer.
    int _faceSign;
    uint8_t _faceSeedColor;
    BOOL _faceObservedDrag;
    // The d value (normalized — signed for Add, |d| for Remove/Paint)
    // currently materialised into `_shapePreview`, plus the `face_with`
    // value at the time those layers were applied. Used so each frame
    // only does O(seed_cells × Δd) work as the user drags through layer
    // boundaries, instead of rebuilding the whole preview every frame.
    int _faceAppliedD;
    macvoxel::FaceWithColor _faceAppliedWith;
    std::vector<Vec3i> _faceSeedCells;
    // Live voxel preview for shape tools (Line/Circle/Square): each entry
    // is a cell touched during the current drag mapped to its original
    // grid value (before any preview edits this drag). On every dragged
    // event we restore these and re-stamp the new shape, so the document
    // visibly tracks the cursor without polluting EditHistory. On mouseUp
    // we roll back one last time and commit the final shape through the
    // normal history path so the whole drag becomes a single undo step.
    std::unordered_map<int64_t, uint8_t> _shapePreview;
    // Generator gizmo state. After the user releases the mouse from a
    // Generator-tool drag-out, the box stays visible (along with its
    // _shapePreview cells) until they confirm. Clicking outside the box
    // commits the preview through EditHistory; Esc rolls it back without
    // a commit. The bounds + active-kind cache lets the per-frame loop
    // detect param/kind changes from the panel and re-run the engine.
    BOOL _genGizmoActive;
    macvoxel::generators::Bounds3i _genBounds;
    macvoxel::generators::Kind _genLastKind;
    macvoxel::generators::Bounds3i _genLastBounds;
    macvoxel::generators::Params _genLastParams;
    // Face-handle drag state. _genActiveDragFace is 0..5 while a handle
    // is being dragged (DragMode::GenHandle); -1 otherwise. The face
    // index encodes (axis, sign): face/2 = axis, face&1 = (sign>0).
    // _genHandleStartBounds locks in the bounds at drag-start so each
    // frame's drag distance projects against the same NDC reference
    // direction — without this, the projected normal moves as bounds
    // change and the drag-to-voxels mapping drifts.
    int _genActiveDragFace;
    NSPoint _genHandleStartCursor;
    macvoxel::generators::Bounds3i _genHandleStartBounds;
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
    _generatorEngine = [[GeneratorEngine alloc] initWithDevice:device
                                                  commandQueue:_commandQueue];
    if (_generatorEngine == nil) {
        return nil;
    }
    _genActiveDragFace = -1;  // 0 means "the -X face" — explicit nil-state.

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

    // Cancel a pending shape anchor on Escape or when the user switches
    // tools mid-stroke. ImGui owns keyDown via its hidden KeyEventResponder,
    // so we read the IO-level state instead of overriding -keyDown:.
    // Clearing _dragMode too means the upcoming mouseUp won't try to
    // commit the (now anchor-less) shape.
    if (_hasAnchor) {
        if (macvoxel::CurrentTool().tool != _anchorTool ||
            ImGui::IsKeyPressed(ImGuiKey_Escape, false)) {
            if (_dragMode == DragMode::Shape) {
                [self rollbackShapePreview];
                _dragMode = DragMode::None;
            }
            _hasAnchor = NO;
            _faceSeedCells.clear();
        }
    }

    // Same logic for an active Generator gizmo: Esc cancels the live
    // preview without writing history, switching tools cancels too. The
    // ImGui IsKeyPressed read happens after NewFrame so it sees this
    // frame's keyboard input.
    if (_genGizmoActive) {
        if (macvoxel::CurrentTool().tool != macvoxel::ToolKind::Generator ||
            ImGui::IsKeyPressed(ImGuiKey_Escape, false)) {
            [self cancelGenGizmo];
        }
    }

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
        macvoxel::DrawGeneratorPanel();
        macvoxel::DrawPalettePanel(*doc);
        // Gizmo refresh: the panel may have changed the active kind or
        // parameters; the tool's palette index may have changed too.
        // Detect any of those (plus a bounds change from a future face
        // handle) and re-run the engine.
        if (_genGizmoActive) {
            const auto& gs = macvoxel::CurrentGeneratorState();
            const uint8_t cur_palette = macvoxel::CurrentTool().palette_idx;
            const bool dirty =
                gs.active_kind != _genLastKind ||
                std::memcmp(&_genBounds, &_genLastBounds,
                            sizeof(_genBounds)) != 0 ||
                cur_palette != _genLastParams.palette_idx ||
                gs.params.axis != _genLastParams.axis ||
                gs.params.apex_at_max != _genLastParams.apex_at_max;
            if (dirty) {
                [self refreshGenGizmoPreview];
                _genLastKind = gs.active_kind;
                _genLastBounds = _genBounds;
                _genLastParams = gs.params;
                _genLastParams.palette_idx = cur_palette;
            }
        }
        [self drawSelectionOverlay];
        [self drawHoverOverlay];
        [self drawGenGizmo];

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
    const BOOL hasCommand = (m & NSEventModifierFlagCommand) != 0;
    // Space + left-click = pan (the alt to middle-click on trackpads
    // and one-button mice). Camera orbit lives on right-click via
    // rightMouseDown:; pan also lives on otherMouseDown: (middle).
    if (ImGui::IsKeyDown(ImGuiKey_Space)) {
        _dragMode = DragMode::Pan;
        _lastDragLocation = event.locationInWindow;
    } else if (_genGizmoActive) {
        // Click on a face arrow handle → enter resize drag. Any other
        // click in the viewport commits the gizmo (the user signals
        // they're done by clicking outside the handles).
        const int face = [self pickGenHandleAtPoint:event.locationInWindow];
        if (face >= 0) {
            _genActiveDragFace = face;
            _genHandleStartCursor = event.locationInWindow;
            _genHandleStartBounds = _genBounds;
            _dragMode = DragMode::GenHandle;
        } else {
            [self commitGenGizmo];
            _dragMode = DragMode::None;
        }
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
            sel.voxels.clear();
        } else {
            _dragMode = DragMode::None;
        }
    } else if (macvoxel::CurrentTool().tool == macvoxel::ToolKind::Line ||
               macvoxel::CurrentTool().tool == macvoxel::ToolKind::Circle ||
               macvoxel::CurrentTool().tool == macvoxel::ToolKind::Square ||
               macvoxel::CurrentTool().tool == macvoxel::ToolKind::Box ||
               macvoxel::CurrentTool().tool == macvoxel::ToolKind::Generator) {
        // Click-and-drag shape tools — anchor on mouseDown, preview while
        // dragging, commit on mouseUp at the release point.
        const macvoxel::ToolMode mode = hasCommand ? macvoxel::ToolMode::Remove
                                                    : macvoxel::CurrentTool().mode;
        [self beginAnchorAtPoint:event.locationInWindow mode:mode];
        if (_hasAnchor) {
            _dragMode = DragMode::Shape;
            // Track the cursor for the live preview while the button is
            // held — mouseMoved doesn't fire during a drag.
            _hoverWindowPoint = event.locationInWindow;
            _hoverHasPoint = YES;
            // Generator tool: activate the gizmo immediately so the
            // AABB outline is visible from the first click rather than
            // appearing only after release. _genBounds starts as the
            // anchor cell alone; refreshShapePreview's Generator case
            // grows it as the user drags.
            if (macvoxel::CurrentTool().tool ==
                macvoxel::ToolKind::Generator) {
                _genBounds = macvoxel::generators::Bounds3i{
                    _anchorCell.x, _anchorCell.y, _anchorCell.z,
                    _anchorCell.x, _anchorCell.y, _anchorCell.z,
                };
                _genGizmoActive = YES;
                _genLastKind =
                    macvoxel::CurrentGeneratorState().active_kind;
                _genLastBounds = _genBounds;
                _genLastParams =
                    macvoxel::CurrentGeneratorState().params;
                _genLastParams.palette_idx =
                    macvoxel::CurrentTool().palette_idx;
            }
            // Render the initial click-cell shape so a bare click (no
            // drag) shows its placement before mouseUp commits.
            [self refreshShapePreview];
        } else {
            _dragMode = DragMode::None;
        }
    } else if (macvoxel::CurrentTool().tool == macvoxel::ToolKind::Face) {
        // Face tool: pick the clicked face, run a flood fill on the seed
        // plane, then enter Shape drag for live extrude / inset preview.
        Vec3i seed;
        int axis = 2, sign = 1;
        uint8_t color = 0;
        if (![self pickFaceAtPoint:event.locationInWindow cell:&seed
                              axis:&axis sign:&sign color:&color]) {
            _dragMode = DragMode::None;
            return;
        }
        _hasAnchor = YES;
        _anchorCell = seed;
        _anchorFaceAxis = axis;
        _anchorMode = macvoxel::CurrentTool().mode;  // unused, kept for symmetry
        _anchorScreen = event.locationInWindow;
        _anchorTool = macvoxel::ToolKind::Face;
        _faceSign = sign;
        _faceSeedColor = color;
        _faceObservedDrag = NO;
        _faceAppliedD = 0;
        _faceAppliedWith = macvoxel::CurrentTool().face_with;
        const macvoxel::ToolState& t = macvoxel::CurrentTool();
        // FaceExtrudeKind::Geometry passes color=0 to the flood — that's
        // the "any non-empty cell" sentinel inside floodFaceFromCell:.
        const uint8_t flood_color =
            (t.face_extrude == macvoxel::FaceExtrudeKind::Color) ? color : 0;
        [self floodFaceFromCell:seed axis:axis sign:sign color:flood_color
              eightConnectivity:t.face_eight_connected
                         output:_faceSeedCells];
        _dragMode = DragMode::Shape;
        _hoverWindowPoint = event.locationInWindow;
        _hoverHasPoint = YES;
        // Render the click-as-1-layer preview immediately. As soon as the
        // user actually drags, refreshShapePreview will switch to using
        // the live drag distance.
        [self refreshShapePreview];
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
        case DragMode::Shape:
            // Re-render the live preview at the new cursor; the actual
            // history entry happens on mouseUp at the release point.
            _hoverWindowPoint = p;
            _hoverHasPoint = YES;
            [self refreshShapePreview];
            break;
        case DragMode::GenHandle: {
            // Project the cursor delta onto the dragged face's normal,
            // update bounds; the per-frame gizmo refresh picks up the
            // change and re-runs the engine.
            const int dv =
                [self genHandleDragVoxelsForFace:_genActiveDragFace
                                          cursor:p];
            [self applyGenHandleDelta:_genActiveDragFace deltaVoxels:dv];
            break;
        }
        case DragMode::None:  break;
    }
}

- (void)mouseUp:(NSEvent*)event {
    if (_dragMode == DragMode::Paint) {
        macvoxel::CurrentHistory().CommitOp();
    } else if (_dragMode == DragMode::GenHandle) {
        // Drag finished — leave bounds where the user released them and
        // stay in gizmo state. Active face goes back to "none" so the
        // arrow color clears.
        _dragMode = DragMode::None;
        _genActiveDragFace = -1;
    } else if (_dragMode == DragMode::Shape) {
        if (_anchorTool == macvoxel::ToolKind::Generator) {
            // Gizmo went live on mouseDown and refreshShapePreview kept
            // _genBounds in sync with the drag, so the box is already
            // in the right state. Just stop dragging and let the gizmo
            // hold position until the user commits, cancels, or grabs
            // a face handle.
            _dragMode = DragMode::None;
            _hasAnchor = NO;
        } else {
            // Wipe the live preview before the real commit so
            // stampBrushAtX: sees the original grid contents and writes
            // proper old/new pairs into EditHistory. Setting _dragMode
            // to None first routes the commit*AtPoint stamps through
            // the history branch.
            [self rollbackShapePreview];
            _dragMode = DragMode::None;
            switch (_anchorTool) {
                case macvoxel::ToolKind::Line:
                    [self commitLineAtPoint:event.locationInWindow]; break;
                case macvoxel::ToolKind::Circle:
                    [self commitCircleAtPoint:event.locationInWindow]; break;
                case macvoxel::ToolKind::Square:
                    [self commitSquareAtPoint:event.locationInWindow]; break;
                case macvoxel::ToolKind::Box:
                    [self commitBoxAtPoint:event.locationInWindow]; break;
                case macvoxel::ToolKind::Face:
                    [self commitFaceAtPoint:event.locationInWindow]; break;
                default: _hasAnchor = NO; break;
            }
        }
    }
    _dragMode = DragMode::None;
    _dragSkipCells.clear();
}

// Right-click drives camera orbit, middle (other) click drives pan. Both
// share the dragged-delta math in mouseDragged: by routing through the
// same _dragMode state machine — the dragged callbacks just forward to
// the left-button mouseDragged:, since the Orbit / Pan switch cases
// don't care which button generated the event.
- (void)rightMouseDown:(NSEvent*)event {
    if (ImGui::GetIO().WantCaptureMouse) {
        _dragMode = DragMode::None;
        return;
    }
    _dragMode = DragMode::Orbit;
    _lastDragLocation = event.locationInWindow;
}

- (void)rightMouseDragged:(NSEvent*)event {
    [self mouseDragged:event];
}

- (void)rightMouseUp:(NSEvent*)__unused event {
    if (_dragMode == DragMode::Orbit) _dragMode = DragMode::None;
}

- (void)otherMouseDown:(NSEvent*)event {
    if (ImGui::GetIO().WantCaptureMouse) {
        _dragMode = DragMode::None;
        return;
    }
    _dragMode = DragMode::Pan;
    _lastDragLocation = event.locationInWindow;
}

- (void)otherMouseDragged:(NSEvent*)event {
    [self mouseDragged:event];
}

- (void)otherMouseUp:(NSEvent*)__unused event {
    if (_dragMode == DragMode::Pan) _dragMode = DragMode::None;
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
    // Generator gizmo is the cursor indicator while it's live; the
    // would-place-cell wireframe would compete with it and read as
    // a stray duplicate.
    if (_genGizmoActive) return;

    const macvoxel::ToolState& t = macvoxel::CurrentTool();
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
    const BOOL ok = is_two_click
        ? [self computeLineEndpointAtPoint:_hoverWindowPoint mode:t.mode
                                      into:&cell face:nullptr]
        : [self computeTargetCellAtPoint:_hoverWindowPoint mode:t.mode
                                    into:&cell face:nullptr];
    if (!ok) return;
    [self drawCellWireAtX:cell.x y:cell.y z:cell.z color:color_for_mode(t.mode)];
}

- (void)drawSelectionOverlay {
    const macvoxel::Selection& sel = macvoxel::CurrentSelection();
    if (!sel.active || sel.box.empty()) return;

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
    {
        const simd::float3 box_min{static_cast<float>(sel.box.min_x),
                                   static_cast<float>(sel.box.min_y),
                                   static_cast<float>(sel.box.min_z)};
        const simd::float3 box_max{static_cast<float>(sel.box.max_x + 1),
                                   static_cast<float>(sel.box.max_y + 1),
                                   static_cast<float>(sel.box.max_z + 1)};
        ImVec2 screen[8];
        bool valid[8];
        project_corners(box_min, box_max, screen, valid);
        stroke_edges(screen, valid, kEdges, 12,
                     IM_COL32(255, 220, 80, 255), 1.5f);
    }

    if (sel.voxels.empty()) return;

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

    std::unordered_set<int64_t> selected_set;
    selected_set.reserve(sel.voxels.size() * 2);
    for (const auto& v : sel.voxels) {
        selected_set.insert(macvoxel::PackCellKey(v[0], v[1], v[2]));
    }

    const simd::float3 cam = _camera.Position();
    const ImU32 voxel_color = IM_COL32(255, 220, 80, 200);
    for (const auto& v : sel.voxels) {
        const simd::float3 cmin{static_cast<float>(v[0]),
                                static_cast<float>(v[1]),
                                static_cast<float>(v[2])};
        const simd::float3 cmax{cmin.x + 1.0f, cmin.y + 1.0f, cmin.z + 1.0f};
        ImVec2 screen[8];
        bool valid[8];
        project_corners(cmin, cmax, screen, valid);
        // Cell center in world space, used for the back-face cull.
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

// Generator gizmo overlay: 12-edge AABB outline around _genBounds plus
// 6 face-normal arrow handles. Hovering a handle highlights it; the
// actively-dragged handle gets the brightest tint. Click-tests for
// "is the cursor over a handle" use the same projected tip positions
// computed here, so visuals and hit-tests can't drift.
- (void)drawGenGizmo {
    if (!_genGizmoActive) return;
    const float w = static_cast<float>(self.bounds.size.width);
    const float h = static_cast<float>(self.bounds.size.height);
    if (w <= 0.0f || h <= 0.0f) return;
    const float aspect = w / h;
    const simd::float4x4 vp =
        _camera.ProjectionMatrix(aspect) * _camera.ViewMatrix();

    auto project = [&](simd::float3 wpos, ImVec2* screen, bool* valid) {
        const simd::float4 clip =
            simd_mul(vp, simd::float4{wpos.x, wpos.y, wpos.z, 1.0f});
        *valid = clip.w > 0.001f;
        if (!*valid) return;
        const float ndc_x = clip.x / clip.w;
        const float ndc_y = clip.y / clip.w;
        screen->x = (ndc_x * 0.5f + 0.5f) * w;
        screen->y = (1.0f - (ndc_y * 0.5f + 0.5f)) * h;
    };

    // Box outline. Voxels span [c, c+1] so outer surfaces sit at min..max+1.
    const float bx0 = static_cast<float>(_genBounds.x0);
    const float by0 = static_cast<float>(_genBounds.y0);
    const float bz0 = static_cast<float>(_genBounds.z0);
    const float bx1 = static_cast<float>(_genBounds.x1 + 1);
    const float by1 = static_cast<float>(_genBounds.y1 + 1);
    const float bz1 = static_cast<float>(_genBounds.z1 + 1);
    const simd::float3 corners_grid[8] = {
        {bx0, by0, bz0}, {bx1, by0, bz0},
        {bx1, by1, bz0}, {bx0, by1, bz0},
        {bx0, by0, bz1}, {bx1, by0, bz1},
        {bx1, by1, bz1}, {bx0, by1, bz1},
    };
    ImVec2 screen[8];
    bool valid[8];
    for (int i = 0; i < 8; ++i) {
        const simd::float3 g = corners_grid[i];
        project(simd::float3{g.x, g.z, -g.y}, &screen[i], &valid[i]);
    }
    static const int kEdges[12][2] = {
        {0, 1}, {1, 2}, {2, 3}, {3, 0},
        {4, 5}, {5, 6}, {6, 7}, {7, 4},
        {0, 4}, {1, 5}, {2, 6}, {3, 7},
    };
    ImDrawList* dl = ImGui::GetBackgroundDrawList();
    const ImU32 outline_color = IM_COL32(120, 200, 255, 230);
    for (int i = 0; i < 12; ++i) {
        const int a = kEdges[i][0];
        const int b = kEdges[i][1];
        if (!valid[a] || !valid[b]) continue;
        dl->AddLine(screen[a], screen[b], outline_color, 1.5f);
    }

    // Hover face: derived per-frame from the cursor unless we're
    // already mid-drag (then the dragged face is the "hovered" one,
    // visually). When a panel has captured the mouse, suppress hover
    // so the cursor over a tooltip doesn't paint a handle hot.
    int hover_face = -1;
    if (_dragMode == DragMode::GenHandle) {
        hover_face = _genActiveDragFace;
    } else if (_hoverHasPoint && !ImGui::GetIO().WantCaptureMouse) {
        hover_face = [self pickGenHandleAtPoint:_hoverWindowPoint];
    }

    constexpr float kTipLengthVoxels = 4.0f;
    constexpr float kArrowheadLenPx = 14.0f;
    constexpr float kArrowheadHalfWidthPx = 7.0f;
    // Standard X / Y / Z = red / green / blue, with brighter variants
    // for hover and active states. Both the +axis and -axis face share
    // their axis's color — position on the box disambiguates direction.
    const ImU32 kAxisBase[3] = {
        IM_COL32(230,  80,  80, 255),
        IM_COL32( 90, 200, 100, 255),
        IM_COL32( 90, 140, 240, 255),
    };
    const ImU32 kAxisHover[3] = {
        IM_COL32(255, 160, 160, 255),
        IM_COL32(170, 250, 180, 255),
        IM_COL32(160, 200, 255, 255),
    };
    const ImU32 kAxisActive[3] = {
        IM_COL32(255, 220, 220, 255),
        IM_COL32(220, 255, 230, 255),
        IM_COL32(220, 240, 255, 255),
    };

    for (int f = 0; f < 6; ++f) {
        simd::float3 cw, nw;
        GizmoFaceWorldGeom(_genBounds, f, &cw, &nw);
        ImVec2 base, tip;
        bool base_v, tip_v;
        project(cw, &base, &base_v);
        project(cw + nw * kTipLengthVoxels, &tip, &tip_v);
        if (!base_v || !tip_v) continue;

        const int axis = f / 2;
        const ImU32 color =
            (f == _genActiveDragFace) ? kAxisActive[axis] :
            (f == hover_face)         ? kAxisHover[axis]  :
                                        kAxisBase[axis];
        const float thickness = (f == hover_face || f == _genActiveDragFace)
                                    ? 2.8f : 2.0f;
        dl->AddLine(base, tip, color, thickness);

        // Solid filled-triangle arrowhead. The triangle's base sits at
        // `back` (pulled back along the stem from the tip by the
        // arrowhead length); leg1 / leg2 are perpendicular offsets in
        // screen space, so the arrowhead reads at consistent pixel
        // size regardless of camera distance.
        const float stem_dx = tip.x - base.x;
        const float stem_dy = tip.y - base.y;
        const float stem_len = std::sqrt(stem_dx * stem_dx +
                                         stem_dy * stem_dy);
        if (stem_len > 1e-3f) {
            const float ux = stem_dx / stem_len;
            const float uy = stem_dy / stem_len;
            const float px = -uy;   // perpendicular in screen space
            const float py =  ux;
            const ImVec2 back{
                tip.x - ux * kArrowheadLenPx,
                tip.y - uy * kArrowheadLenPx};
            const ImVec2 leg1{
                back.x + px * kArrowheadHalfWidthPx,
                back.y + py * kArrowheadHalfWidthPx};
            const ImVec2 leg2{
                back.x - px * kArrowheadHalfWidthPx,
                back.y - py * kArrowheadHalfWidthPx};
            dl->AddTriangleFilled(tip, leg1, leg2, color);
        }
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
                            into:(Vec3i*)out
                            face:(int*)out_face_axis {
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
    int face_axis = 2;  // ground-plane fallback faces +Z
    if (hit_voxel) {
        target_x = hit.x;
        target_y = hit.y;
        target_z = hit.z;
        if (hit.axis >= 0) face_axis = hit.axis;
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
    if (out_face_axis) *out_face_axis = face_axis;
    return YES;
}

- (void)performEditAtPoint:(NSPoint)windowPoint mode:(macvoxel::ToolMode)mode {
    Vec3i target;
    int face_axis = 2;
    if (![self computeTargetCellAtPoint:windowPoint mode:mode into:&target
                                   face:&face_axis]) {
        return;
    }

    // Drag-paint dedupe: only fire when the target cell changes. Without
    // this, every pointer-move event during a drag (many per frame) would
    // re-apply the brush to the same cell, which is harmless for Add but
    // bloats the undo history and can produce N²-style work for Paint.
    if (_dragMode == DragMode::Paint && SameCell(target, _lastDragEditCell)) {
        return;
    }
    _lastDragEditCell = target;

    [self stampBrushAtX:target.x y:target.y z:target.z
              faceAxis:face_axis mode:mode];
}

// Stamp the current brush footprint at a specific cell. Extracted from
// performEditAtPoint: so the Line tool can reuse it per voxel along the
// segment while passing its own face_axis (anchor's axis for Straight mode,
// per-step axis for Project mode).
- (void)stampBrushAtX:(int)target_x y:(int)target_y z:(int)target_z
             faceAxis:(int)face_axis mode:(macvoxel::ToolMode)mode {
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) return;

    macvoxel::ToolState& tool = macvoxel::CurrentTool();
    const int size = std::max(1, tool.brush_size);
    const int lo = -((size - 1) / 2);
    const int hi = size / 2;

    macvoxel::EditHistory& history = macvoxel::CurrentHistory();

    const BOOL track_skip = (_dragMode == DragMode::Paint &&
                             mode == macvoxel::ToolMode::Add);
    const BOOL preview = (_dragMode == DragMode::Shape);
    auto apply = [&](int x, int y, int z) {
        const uint8_t old_val = doc->grid.Get(x, y, z);
        const uint8_t new_val = ComputeNewCellValue(old_val, mode,
                                                    tool.palette_idx);
        if (new_val == old_val) return;
        doc->grid.Set(x, y, z, new_val);
        if (preview) {
            // Snapshot the original value the *first* time this cell is
            // touched during the drag; subsequent rollbacks restore that.
            // After a rollback, old_val is again the original here, so
            // try_emplace's no-overwrite-on-existing behavior is correct.
            const int64_t key = macvoxel::PackCellKey(x, y, z);
            _shapePreview.try_emplace(key, old_val);
        } else {
            history.Record(x, y, z, old_val, new_val);
            if (track_skip) {
                _dragSkipCells.insert(macvoxel::PackCellKey(x, y, z));
            }
        }
    };

    // Footprint shape combines BrushShape × dim:
    //  Square+3D = cube         |  Square+2D = slab on face plane
    //  Circle+3D = sphere       |  Circle+2D = disc on face plane
    // For 2D modes the plane axis is the face the user clicked
    // (face_axis); the brush is one cell thick along that axis.
    // Brush center: 0 for odd diameters, 0.5 for even diameters.
    // The fractional center on even sizes makes the footprint sit
    // between cells so it stays geometrically centered (and avoids
    // the cardinal-tip "widows" we used to hand-fudge with +0.5).
    const float c = (lo + hi) * 0.5f;
    const float r2 = (size * 0.5f) * (size * 0.5f);
    const bool is_3d = tool.brush_3d;
    const bool is_circle = tool.brush_shape == macvoxel::BrushShape::Circle;
    for (int dz = lo; dz <= hi; ++dz) {
        if (!is_3d && face_axis == 2 && dz != 0) continue;
        for (int dy = lo; dy <= hi; ++dy) {
            if (!is_3d && face_axis == 1 && dy != 0) continue;
            for (int dx = lo; dx <= hi; ++dx) {
                if (!is_3d && face_axis == 0 && dx != 0) continue;
                if (is_circle) {
                    float d2 = 0.0f;
                    if (is_3d || face_axis != 0) {
                        const float f = dx - c; d2 += f * f;
                    }
                    if (is_3d || face_axis != 1) {
                        const float f = dy - c; d2 += f * f;
                    }
                    if (is_3d || face_axis != 2) {
                        const float f = dz - c; d2 += f * f;
                    }
                    if (d2 > r2) continue;
                }
                apply(target_x + dx, target_y + dy, target_z + dz);
            }
        }
    }

    ++doc->version;
}

// Single-cell stamp pipeline for the Generator tool. Each cell from a
// generator kernel is a "this exact cell should be filled" instruction —
// brush size / shape / 2D / 3D options must NOT expand the footprint
// (the kernel already produced the final cell list). Routes to
// _shapePreview when `preview` is YES and EditHistory otherwise; the
// caller is expected to BeginOp/CommitOp around a non-preview batch.
- (void)stampGeneratorCells:(const std::vector<macvoxel::shapes::Vec3i>&)cells
                        mode:(macvoxel::ToolMode)mode
                     preview:(BOOL)preview {
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr || cells.empty()) return;

    const uint8_t palette_idx = macvoxel::CurrentTool().palette_idx;
    macvoxel::EditHistory& history = macvoxel::CurrentHistory();
    for (const macvoxel::shapes::Vec3i& c : cells) {
        const uint8_t old_val = doc->grid.Get(c.x, c.y, c.z);
        const uint8_t new_val = ComputeNewCellValue(old_val, mode, palette_idx);
        if (new_val == old_val) continue;
        doc->grid.Set(c.x, c.y, c.z, new_val);
        if (preview) {
            const int64_t key = macvoxel::PackCellKey(c.x, c.y, c.z);
            _shapePreview.try_emplace(key, old_val);
        } else {
            history.Record(c.x, c.y, c.z, old_val, new_val);
        }
    }
    ++doc->version;
}

// ---------------------------------------------------------------------------
// Line tool — two-click point-to-point. Click 1 stores an anchor; click 2
// enumerates the line and stamps the brush at every cell.
// ---------------------------------------------------------------------------

// Endpoint picker for the Line tool. Like computeTargetCellAtPoint: but
// also accepts empty-space clicks for Remove/Paint, falling through to the
// same ground-plane fallback Add uses. Lets the user anchor a Remove or
// Paint line on either side of the geometry it should pass through.
// Per-step picking inside Project mode keeps the strict picker so empty
// pixels between solid surfaces don't introduce phantom hits.
- (BOOL)computeLineEndpointAtPoint:(NSPoint)windowPoint
                              mode:(macvoxel::ToolMode)mode
                              into:(Vec3i*)out
                              face:(int*)out_face_axis {
    if ([self computeTargetCellAtPoint:windowPoint mode:mode into:out
                                  face:out_face_axis]) {
        return YES;
    }
    if (mode == macvoxel::ToolMode::Add) return NO;
    return [self computeTargetCellAtPoint:windowPoint
                                     mode:macvoxel::ToolMode::Add
                                     into:out face:out_face_axis];
}

- (void)enumerateLineFromAnchorTo:(NSPoint)cursor
                          straight:(BOOL)straight
                            output:(std::vector<LineHit>&)out {
    out.clear();
    if (!_hasAnchor) return;

    if (straight) {
        Vec3i endpoint;
        int end_face = _anchorFaceAxis;
        if (![self computeLineEndpointAtPoint:cursor mode:_anchorMode
                                         into:&endpoint face:&end_face]) {
            // Endpoint picker only fails when no usable cell exists at all
            // (e.g., camera looking up so the ground-plane fallback is
            // behind the camera). Show just the anchor.
            out.push_back({_anchorCell.x, _anchorCell.y,
                           _anchorCell.z, _anchorFaceAxis});
            return;
        }
        std::vector<Vec3i> cells;
        macvoxel::shapes::EnumerateLine(_anchorCell, endpoint, cells);
        out.reserve(cells.size());
        for (const Vec3i& c : cells) {
            out.push_back({c.x, c.y, c.z, _anchorFaceAxis});
        }
        return;
    }

    // Project mode: walk the screen-space segment from the anchor click
    // pixel to the cursor pixel, raycasting at each step. Each hit is the
    // cell a single Brush click at that pixel would have produced.
    const NSPoint s1 = _anchorScreen;
    const NSPoint s2 = cursor;
    const float dx = static_cast<float>(s2.x - s1.x);
    const float dy = static_cast<float>(s2.y - s1.y);
    // Oversample 2× so oblique screen-space lines don't skip voxels whose
    // projection sits between integer pixels.
    const int steps = std::max(1, static_cast<int>(
        2.0f * std::max(std::fabs(dx), std::fabs(dy))));
    std::unordered_set<int64_t> seen;
    seen.reserve(static_cast<size_t>(steps) + 1);
    for (int i = 0; i <= steps; ++i) {
        const float u = static_cast<float>(i) / static_cast<float>(steps);
        const NSPoint p{static_cast<CGFloat>(s1.x + dx * u),
                        static_cast<CGFloat>(s1.y + dy * u)};
        Vec3i cell;
        int face_axis = _anchorFaceAxis;
        if (![self computeTargetCellAtPoint:p mode:_anchorMode
                                       into:&cell face:&face_axis]) {
            continue;
        }
        const int64_t k = macvoxel::PackCellKey(cell.x, cell.y, cell.z);
        if (!seen.insert(k).second) continue;
        out.push_back({cell.x, cell.y, cell.z, face_axis});
    }
    // The anchor cell may not be among the per-step hits if the anchor
    // started on the ground-plane fallback while the first stepped pixels
    // hit different cells; ensure click 1's cell is always included so
    // the line endpoint always reads as placed.
    const int64_t anchor_k = macvoxel::PackCellKey(
        _anchorCell.x, _anchorCell.y, _anchorCell.z);
    if (seen.find(anchor_k) == seen.end()) {
        out.insert(out.begin(), {_anchorCell.x, _anchorCell.y,
                                 _anchorCell.z, _anchorFaceAxis});
    }
}

// Restore every cell touched by the live shape preview to its original
// value and drop the snapshot. Used between dragged frames to wipe the
// previous shape before re-stamping the new one, and on Esc / mouseUp
// before the final commit goes through the normal history path.
- (void)rollbackShapePreview {
    // Always reset the Face short-circuit cache: even if there's nothing
    // in `_shapePreview` to undo, the next refresh has to re-decide what
    // to apply rather than trusting a stale "already applied d" value.
    _faceAppliedD = 0;
    if (_shapePreview.empty()) return;
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) {
        _shapePreview.clear();
        return;
    }
    for (const auto& [key, orig] : _shapePreview) {
        int32_t x, y, z;
        macvoxel::UnpackCellKey(key, &x, &y, &z);
        doc->grid.Set(x, y, z, orig);
    }
    _shapePreview.clear();
    ++doc->version;
}

// Re-render the in-progress shape into the document at the current cursor.
// Each cell's original value is preserved in `_shapePreview` so the next
// frame can roll back. Stamps go through `stampBrushAtX:`, which detects
// `_dragMode == Shape` and routes writes to the preview path instead of
// EditHistory.
- (void)refreshShapePreview {
    if (!_hasAnchor || _dragMode != DragMode::Shape) return;

    // Face tool: drive the preview incrementally. Only the layers that
    // actually differ between the previous d and the new d get touched,
    // so dragging through layer boundaries costs O(seed_cells × Δd)
    // per frame rather than O(seed_cells × |d|).
    if (_anchorTool == macvoxel::ToolKind::Face) {
        // Click without drag previews as a single layer; once a non-zero
        // d has been observed the override stops applying so dragging
        // back to the anchor cleanly cancels.
        int d = [self faceDragVoxelsAtCursor:_hoverWindowPoint];
        if (d != 0) _faceObservedDrag = YES;
        if (d == 0 && !_faceObservedDrag) d = 1;
        // Remove/Paint don't care about drag sign — normalize to magnitude
        // so the short-circuit and the diff driver see equivalent gestures
        // as equivalent state.
        if (_anchorMode == macvoxel::ToolMode::Remove ||
            _anchorMode == macvoxel::ToolMode::Paint) {
            d = std::abs(d);
        }
        const macvoxel::ToolState& t = macvoxel::CurrentTool();
        if (d == _faceAppliedD && t.face_with == _faceAppliedWith) return;
        [self transitionFaceTo:d];
        return;
    }

    // Other shape tools: rebuild from scratch every refresh, since their
    // hit list is a continuous function of cursor position with no clean
    // discrete short-circuit.
    [self rollbackShapePreview];

    const macvoxel::ToolState& t = macvoxel::CurrentTool();
    std::vector<LineHit> hits;
    switch (_anchorTool) {
        case macvoxel::ToolKind::Line: {
            const BOOL straight =
                t.line_mode == macvoxel::LineMode::Straight;
            [self enumerateLineFromAnchorTo:_hoverWindowPoint
                                    straight:straight output:hits];
            break;
        }
        case macvoxel::ToolKind::Circle:
            [self enumerateCircleFromAnchorTo:_hoverWindowPoint
                                         fill:t.circle_fill
                                         even:t.circle_even
                                       output:hits];
            break;
        case macvoxel::ToolKind::Square:
            [self enumerateSquareFromAnchorTo:_hoverWindowPoint
                                         fill:t.square_fill
                                         even:t.square_even
                                       output:hits];
            break;
        case macvoxel::ToolKind::Box:
            [self enumerateBoxFromAnchorTo:_hoverWindowPoint
                                      fill:t.box_fill
                                    output:hits];
            break;
        case macvoxel::ToolKind::Generator: {
            // Engine emits final cells; brush footprint must NOT apply,
            // so this path bypasses the per-hit stampBrushAtX loop and
            // writes through stampGeneratorCells instead.
            Vec3i endpoint = _anchorCell;
            int end_face = _anchorFaceAxis;
            [self computeLineEndpointAtPoint:_hoverWindowPoint
                                        mode:_anchorMode
                                        into:&endpoint face:&end_face];
            macvoxel::generators::Bounds3i b{
                std::min(_anchorCell.x, endpoint.x),
                std::min(_anchorCell.y, endpoint.y),
                std::min(_anchorCell.z, endpoint.z),
                std::max(_anchorCell.x, endpoint.x),
                std::max(_anchorCell.y, endpoint.y),
                std::max(_anchorCell.z, endpoint.z),
            };
            macvoxel::generators::Params p =
                macvoxel::CurrentGeneratorState().params;
            p.palette_idx = macvoxel::CurrentTool().palette_idx;
            std::vector<macvoxel::shapes::Vec3i> cells;
            [_generatorEngine
                generateInto:cells
                        kind:macvoxel::CurrentGeneratorState().active_kind
                      bounds:b
                      params:p];
            [self stampGeneratorCells:cells mode:_anchorMode preview:YES];
            // Keep gizmo state synced with the drag so drawGenGizmo
            // sees the live bounds and the per-frame change-detector
            // doesn't redundantly re-fire on the next frame.
            _genBounds = b;
            _genLastKind = macvoxel::CurrentGeneratorState().active_kind;
            _genLastBounds = b;
            _genLastParams = p;
            return;
        }
        default: return;
    }
    for (const LineHit& h : hits) {
        [self stampBrushAtX:h.x y:h.y z:h.z faceAxis:h.face_axis
                       mode:_anchorMode];
    }
}

- (void)beginAnchorAtPoint:(NSPoint)windowPoint mode:(macvoxel::ToolMode)mode {
    Vec3i target;
    int face_axis = 2;
    if (![self computeLineEndpointAtPoint:windowPoint mode:mode into:&target
                                     face:&face_axis]) {
        return;
    }
    _hasAnchor = YES;
    _anchorCell = target;
    _anchorFaceAxis = face_axis;
    _anchorMode = mode;
    _anchorScreen = windowPoint;
    _anchorTool = macvoxel::CurrentTool().tool;
}

- (void)commitLineAtPoint:(NSPoint)windowPoint {
    if (!_hasAnchor) return;
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) { _hasAnchor = NO; return; }

    const BOOL straight =
        macvoxel::CurrentTool().line_mode == macvoxel::LineMode::Straight;
    std::vector<LineHit> hits;
    [self enumerateLineFromAnchorTo:windowPoint straight:straight output:hits];

    if (!hits.empty()) {
        macvoxel::CurrentHistory().BeginOp();
        for (const LineHit& h : hits) {
            [self stampBrushAtX:h.x y:h.y z:h.z faceAxis:h.face_axis
                           mode:_anchorMode];
        }
        macvoxel::CurrentHistory().CommitOp();
    }
    _hasAnchor = NO;
}

// ---------------------------------------------------------------------------
// Circle tool — two-click center-to-edge planar disc / ring.
// ---------------------------------------------------------------------------

- (void)enumerateCircleFromAnchorTo:(NSPoint)cursor
                                fill:(BOOL)fill
                                even:(BOOL)even
                              output:(std::vector<LineHit>&)out {
    out.clear();
    if (!_hasAnchor) return;

    Vec3i endpoint;
    int end_face = _anchorFaceAxis;
    if (![self computeLineEndpointAtPoint:cursor mode:_anchorMode
                                     into:&endpoint face:&end_face]) {
        out.push_back({_anchorCell.x, _anchorCell.y, _anchorCell.z,
                       _anchorFaceAxis});
        return;
    }

    std::vector<Vec3i> cells;
    macvoxel::shapes::EnumerateCirclePlanar(_anchorCell, endpoint,
                                            _anchorFaceAxis, fill, even,
                                            cells);
    out.reserve(cells.size());
    for (const Vec3i& c : cells) {
        out.push_back({c.x, c.y, c.z, _anchorFaceAxis});
    }
}

- (void)commitCircleAtPoint:(NSPoint)windowPoint {
    if (!_hasAnchor) return;
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) { _hasAnchor = NO; return; }

    const macvoxel::ToolState& tool = macvoxel::CurrentTool();
    std::vector<LineHit> hits;
    [self enumerateCircleFromAnchorTo:windowPoint
                                 fill:tool.circle_fill
                                 even:tool.circle_even
                               output:hits];

    if (!hits.empty()) {
        macvoxel::CurrentHistory().BeginOp();
        for (const LineHit& h : hits) {
            [self stampBrushAtX:h.x y:h.y z:h.z faceAxis:h.face_axis
                           mode:_anchorMode];
        }
        macvoxel::CurrentHistory().CommitOp();
    }
    _hasAnchor = NO;
}

// ---------------------------------------------------------------------------
// Square tool — two-click center-to-edge-midpoint planar square / frame.
// Same shape as the Circle tool but with a Chebyshev (max-norm) predicate
// instead of Euclidean. The cursor's offset from the anchor is interpreted
// as the *midpoint of an edge* of the square, so the half-side is the
// dominant axis of the offset (max(|du|, |dv|)) and the square is always
// centered on the anchor cell — distinguishing it from a Box tool where
// the cursor would be at one corner.
// ---------------------------------------------------------------------------

- (void)enumerateSquareFromAnchorTo:(NSPoint)cursor
                                fill:(BOOL)fill
                                even:(BOOL)even
                              output:(std::vector<LineHit>&)out {
    out.clear();
    if (!_hasAnchor) return;

    Vec3i endpoint;
    int end_face = _anchorFaceAxis;
    if (![self computeLineEndpointAtPoint:cursor mode:_anchorMode
                                     into:&endpoint face:&end_face]) {
        out.push_back({_anchorCell.x, _anchorCell.y, _anchorCell.z,
                       _anchorFaceAxis});
        return;
    }

    std::vector<Vec3i> cells;
    macvoxel::shapes::EnumerateSquarePlanar(_anchorCell, endpoint,
                                            _anchorFaceAxis, fill, even,
                                            cells);
    out.reserve(cells.size());
    for (const Vec3i& c : cells) {
        out.push_back({c.x, c.y, c.z, _anchorFaceAxis});
    }
}

- (void)commitSquareAtPoint:(NSPoint)windowPoint {
    if (!_hasAnchor) return;
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) { _hasAnchor = NO; return; }

    const macvoxel::ToolState& tool = macvoxel::CurrentTool();
    std::vector<LineHit> hits;
    [self enumerateSquareFromAnchorTo:windowPoint
                                 fill:tool.square_fill
                                 even:tool.square_even
                               output:hits];

    if (!hits.empty()) {
        macvoxel::CurrentHistory().BeginOp();
        for (const LineHit& h : hits) {
            [self stampBrushAtX:h.x y:h.y z:h.z faceAxis:h.face_axis
                           mode:_anchorMode];
        }
        macvoxel::CurrentHistory().CommitOp();
    }
    _hasAnchor = NO;
}

// ---------------------------------------------------------------------------
// Box tool — two-click corner-to-corner volumetric AABB / hollow shell.
// Shares the same endpoint picker as Line (raycast hit, ground-plane
// fallback), so click-in-empty-space drags the cursor along the ground
// plane and the box spans from the anchor's depth down to it.
// ---------------------------------------------------------------------------

- (void)enumerateBoxFromAnchorTo:(NSPoint)cursor
                             fill:(BOOL)fill
                           output:(std::vector<LineHit>&)out {
    out.clear();
    if (!_hasAnchor) return;

    Vec3i endpoint;
    int end_face = _anchorFaceAxis;
    if (![self computeLineEndpointAtPoint:cursor mode:_anchorMode
                                     into:&endpoint face:&end_face]) {
        out.push_back({_anchorCell.x, _anchorCell.y, _anchorCell.z,
                       _anchorFaceAxis});
        return;
    }

    std::vector<Vec3i> cells;
    macvoxel::shapes::EnumerateBox(_anchorCell, endpoint, fill, cells);
    out.reserve(cells.size());
    for (const Vec3i& c : cells) {
        out.push_back({c.x, c.y, c.z, _anchorFaceAxis});
    }
}

- (void)commitBoxAtPoint:(NSPoint)windowPoint {
    if (!_hasAnchor) return;
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) { _hasAnchor = NO; return; }

    const macvoxel::ToolState& tool = macvoxel::CurrentTool();
    std::vector<LineHit> hits;
    [self enumerateBoxFromAnchorTo:windowPoint fill:tool.box_fill
                            output:hits];

    if (!hits.empty()) {
        macvoxel::CurrentHistory().BeginOp();
        for (const LineHit& h : hits) {
            [self stampBrushAtX:h.x y:h.y z:h.z faceAxis:h.face_axis
                           mode:_anchorMode];
        }
        macvoxel::CurrentHistory().CommitOp();
    }
    _hasAnchor = NO;
}

// ---------------------------------------------------------------------------
// Generator tool — gizmo lifecycle. Activates on mouseDown (single-cell
// box at the anchor), grows during drag-out via refreshShapePreview's
// Generator case (which keeps _genBounds in sync), persists past
// mouseUp until the user commits, cancels (Esc / tool switch), or
// grabs a face handle. Stamping bypasses the brush-footprint expansion
// that stampBrushAtX: does for Line / Circle / Square / Box.
// ---------------------------------------------------------------------------

// Roll back the live preview, run the engine for the current bounds +
// kind + params, and re-stamp the result. Called whenever the gizmo
// config changes (kind / bounds / params) while gizmo is active.
- (void)refreshGenGizmoPreview {
    if (!_genGizmoActive) return;
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) return;

    [self rollbackShapePreview];

    macvoxel::generators::Params p = macvoxel::CurrentGeneratorState().params;
    p.palette_idx = macvoxel::CurrentTool().palette_idx;
    std::vector<macvoxel::shapes::Vec3i> cells;
    [_generatorEngine generateInto:cells
                              kind:macvoxel::CurrentGeneratorState().active_kind
                            bounds:_genBounds
                            params:p];
    [self stampGeneratorCells:cells
                         mode:macvoxel::CurrentTool().mode
                      preview:YES];
}

// Commit the current gizmo's preview through EditHistory as a single
// undo step, then exit gizmo state. The grid already shows the result
// (the preview is live), so we just need to record old/new pairs.
- (void)commitGenGizmo {
    if (!_genGizmoActive) return;
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) {
        _genGizmoActive = NO;
        _shapePreview.clear();
        return;
    }
    if (!_shapePreview.empty()) {
        macvoxel::EditHistory& history = macvoxel::CurrentHistory();
        history.BeginOp();
        for (const auto& [key, orig] : _shapePreview) {
            int32_t x, y, z;
            macvoxel::UnpackCellKey(key, &x, &y, &z);
            const uint8_t cur = doc->grid.Get(x, y, z);
            history.Record(x, y, z, orig, cur);
        }
        history.CommitOp();
    }
    _shapePreview.clear();
    _genGizmoActive = NO;
}

// Discard the current gizmo without writing to history. Restores every
// previewed cell to its pre-preview value. Also clears any in-progress
// face-handle drag so the next mouse event lands cleanly.
- (void)cancelGenGizmo {
    if (!_genGizmoActive) return;
    [self rollbackShapePreview];
    _genGizmoActive = NO;
    _genActiveDragFace = -1;
    if (_dragMode == DragMode::GenHandle) _dragMode = DragMode::None;
}

// Project each gizmo face's arrow tip into screen space and pick the
// face whose tip is closest to `windowPoint` within a 14-point click
// radius. Returns -1 if no handle is under the cursor. Faces whose tip
// projects behind the camera are skipped.
- (int)pickGenHandleAtPoint:(NSPoint)windowPoint {
    if (!_genGizmoActive) return -1;
    const float w = static_cast<float>(self.bounds.size.width);
    const float h = static_cast<float>(self.bounds.size.height);
    if (w <= 0.0f || h <= 0.0f) return -1;
    const float aspect = w / h;
    const simd::float4x4 vp =
        _camera.ProjectionMatrix(aspect) * _camera.ViewMatrix();

    const NSPoint local = [self convertPoint:windowPoint fromView:nil];
    const float cur_x = static_cast<float>(local.x);
    const float cur_y = static_cast<float>(h - local.y);  // ImGui Y-down

    // Match drawGenGizmo's stem length so the click target lines up
    // with the rendered arrow tip; the radius covers the full
    // 14-px-long arrowhead so any click on the visible arrow lands.
    constexpr float kTipLengthVoxels = 4.0f;
    constexpr float kHitRadiusPx = 16.0f;
    int best = -1;
    float best_d2 = kHitRadiusPx * kHitRadiusPx;
    for (int f = 0; f < 6; ++f) {
        simd::float3 cw, nw;
        GizmoFaceWorldGeom(_genBounds, f, &cw, &nw);
        const simd::float3 tip = cw + nw * kTipLengthVoxels;
        const simd::float4 clip = simd_mul(
            vp, simd::float4{tip.x, tip.y, tip.z, 1.0f});
        if (clip.w <= 0.001f) continue;
        const float ndc_x = clip.x / clip.w;
        const float ndc_y = clip.y / clip.w;
        const float sx = (ndc_x * 0.5f + 0.5f) * w;
        const float sy = (1.0f - (ndc_y * 0.5f + 0.5f)) * h;
        const float dx = sx - cur_x;
        const float dy = sy - cur_y;
        const float d2 = dx * dx + dy * dy;
        if (d2 < best_d2) {
            best_d2 = d2;
            best = f;
        }
    }
    return best;
}

// Convert a cursor delta from drag-start into a signed voxel count
// along face `face`'s normal. Same projection trick as the Face tool's
// faceDragVoxelsAtCursor:: build the NDC-space direction "1 voxel of
// normal travel" looks like, project the cursor delta onto it.
- (int)genHandleDragVoxelsForFace:(int)face cursor:(NSPoint)cursor {
    const float w = static_cast<float>(self.bounds.size.width);
    const float h = static_cast<float>(self.bounds.size.height);
    if (w <= 0.0f || h <= 0.0f) return 0;
    const float aspect = w / h;
    const simd::float4x4 vp =
        _camera.ProjectionMatrix(aspect) * _camera.ViewMatrix();

    simd::float3 cw, nw;
    GizmoFaceWorldGeom(_genHandleStartBounds, face, &cw, &nw);

    auto to_ndc = [&](simd::float3 wp, simd::float2* ndc) -> bool {
        const simd::float4 clip = simd_mul(
            vp, simd::float4{wp.x, wp.y, wp.z, 1.0f});
        if (clip.w <= 1e-6f) return false;
        ndc->x = clip.x / clip.w;
        ndc->y = clip.y / clip.w;
        return true;
    };
    simd::float2 ndc0{}, ndc1{};
    if (!to_ndc(cw, &ndc0)) return 0;
    if (!to_ndc(cw + nw, &ndc1)) return 0;
    const simd::float2 dir{ndc1.x - ndc0.x, ndc1.y - ndc0.y};
    const float dir_len2 = dir.x * dir.x + dir.y * dir.y;
    if (dir_len2 < 1e-8f) return 0;

    const NSPoint anchor_local =
        [self convertPoint:_genHandleStartCursor fromView:nil];
    const NSPoint cursor_local = [self convertPoint:cursor fromView:nil];
    const simd::float2 drag{
        static_cast<float>((cursor_local.x - anchor_local.x) / w * 2.0f),
        static_cast<float>((cursor_local.y - anchor_local.y) / h * 2.0f)};
    const float t = (drag.x * dir.x + drag.y * dir.y) / dir_len2;
    return static_cast<int>(std::round(t));
}

// Apply a drag delta (in voxels along the face normal) to the gizmo
// bounds. Positive delta moves the face outward; negative inward.
// Clamps against the opposite face so the box stays at least 1 voxel
// thick on each axis.
- (void)applyGenHandleDelta:(int)face deltaVoxels:(int)delta {
    int axis, sign;
    GenFaceAxisSign(face, &axis, &sign);
    macvoxel::generators::Bounds3i b = _genHandleStartBounds;
    if (axis == 0) {
        if (sign < 0) b.x0 = std::min(b.x1, b.x0 - delta);
        else          b.x1 = std::max(b.x0, b.x1 + delta);
    } else if (axis == 1) {
        if (sign < 0) b.y0 = std::min(b.y1, b.y0 - delta);
        else          b.y1 = std::max(b.y0, b.y1 + delta);
    } else {
        if (sign < 0) b.z0 = std::min(b.z1, b.z0 - delta);
        else          b.z1 = std::max(b.z0, b.z1 + delta);
    }
    _genBounds = b;
}

// ---------------------------------------------------------------------------
// Face tool — click selects a coplanar same-color flood region whose face
// on the clicked side is exposed; drag extrudes (positive, away from the
// surface) or insets (negative, into the surface) by an integer number
// of voxel layers along the face normal.
// ---------------------------------------------------------------------------

// Like computeTargetCellAtPoint:'s hit branch but exposes hit.sign too,
// since the Face tool needs both axis and sign of the clicked face.
- (BOOL)pickFaceAtPoint:(NSPoint)windowPoint
                  cell:(Vec3i*)outCell
                  axis:(int*)outAxis
                  sign:(int*)outSign
                 color:(uint8_t*)outColor {
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
    if (!macvoxel::Raycast(doc->grid, ray_origin_grid, ray_dir_grid,
                            4096.0f, &hit)) {
        return NO;
    }
    if (hit.axis < 0) return NO;  // ray started inside a voxel — no face
    outCell->x = hit.x;
    outCell->y = hit.y;
    outCell->z = hit.z;
    *outAxis = hit.axis;
    *outSign = hit.sign;
    if (outColor) *outColor = hit.color;
    return YES;
}

- (void)floodFaceFromCell:(Vec3i)seed
                     axis:(int)axis sign:(int)sign
                    color:(uint8_t)color
        eightConnectivity:(BOOL)eightConn
                   output:(std::vector<Vec3i>&)out {
    out.clear();
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) return;
    macvoxel::shapes::FloodCoplanarFace(doc->grid, seed, axis, sign, color,
                                        eightConn ? true : false, out);
}

// Convert the cursor's screen-space drag (relative to the click) into a
// signed integer voxel distance along the face normal. Projects the face
// normal into NDC at the anchor cell's depth — the drag is then scaled
// against that direction so one voxel of normal travel equals exactly the
// pixel distance the camera sees per voxel at that depth. Looking exactly
// edge-on to the face yields a degenerate direction and 0 voxels.
- (int)faceDragVoxelsAtCursor:(NSPoint)cursor {
    const float w = static_cast<float>(self.bounds.size.width);
    const float h = static_cast<float>(self.bounds.size.height);
    if (w <= 0 || h <= 0) return 0;
    const float aspect = w / h;
    const simd::float4x4 vp =
        _camera.ProjectionMatrix(aspect) * _camera.ViewMatrix();

    const simd::float3 p0_grid{
        static_cast<float>(_anchorCell.x) + 0.5f,
        static_cast<float>(_anchorCell.y) + 0.5f,
        static_cast<float>(_anchorCell.z) + 0.5f};
    const simd::float3 p0_world{p0_grid.x, p0_grid.z, -p0_grid.y};
    simd::float3 n_grid{0, 0, 0};
    if (_anchorFaceAxis == 0)      n_grid.x = static_cast<float>(_faceSign);
    else if (_anchorFaceAxis == 1) n_grid.y = static_cast<float>(_faceSign);
    else                            n_grid.z = static_cast<float>(_faceSign);
    const simd::float3 n_world{n_grid.x, n_grid.z, -n_grid.y};

    auto to_ndc = [&](simd::float3 wp, simd::float2* ndc) -> bool {
        const simd::float4 clip =
            simd_mul(vp, simd::float4{wp.x, wp.y, wp.z, 1.0f});
        if (clip.w <= 1e-6f) return false;
        ndc->x = clip.x / clip.w;
        ndc->y = clip.y / clip.w;
        return true;
    };
    simd::float2 ndc0{}, ndc1{};
    if (!to_ndc(p0_world, &ndc0)) return 0;
    if (!to_ndc(p0_world + n_world, &ndc1)) return 0;
    const simd::float2 dir{ndc1.x - ndc0.x, ndc1.y - ndc0.y};
    const float dir_len2 = dir.x * dir.x + dir.y * dir.y;
    if (dir_len2 < 1e-8f) return 0;

    const NSPoint anchor_local = [self convertPoint:_anchorScreen fromView:nil];
    const NSPoint cursor_local = [self convertPoint:cursor fromView:nil];
    const simd::float2 drag{
        static_cast<float>((cursor_local.x - anchor_local.x) / w * 2.0f),
        static_cast<float>((cursor_local.y - anchor_local.y) / h * 2.0f)};
    const float t = (drag.x * dir.x + drag.y * dir.y) / dir_len2;
    return static_cast<int>(std::round(t));
}

// Apply the extrusion / inset / paint to the document. Routes writes
// through the preview snapshot during DragMode::Shape (so each frame's
// preview can be rolled back) and directly through EditHistory otherwise.
//
// Mode dispatch (mode is frozen at click in `_anchorMode`):
//   Add    — signed d. Positive extrudes; negative insets (erases).
//            Extrude color comes from `face_with` (read live so the user
//            can flip Geometry/Palette mid-drag and see the change).
//   Remove — |d| layers, always inset (drag direction ignored).
//   Paint  — |d| inward layers, repaint existing voxels with the palette
//            color. Empty cells are skipped (Paint never fills).
- (void)applyFaceExtrusion:(int)d {
    if (d == 0 || _faceSeedCells.empty()) return;
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) return;

    int da[3] = {0, 0, 0};
    da[_anchorFaceAxis] = _faceSign;
    macvoxel::EditHistory& history = macvoxel::CurrentHistory();
    const BOOL preview = (_dragMode == DragMode::Shape);
    auto write = [&](int x, int y, int z, uint8_t new_val) {
        const uint8_t old_val = doc->grid.Get(x, y, z);
        if (new_val == old_val) return;
        doc->grid.Set(x, y, z, new_val);
        if (preview) {
            const int64_t key = macvoxel::PackCellKey(x, y, z);
            _shapePreview.try_emplace(key, old_val);
        } else {
            history.Record(x, y, z, old_val, new_val);
        }
    };

    const macvoxel::ToolState& tool = macvoxel::CurrentTool();
    const macvoxel::ToolMode mode = _anchorMode;
    const int n = std::abs(d);

    if (mode == macvoxel::ToolMode::Add && d > 0) {
        // Extrude outward: fill empty cells at offsets 1..d. Existing
        // geometry isn't overwritten (avoids surprising data loss).
        const BOOL with_geometry =
            (tool.face_with == macvoxel::FaceWithColor::Geometry);
        for (int k = 1; k <= d; ++k) {
            for (const Vec3i& v : _faceSeedCells) {
                const int x = v.x + k * da[0];
                const int y = v.y + k * da[1];
                const int z = v.z + k * da[2];
                if (doc->grid.Get(x, y, z) != 0) continue;
                const uint8_t color = with_geometry
                    ? doc->grid.Get(v.x, v.y, v.z)  // source cell color
                    : tool.palette_idx;
                write(x, y, z, color);
            }
        }
    } else if (mode == macvoxel::ToolMode::Add && d < 0) {
        // Inset (Add with negative drag): erase the seed plane and walk
        // |d| steps inward.
        for (int k = 0; k < n; ++k) {
            for (const Vec3i& v : _faceSeedCells) {
                const int x = v.x - k * da[0];
                const int y = v.y - k * da[1];
                const int z = v.z - k * da[2];
                write(x, y, z, 0);
            }
        }
    } else if (mode == macvoxel::ToolMode::Remove) {
        // Always inset, magnitude only — drag direction is ignored.
        for (int k = 0; k < n; ++k) {
            for (const Vec3i& v : _faceSeedCells) {
                const int x = v.x - k * da[0];
                const int y = v.y - k * da[1];
                const int z = v.z - k * da[2];
                write(x, y, z, 0);
            }
        }
    } else if (mode == macvoxel::ToolMode::Paint) {
        // Repaint existing voxels at the seed plane and |d|-1 layers in.
        // Skips empty cells (Paint mode never fills).
        for (int k = 0; k < n; ++k) {
            for (const Vec3i& v : _faceSeedCells) {
                const int x = v.x - k * da[0];
                const int y = v.y - k * da[1];
                const int z = v.z - k * da[2];
                if (doc->grid.Get(x, y, z) != 0) {
                    write(x, y, z, tool.palette_idx);
                }
            }
        }
    }
    ++doc->version;
}

// Apply or rollback a single Face-tool layer at `offset` along the face
// normal. These are the incremental hot-path helpers used during the
// live preview — they only touch one layer's worth of cells (seed_cells
// many) instead of the full O(seed × |d|) the bulk applyFaceExtrusion:
// would do. Always write to `_shapePreview` (preconditions: drag in
// progress with `_dragMode == DragMode::Shape`).
- (void)applyFaceLayerAtOffset:(int)offset {
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) return;

    int da[3] = {0, 0, 0};
    da[_anchorFaceAxis] = _faceSign;
    const macvoxel::ToolState& tool = macvoxel::CurrentTool();
    const macvoxel::ToolMode mode = _anchorMode;
    auto write = [&](int x, int y, int z, uint8_t new_val) {
        const uint8_t old_val = doc->grid.Get(x, y, z);
        if (new_val == old_val) return;
        doc->grid.Set(x, y, z, new_val);
        const int64_t key = macvoxel::PackCellKey(x, y, z);
        _shapePreview.try_emplace(key, old_val);
    };

    for (const Vec3i& v : _faceSeedCells) {
        const int x = v.x + offset * da[0];
        const int y = v.y + offset * da[1];
        const int z = v.z + offset * da[2];
        if (mode == macvoxel::ToolMode::Add && offset > 0) {
            if (doc->grid.Get(x, y, z) != 0) continue;
            const uint8_t color =
                (tool.face_with == macvoxel::FaceWithColor::Geometry)
                    ? doc->grid.Get(v.x, v.y, v.z)
                    : tool.palette_idx;
            write(x, y, z, color);
        } else if (mode == macvoxel::ToolMode::Add && offset <= 0) {
            write(x, y, z, 0);
        } else if (mode == macvoxel::ToolMode::Remove) {
            write(x, y, z, 0);
        } else if (mode == macvoxel::ToolMode::Paint) {
            if (doc->grid.Get(x, y, z) != 0) {
                write(x, y, z, tool.palette_idx);
            }
        }
    }
    ++doc->version;
}

- (void)rollbackFaceLayerAtOffset:(int)offset {
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) return;
    int da[3] = {0, 0, 0};
    da[_anchorFaceAxis] = _faceSign;
    for (const Vec3i& v : _faceSeedCells) {
        const int x = v.x + offset * da[0];
        const int y = v.y + offset * da[1];
        const int z = v.z + offset * da[2];
        const int64_t key = macvoxel::PackCellKey(x, y, z);
        auto it = _shapePreview.find(key);
        if (it == _shapePreview.end()) continue;
        doc->grid.Set(x, y, z, it->second);
        _shapePreview.erase(it);
    }
    ++doc->version;
}

// Move the Face preview from `_faceAppliedD` to `new_d` by adding /
// removing only the layers that differ. Falls back to a full rebuild
// when the preview's "direction" flips (Add positive ↔ negative drag)
// or `face_with` changes — those rarely happen during a drag, so the
// full-rebuild fallback's O(seed × |d|) cost is acceptable there.
//
// For Remove/Paint, `new_d` is expected pre-normalized to a non-negative
// magnitude (always inward), so a sign flip is impossible.
- (void)transitionFaceTo:(int)new_d {
    const macvoxel::ToolState& tool = macvoxel::CurrentTool();
    const macvoxel::ToolMode mode = _anchorMode;

    bool full_rebuild = false;
    if (mode == macvoxel::ToolMode::Add) {
        if (tool.face_with != _faceAppliedWith) full_rebuild = true;
        if (_faceAppliedD != 0 && new_d != 0 &&
            ((_faceAppliedD > 0) != (new_d > 0))) {
            full_rebuild = true;
        }
    }
    if (full_rebuild) {
        [self rollbackShapePreview];  // resets _faceAppliedD to 0
        [self applyFaceExtrusion:new_d];
        _faceAppliedD = new_d;
        _faceAppliedWith = tool.face_with;
        return;
    }

    const int abs_old = std::abs(_faceAppliedD);
    const int abs_new = std::abs(new_d);
    int dir_sign;  // +1 = outward (Add d>0), -1 = inward (Add d<0, Remove, Paint)
    if (mode == macvoxel::ToolMode::Add) {
        if (_faceAppliedD == 0 && new_d == 0) return;
        dir_sign = (_faceAppliedD != 0 ? _faceAppliedD : new_d) > 0 ? +1 : -1;
    } else {
        dir_sign = -1;
    }
    // Map a 0-based layer index to the offset along the face normal:
    //   outward  (idx 0,1,2,...)  → offsets +1, +2, +3, ...
    //   inward   (idx 0,1,2,...)  → offsets  0, -1, -2, ...
    auto offset_for_idx = [dir_sign](int idx) {
        return dir_sign > 0 ? idx + 1 : -idx;
    };

    if (abs_new > abs_old) {
        for (int idx = abs_old; idx < abs_new; ++idx) {
            [self applyFaceLayerAtOffset:offset_for_idx(idx)];
        }
    } else if (abs_new < abs_old) {
        for (int idx = abs_old - 1; idx >= abs_new; --idx) {
            [self rollbackFaceLayerAtOffset:offset_for_idx(idx)];
        }
    }
    _faceAppliedD = new_d;
    _faceAppliedWith = tool.face_with;
}

- (void)commitFaceAtPoint:(NSPoint)windowPoint {
    if (!_hasAnchor) { _faceSeedCells.clear(); return; }
    AppDelegate* delegate = (AppDelegate*)NSApp.delegate;
    macvoxel::Document* doc = [delegate document];
    if (doc == nullptr) {
        _hasAnchor = NO;
        _faceSeedCells.clear();
        return;
    }
    int d = [self faceDragVoxelsAtCursor:windowPoint];
    if (d != 0) _faceObservedDrag = YES;
    if (d == 0 && !_faceObservedDrag) d = 1;
    if (d != 0) {
        macvoxel::CurrentHistory().BeginOp();
        [self applyFaceExtrusion:d];
        macvoxel::CurrentHistory().CommitOp();
    }
    _hasAnchor = NO;
    _faceSeedCells.clear();
}

@end
