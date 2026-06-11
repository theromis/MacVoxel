#import "MetalScene.h"

#import "BrushEngine.h"
#import "GeneratorEngine.h"
#import "LiftEngine.h"
#import "MutatorEngine.h"
#import "PathTraceRenderer.h"
#import "RaycastRenderer.h"
#import "SceneOverlayRenderer.h"
#import "ShapeEngine.h"
#import "VolumeTexture.h"

#import "swift/EditorContextBridge.h"
#import "swift/EditorContextBridge_Internal.h"

#import <Metal/Metal.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <cstdio>
#include <algorithm>

#include "BoxSelectController.h"
#include "Camera.h"
#include "CellKey.h"
#include "Document.h"
#include "EditHistory.h"
#include "EditorContext.h"
#include "FaceTool.h"
#include "FloodSelectController.h"
#include "GeneratorState.h"
#include "GeneratorTool.h"
#include "ToolRegistry.h"
#include "Input.h"
#include "InteractionState.h"
#include "MarqueeController.h"
#include "MoveSelectController.h"
#include "OverlayDraw.h"
#include "Raycast.h"
#include "RenderState.h"
#include "Selection.h"
#include "SelectionLift.h"
#include "SelectionOps.h"
#include "SelectionOverlay.h"
#include "EditEngine.h"
#include "Shapes.h"
#include "ToolState.h"
#include "ViewContext.h"
#include "XformHandleController.h"

#include <memory>

namespace {
using DragMode = macvoxel::DragMode;
using Vec3i = macvoxel::shapes::Vec3i;

// VK_Space (HIToolbox kVK_Space). Used to enable Pan via Space-drag.
constexpr unsigned short kKeyCodeSpace       = 49;
constexpr unsigned short kKeyCodeEscape      = 53;
constexpr unsigned short kKeyCodeReturn      = 36;
constexpr unsigned short kKeyCodeKeypadEnter = 76;
constexpr unsigned short kKeyCodeDelete      = 51;   // backspace
constexpr unsigned short kKeyCodeFwdDelete   = 117;
}  // namespace

@implementation MetalScene {
    macvoxel::EditorContext *_ctx;  // non-owning; bridge owns the unique_ptr.

    id<MTLCommandQueue> _commandQueue;
    RaycastRenderer *_raycastRenderer;
    PathTraceRenderer *_pathTraceRenderer;
    SceneOverlayRenderer *_overlayRenderer;
    GeneratorEngine *_generatorEngine;
    MutatorEngine *_mutatorEngine;
    LiftEngine *_liftEngine;
    BrushEngine *_brushEngine;
    ShapeEngine *_shapeEngine;
    // Per-document GPU mirror of the voxel grid. Both renderers and
    // the brush kernel bind it; the brush kernel writes through
    // access::read_write, the rasterizer fragment shader reads.
    VolumeTexture *_docVolumeTex;
    uint64_t _docVolumeTexCachedVersion;

    macvoxel::Camera _camera;
    NSTrackingArea *_trackingArea;

    // Tracks transitions for auto-committing the lift: tool switch /
    // entering render mode / etc. are "user moved on" gestures, so we
    // commit whatever's lifted before letting the new context see a
    // stale lift.
    macvoxel::ToolKind _lastToolForLift;
    macvoxel::RenderMode _lastModeForLift;
    macvoxel::RenderMode _lastRenderMode;

    // Modeling-side gesture state — drag mode + per-tool sub-structs.
    // See InteractionState.h for the breakdown.
    macvoxel::InteractionState _interaction;

    // Local key state. Replaces ImGui's IO key buffer for the two
    // keys the editor cares about: Space (held = pan modifier),
    // Escape (single-shot consumed each frame).
    BOOL _spaceHeld;
    BOOL _escapePending;

    // Re-used per frame to avoid allocator churn.
    macvoxel::OverlayDraw _od;

    // GPU façade hiding the four Obj-C engines from pure-C++ Tools.
    // Constructed in init once `_brushEngine` / `_shapeEngine` /
    // `_generatorEngine` / `_docVolumeTex` are alive.
    std::unique_ptr<macvoxel::EditEngine> _editEngine;

    // Per-tool gesture dispatch. The registry owns one of each
    // volume-writing Tool subclass; the dispatcher looks one up via
    // `ToolFor(_ctx->tool.tool)` at mouseDown and stashes the result
    // in `_activeTool` so mouseDragged / mouseUp route back to the
    // same Tool regardless of mid-stroke tool-kind changes. Selection
    // tools (Marquee / BoxSelect / etc.) are out of scope for this
    // refactor and keep their own per-controller branches below.
    std::unique_ptr<macvoxel::ToolRegistry> _toolRegistry;
    macvoxel::Tool *_activeTool;  // non-owning, may be nullptr
}

- (instancetype)initWithFrame:(NSRect)frame
                       bridge:(EditorContextBridge *)bridge {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) {
        std::fprintf(stderr, "MacVoxel: no Metal-capable device available\n");
        return nil;
    }

    self = [super initWithFrame:frame device:device];
    if (self == nil) return nil;

    _ctx = [bridge context];

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

    _raycastRenderer = [[RaycastRenderer alloc]
        initWithDevice:device
           colorFormat:self.colorPixelFormat
           depthFormat:self.depthStencilPixelFormat];
    if (_raycastRenderer == nil) return nil;

    _pathTraceRenderer = [[PathTraceRenderer alloc]
        initWithDevice:device colorFormat:self.colorPixelFormat];
    if (_pathTraceRenderer == nil) return nil;

    _overlayRenderer = [[SceneOverlayRenderer alloc]
        initWithDevice:device
           colorFormat:self.colorPixelFormat
           depthFormat:self.depthStencilPixelFormat];
    if (_overlayRenderer == nil) return nil;

    // Dedicated brush queue. Sharing with the rasterizer's
    // _commandQueue forces the brush's `waitUntilCompleted` to block
    // behind in-flight frame draws — the source of the 30–60 ms
    // dispatch spikes seen during a drag.
    id<MTLCommandQueue> brushQueue = [device newCommandQueue];
    brushQueue.label = @"MacVoxelBrushQueue";
    _brushEngine = [[BrushEngine alloc]
        initWithDevice:device commandQueue:brushQueue];
    if (_brushEngine == nil) return nil;

    // Generator shares the brush queue so its (slow) generate
    // dispatches are ordered before the commit_generic + readback that
    // ShapeEngine encodes — on a separate queue a Tree/Conifer pass
    // could still be writing tex_t while the commit reads it.
    _generatorEngine = [[GeneratorEngine alloc]
        initWithDevice:device commandQueue:brushQueue];
    if (_generatorEngine == nil) return nil;

    // Shape kernels share a queue with the brush — they're mutually
    // exclusive at the gesture level, and the dedicated queue keeps
    // them off the rasterizer's frame-draw critical path.
    _shapeEngine = [[ShapeEngine alloc]
        initWithDevice:device commandQueue:brushQueue];
    if (_shapeEngine == nil) return nil;

    // Mutator kernels share the same queue (also mutually exclusive at
    // gesture level with brush / shape / generator).
    _mutatorEngine = [[MutatorEngine alloc]
        initWithDevice:device commandQueue:brushQueue];
    if (_mutatorEngine == nil) return nil;

    // Lift kernel (selection finalize / translate / rotate / flip /
    // commit / cancel). Same queue as the others — lift mutations are
    // user-initiated and don't overlap with strokes.
    _liftEngine = [[LiftEngine alloc]
        initWithDevice:device commandQueue:brushQueue];
    if (_liftEngine == nil) return nil;

    _docVolumeTex = [[VolumeTexture alloc]
        initWithDevice:device
                volume:_ctx->document.volume_shadow];
    if (_docVolumeTex == nil) return nil;
    _docVolumeTexCachedVersion = 0;

    _editEngine = macvoxel::MakeEditEngine(_brushEngine, _shapeEngine,
                                           _generatorEngine, _mutatorEngine,
                                           _liftEngine,
                                           _docVolumeTex,
                                           _ctx->document.volume);
    // SelectionOps + bridge actions reach the GPU dispatch through
    // ctx.engine — same engine MetalScene owns.
    _ctx->engine = _editEngine.get();
    _toolRegistry = std::make_unique<macvoxel::ToolRegistry>();
    _activeTool = nullptr;

    _lastRenderMode = macvoxel::RenderMode::Edit;
    _lastToolForLift = _ctx->tool.tool;
    _lastModeForLift = _ctx->render_settings.mode;
    return self;
}

// ---------------------------------------------------------------------------
// Public helpers (called from the SwiftUI shell)
// ---------------------------------------------------------------------------

- (void)frameCameraToDocument {
    macvoxel::Document *doc = &_ctx->document;
    const macvoxel::Bounds3 b = doc->grid.Bounds();
    const int32_t maxExtent = std::max({b.size_x(), b.size_y(), b.size_z()});
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
    // Force a full re-sync of the doc texture from the (possibly new)
    // shadow on the next draw. VoxelVolume::Clear / ReseedVolumeShadow
    // already mark every chunk dirty; resetting the cached version
    // ensures the sync path actually fires.
    _docVolumeTexCachedVersion = 0;
}

- (BOOL)exportRenderToURL:(NSURL *)url error:(NSError **)error {
    if (url == nil) {
        if (error) *error = [NSError errorWithDomain:@"MacVoxel" code:10
            userInfo:@{NSLocalizedDescriptionKey: @"No URL provided."}];
        return NO;
    }
    const BOOL aces = _ctx->render_settings.aces_tonemap ? YES : NO;
    const BOOL denoise = _ctx->render_settings.denoise ? YES : NO;
    return [_pathTraceRenderer exportPNGToURL:url
                                  acesTonemap:aces
                                      denoise:denoise
                                 commandQueue:_commandQueue
                                        error:error];
}

// ---------------------------------------------------------------------------
// First responder. Unlike VoxelView (which deferred to ImGui's hidden
// KeyEventResponder), MetalScene needs to take key events directly so
// it can poll Space / Escape. SwiftUI panels still get key events
// when a TextField is focused — they live in a sibling view hierarchy
// and AppKit's responder chain handles the routing.
// ---------------------------------------------------------------------------

- (BOOL)acceptsFirstResponder { return YES; }

- (BOOL)canBecomeKeyView { return YES; }

// Absorb the keys we use as drag modifiers so they don't beep up the
// responder chain. Track Space / Escape state for ImGui-replacement.
// Plain (no-modifier) letter keys map to tool / mode quick-switches —
// these only reach us when MetalScene is first responder, so a focused
// TextField still gets its keystrokes.
- (void)keyDown:(NSEvent *)event {
    const unsigned short kc = event.keyCode;
    if (kc == kKeyCodeSpace) {
        _spaceHeld = YES;
        return;
    }
    if (kc == kKeyCodeEscape) {
        _escapePending = YES;
        return;
    }
    if (kc == kKeyCodeReturn || kc == kKeyCodeKeypadEnter) {
        if (_ctx->tool.tool == macvoxel::ToolKind::Generator &&
            _toolRegistry->generator()->HasActiveGizmo()) {
            _toolRegistry->generator()->Commit(*_ctx, _interaction,
                                                *_editEngine);
            _interaction.drag_mode = macvoxel::DragMode::None;
            _activeTool = nullptr;
            return;
        }
        if (_ctx->selection.lift_active()) {
            [self autoCommitLift];
            return;
        }
        // Nothing live to commit — fall through to super.
    }
    // Bare backspace deletes the lifted selection only while the 3D
    // view is first responder; the menu equivalent is Cmd+Delete so
    // text fields keep their backspace.
    if (kc == kKeyCodeDelete || kc == kKeyCodeFwdDelete) {
        if (_ctx->selection.lift_active()) {
            macvoxel::lift::DeleteLift(*_ctx);
            return;
        }
    }
    const NSEventModifierFlags m = event.modifierFlags &
        (NSEventModifierFlagCommand |
         NSEventModifierFlagOption |
         NSEventModifierFlagControl);
    if (m == 0) {
        NSString *chars = event.charactersIgnoringModifiers;
        if (chars.length == 1) {
            using K = macvoxel::ToolKind;
            using M = macvoxel::ToolMode;
            const unichar c = [chars characterAtIndex:0];
            switch (c) {
            case 'v': case 'V': _ctx->tool.tool = K::Brush;   return;
            case 'l': case 'L': _ctx->tool.tool = K::Line;    return;
            case 'b': case 'B': _ctx->tool.tool = K::Box;     return;
            case 'f': case 'F': _ctx->tool.tool = K::Face;    return;
            case 'u': case 'U': _ctx->tool.tool = K::Mutator; return;
            case 'm': case 'M': _ctx->tool.tool = K::Marquee; return;
            case 't': case 'T': _ctx->tool.mode = M::Add;     return;
            case 'r': case 'R': _ctx->tool.mode = M::Remove;  return;
            case 'g': case 'G': _ctx->tool.mode = M::Paint;   return;
            }
        }
    }
    [super keyDown:event];
}

- (void)keyUp:(NSEvent *)event {
    if (event.keyCode == kKeyCodeSpace) {
        _spaceHeld = NO;
        return;
    }
    [super keyUp:event];
}

// ---------------------------------------------------------------------------
// Tracking area + hover bookkeeping
// ---------------------------------------------------------------------------

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

- (void)mouseMoved:(NSEvent *)event {
    _interaction.hover.local = [self localFromWindow:event.locationInWindow];
    _interaction.hover.has_point = YES;
}

- (void)mouseExited:(NSEvent *)__unused event {
    _interaction.hover.has_point = NO;
}

// ---------------------------------------------------------------------------
// View-context + input helpers
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

- (macvoxel::MouseEvent)mouseEventFromNSEvent:(NSEvent *)event {
    const NSPoint w = event.locationInWindow;
    const simd::float2 local = [self localFromWindow:w];
    const NSEventModifierFlags m = event.modifierFlags;
    macvoxel::MouseEvent out;
    out.window = simd::float2{static_cast<float>(w.x), static_cast<float>(w.y)};
    out.local = local;
    out.mods.option  = (m & NSEventModifierFlagOption)  != 0;
    out.mods.command = (m & NSEventModifierFlagCommand) != 0;
    out.mods.shift   = (m & NSEventModifierFlagShift)   != 0;
    out.mods.control = (m & NSEventModifierFlagControl) != 0;
    return out;
}

- (void)autoCommitLift {
    if (!_ctx->selection.lift_active()) return;
    macvoxel::lift::CommitLift(*_ctx);
}

// Eyedropper: cast a ray from the click into the grid; if it hits a
// non-empty voxel, copy that voxel's palette index into the active
// slot. Misses leave the palette unchanged.
- (BOOL)eyedropperAtPoint:(NSPoint)windowPoint {
    macvoxel::Document *doc = &_ctx->document;
    const simd::float2 lp = [self localFromWindow:windowPoint];
    simd::float3 ray_origin, ray_dir;
    if (![self viewContext].RayAt(lp.x, lp.y, &ray_origin, &ray_dir)) return NO;
    macvoxel::RayHit hit;
    if (!macvoxel::Raycast(doc->grid, ray_origin, ray_dir, 4096.0f, &hit)) return NO;
    if (hit.color == 0) return NO;
    macvoxel::ToolSettings &tool = _ctx->tool;
    tool.palette_idx = hit.color;
    tool.selected_slots.reset();
    tool.selected_slots.set(hit.color);
    return YES;
}

// ---------------------------------------------------------------------------
// MTKViewDelegate
// ---------------------------------------------------------------------------

- (void)mtkView:(MTKView *)__unused view drawableSizeWillChange:(CGSize)__unused size {
    // No-op; viewport size is read from self.bounds each frame.
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (pass == nil || drawable == nil) return;

    // Abort an in-flight drag on Escape or when the tool switched out
    // from under it. Tool::Cancel clears the tool's preview-texture
    // cells and closes its history op — without it the stale
    // tex_t/preview_rem cells get promoted into the doc by the next
    // overlapping commit. Generator self-cancels in its Tick.
    const BOOL escape_now = _escapePending;
    _escapePending = NO;
    if (_activeTool != nullptr &&
        _activeTool != _toolRegistry->generator() &&
        (escape_now ||
         _toolRegistry->ToolFor(_ctx->tool.tool) != _activeTool)) {
        _activeTool->Cancel(*_ctx, _interaction, *_editEngine);
        _activeTool = nullptr;
        _interaction.drag_mode = DragMode::None;
    }
    // Cancel a pending two-click anchor the same way — the anchoring
    // tool's Cancel clears its preview bbox and the anchor flag.
    if (_interaction.anchor.has_anchor) {
        if (_ctx->tool.tool != _interaction.anchor.tool || escape_now) {
            macvoxel::Tool *anchored =
                _toolRegistry->ToolFor(_interaction.anchor.tool);
            if (anchored != nullptr && anchored != _toolRegistry->generator()) {
                anchored->Cancel(*_ctx, _interaction, *_editEngine);
            }
            _interaction.anchor.has_anchor = NO;
            if (_interaction.drag_mode == DragMode::Shape) {
                _interaction.drag_mode = DragMode::None;
            }
        }
    }

    // Per-frame Tick on every Tool. Currently only Generator does
    // anything in Tick (gizmo dirty-check / cancel-on-Esc); others
    // default to no-op.
    _toolRegistry->TickAll(*_ctx, _interaction, [self viewContext],
                            _ctx->tool.tool, escape_now, *_editEngine);

    // Auto-commit the active lift on "user moved on" gestures
    // detectable from the per-frame loop: tool switch and render-mode
    // toggle. (Other paths — save / open / new / deselect — handle
    // it themselves through bridge actions.)
    {
        const macvoxel::ToolKind cur_tool = _ctx->tool.tool;
        const macvoxel::RenderMode cur_mode = _ctx->render_settings.mode;
        if (_ctx->selection.lift_active()) {
            const bool entering_render =
                cur_mode != macvoxel::RenderMode::Edit &&
                _lastModeForLift == macvoxel::RenderMode::Edit;
            if (cur_tool != _lastToolForLift || entering_render) {
                macvoxel::lift::CommitLift(*_ctx);
            }
        }
        _lastToolForLift = cur_tool;
        _lastModeForLift = cur_mode;
    }

    // Build the overlay command list for this frame. The overlays draw
    // *over* the rendered scene, so we collect first and encode after.
    _od.Clear();
    const bool mouse_captured_by_ui = false;  // wired in Phase D when
                                              // SwiftUI panels arrive.
    const macvoxel::ViewContext vc = [self viewContext];
    macvoxel::selection_overlay::DrawSelection(vc, _od);
    macvoxel::xform_handle_controller::DrawOverlay(
        _interaction, vc, _od, mouse_captured_by_ui);
    macvoxel::marquee_controller::DrawOverlay(_interaction, vc, _od);
    macvoxel::selection_overlay::DrawHover(
        _interaction, vc, mouse_captured_by_ui, _od);
    _toolRegistry->DrawOverlays(_interaction, vc, _od, mouse_captured_by_ui);

    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
    cmd.label = @"MacVoxel Frame";

    const macvoxel::RenderMode mode_now = _ctx->render_settings.mode;
    if (mode_now != _lastRenderMode) {
        // Toggling between modes invalidates whatever the PT engine
        // had accumulated, so the user never sees stale pixels from
        // the previous mode on the way back in.
        [_pathTraceRenderer invalidate];
        _lastRenderMode = mode_now;
    }

    const CGSize ds = view.drawableSize;
    const simd::float2 viewport_pixels = {
        static_cast<float>(self.bounds.size.width),
        static_cast<float>(self.bounds.size.height),
    };

    if (mode_now == macvoxel::RenderMode::Render) {
        // Path-traced: the renderer handles its own accumulation +
        // display passes. Overlay draws into a follow-up encoder
        // sharing the same drawable's render-pass descriptor.
        [_pathTraceRenderer renderInView:view
                                     cmd:cmd
                                 context:_ctx
                                  camera:_camera];

        if (!_od.empty()) {
            MTLRenderPassDescriptor *overlayPass =
                [MTLRenderPassDescriptor renderPassDescriptor];
            overlayPass.colorAttachments[0].texture = drawable.texture;
            overlayPass.colorAttachments[0].loadAction = MTLLoadActionLoad;
            overlayPass.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> enc =
                [cmd renderCommandEncoderWithDescriptor:overlayPass];
            enc.label = @"Overlay (over PT)";
            [_overlayRenderer encodeWithEncoder:enc
                                        overlay:_od
                                   viewportSize:viewport_pixels
                                       hasDepth:NO];
            [enc endEncoding];
        }
    } else {
        // Realtime ray-cast renderer + overlay share one render encoder.
        const float aspect = ds.height > 0
                                 ? static_cast<float>(ds.width / ds.height)
                                 : 1.0f;
        const simd::float4x4 viewMat = _camera.ViewMatrix();
        const simd::float4x4 projMat = _camera.ProjectionMatrix(aspect);

        // Sync the doc texture from CPU shadow on geometry_version
        // change. Skipped when the GPU was the authoritative writer
        // (brush kernel) — those edits drain the shadow's dirty
        // chunks post-dispatch so this finds nothing to upload.
        if (_docVolumeTexCachedVersion != _ctx->document.geometry_version) {
            [_docVolumeTex syncFromVolume:_ctx->document.volume_shadow];
            _docVolumeTexCachedVersion = _ctx->document.geometry_version;
        }
        // The lift's GPU state (tex_lift) is mutated directly by lift
        // kernels — no CPU mirror to sync. The bbox outline drawn by
        // SelectionOverlay reads sel.bounds() each frame.

        id<MTLRenderCommandEncoder> enc =
            [cmd renderCommandEncoderWithDescriptor:pass];
        enc.label = @"MacVoxel Pass";
        [_raycastRenderer encodeWithEncoder:enc
                                       view:viewMat
                                 projection:projMat
                                cameraWorld:_camera.Position()
                                    context:_ctx
                              volumeTexture:_docVolumeTex];
        if (!_od.empty()) {
            [_overlayRenderer encodeWithEncoder:enc
                                        overlay:_od
                                   viewportSize:viewport_pixels
                                       hasDepth:YES];
        }
        [enc endEncoding];
    }

    [cmd presentDrawable:drawable];
    [cmd commit];
}

// ---------------------------------------------------------------------------
// Mouse input. mouse_captured_by_ui is hardcoded false for Phase B
// (no SwiftUI panels yet); Phase D will route a real flag from the
// SwiftUI side via the bridge.
// ---------------------------------------------------------------------------

- (void)mouseDown:(NSEvent *)event {
    const NSEventModifierFlags m = event.modifierFlags;
    const BOOL hasOption  = (m & NSEventModifierFlagOption)  != 0;
    const BOOL hasCommand = (m & NSEventModifierFlagCommand) != 0;

    // Option + left-click = eyedropper. Side-action only.
    if (hasOption) {
        [self eyedropperAtPoint:event.locationInWindow];
        _interaction.drag_mode = DragMode::None;
        return;
    }
    // Space + left-click = pan (one-button-mouse alt for middle-click).
    if (_spaceHeld) {
        _interaction.drag_mode = DragMode::Pan;
        _interaction.last_drag_location = event.locationInWindow;
        return;
    }
    // Active generator gizmo intercepts every click regardless of which
    // tool is currently selected.
    if (_toolRegistry->generator()->HasActiveGizmo()) {
        _toolRegistry->generator()->OnMouseDown(*_ctx, _interaction,
                                                  [self viewContext],
                                                  [self mouseEventFromNSEvent:event],
                                                  *_editEngine);
        _activeTool = _toolRegistry->generator();
        return;
    }
    if (macvoxel::xform_handle_controller::OnMouseDown(
            *_ctx, _interaction, [self viewContext],
            [self mouseEventFromNSEvent:event])) {
        return;  // click consumed by the transform-gizmo face arrow
    }
    if (hasCommand &&
        (_ctx->tool.tool == macvoxel::ToolKind::Marquee ||
         _ctx->tool.tool == macvoxel::ToolKind::BoxSelect ||
         _ctx->tool.tool == macvoxel::ToolKind::FloodSelect) &&
        macvoxel::move_select_controller::OnMouseDown(
            *_ctx, _interaction, [self viewContext],
            [self mouseEventFromNSEvent:event])) {
        return;  // Cmd-drag on a selected voxel
    }
    // Selection tools (Marquee / BoxSelect / FloodSelect) aren't
    // registered with ToolRegistry; they don't write to the volume,
    // they manipulate the selection. Out of scope for this refactor.
    if (_ctx->tool.tool == macvoxel::ToolKind::Marquee) {
        [self autoCommitLift];
        macvoxel::marquee_controller::OnMouseDown(
            _interaction, [self mouseEventFromNSEvent:event]);
        return;
    }
    if (_ctx->tool.tool == macvoxel::ToolKind::BoxSelect) {
        [self autoCommitLift];
        if (!macvoxel::box_select_controller::OnMouseDown(
                *_ctx, _interaction, [self viewContext],
                [self mouseEventFromNSEvent:event])) {
            _interaction.drag_mode = DragMode::None;
        }
        return;
    }
    if (_ctx->tool.tool == macvoxel::ToolKind::FloodSelect) {
        [self autoCommitLift];
        macvoxel::flood_select_controller::OnMouseDown(
            *_ctx, [self viewContext], [self mouseEventFromNSEvent:event]);
        _interaction.drag_mode = DragMode::None;
        return;
    }

    // Volume-writing tools route through the registry.
    macvoxel::Tool *tool = _toolRegistry->ToolFor(_ctx->tool.tool);
    if (tool == nullptr) {
        _interaction.drag_mode = DragMode::None;
        return;
    }
    [self autoCommitLift];
    const macvoxel::MouseEvent me = [self mouseEventFromNSEvent:event];
    if (tool->OnMouseDown(*_ctx, _interaction, [self viewContext], me,
                          *_editEngine)) {
        _interaction.hover.local = [self localFromWindow:event.locationInWindow];
        _interaction.hover.has_point = YES;
        _activeTool = tool;
    } else {
        _interaction.drag_mode = DragMode::None;
        _activeTool = nullptr;
    }
}

- (void)mouseDragged:(NSEvent *)event {
    if (_interaction.drag_mode == DragMode::None) return;
    const NSPoint p = event.locationInWindow;
    const float dx = static_cast<float>(p.x - _interaction.last_drag_location.x);
    const float dy = static_cast<float>(p.y - _interaction.last_drag_location.y);
    _interaction.last_drag_location = p;

    switch (_interaction.drag_mode) {
        case DragMode::Orbit: _camera.Orbit(dx, dy); break;
        case DragMode::Pan:   _camera.Pan(dx, dy);   break;
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
        case DragMode::Paint:
        case DragMode::Shape:
        case DragMode::GenHandle:
            // Hover follow during shape drag (lets DrawOverlay highlight
            // handles + lets the controller see the live cursor).
            if (_interaction.drag_mode == DragMode::Shape) {
                _interaction.hover.local = [self localFromWindow:p];
                _interaction.hover.has_point = YES;
            }
            if (_activeTool) {
                _activeTool->OnMouseDragged(*_ctx, _interaction,
                                             [self viewContext],
                                             [self mouseEventFromNSEvent:event],
                                             *_editEngine);
            }
            break;
        case DragMode::None: break;
    }
}

- (void)mouseUp:(NSEvent *)event {
    switch (_interaction.drag_mode) {
        case DragMode::Marquee:
            macvoxel::marquee_controller::OnMouseUp(
                *_ctx, _interaction.marquee, [self viewContext],
                [self mouseEventFromNSEvent:event]);
            break;
        case DragMode::BoxSelect:
            macvoxel::box_select_controller::OnMouseUp(*_ctx);
            break;
        case DragMode::MoveSelect:
            // No-op — the drag itself was the work; release just ends it.
            break;
        case DragMode::XformHandle:
            macvoxel::xform_handle_controller::OnMouseUp(_interaction);
            break;
        case DragMode::Paint:
        case DragMode::Shape:
        case DragMode::GenHandle:
            if (_activeTool) {
                _activeTool->OnMouseUp(*_ctx, _interaction, [self viewContext],
                                        [self mouseEventFromNSEvent:event],
                                        *_editEngine);
            }
            break;
        case DragMode::Orbit:
        case DragMode::Pan:
        case DragMode::None:
            break;
    }
    _activeTool = nullptr;
    _interaction.drag_mode = DragMode::None;
}

// Right-click drives camera orbit, middle (other) click drives pan.
// Both share the dragged-delta math in mouseDragged: by routing
// through _interaction.drag_mode.
- (void)rightMouseDown:(NSEvent *)event {
    _interaction.drag_mode = DragMode::Orbit;
    _interaction.last_drag_location = event.locationInWindow;
}

- (void)rightMouseDragged:(NSEvent *)event { [self mouseDragged:event]; }

- (void)rightMouseUp:(NSEvent *)__unused event {
    if (_interaction.drag_mode == DragMode::Orbit) _interaction.drag_mode = DragMode::None;
}

- (void)otherMouseDown:(NSEvent *)event {
    _interaction.drag_mode = DragMode::Pan;
    _interaction.last_drag_location = event.locationInWindow;
}

- (void)otherMouseDragged:(NSEvent *)event { [self mouseDragged:event]; }

- (void)otherMouseUp:(NSEvent *)__unused event {
    if (_interaction.drag_mode == DragMode::Pan) _interaction.drag_mode = DragMode::None;
}

- (void)scrollWheel:(NSEvent *)event {
    const float ticks = static_cast<float>(event.scrollingDeltaY) * 0.1f;
    _camera.Zoom(ticks);
}

- (void)magnifyWithEvent:(NSEvent *)event {
    _camera.Zoom(static_cast<float>(event.magnification) * 8.0f);
}

@end
