#import "MetalScene.h"

#import "GeneratorEngine.h"
#import "PathTraceRenderer.h"
#import "RaycastRenderer.h"
#import "SceneOverlayRenderer.h"

#import "swift/EditorContextBridge.h"
#import "swift/EditorContextBridge_Internal.h"

#import <Metal/Metal.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <cstdio>
#include <algorithm>

#include "BoxSelectController.h"
#include "BrushController.h"
#include "BrushOps.h"
#include "Camera.h"
#include "CellKey.h"
#include "Document.h"
#include "EditHistory.h"
#include "EditorContext.h"
#include "FaceController.h"
#include "FloatingBuffer.h"
#include "FloatingBufferOps.h"
#include "FloodSelectController.h"
#include "GeneratorController.h"
#include "GeneratorState.h"
#include "Input.h"
#include "InteractionState.h"
#include "MarqueeController.h"
#include "MoveSelectController.h"
#include "OverlayDraw.h"
#include "PreviewOps.h"
#include "PreviewOverlay.h"
#include "Raycast.h"
#include "RenderState.h"
#include "Selection.h"
#include "SelectionOps.h"
#include "SelectionOverlay.h"
#include "ShapeController.h"
#include "Shapes.h"
#include "ToolState.h"
#include "ViewContext.h"
#include "XformHandleController.h"

namespace {
using DragMode = macvoxel::DragMode;
using Vec3i = macvoxel::shapes::Vec3i;

// VK_Space (HIToolbox kVK_Space). Used to enable Pan via Space-drag.
constexpr unsigned short kKeyCodeSpace  = 49;
constexpr unsigned short kKeyCodeEscape = 53;
}  // namespace

@implementation MetalScene {
    macvoxel::EditorContext *_ctx;  // non-owning; bridge owns the unique_ptr.

    id<MTLCommandQueue> _commandQueue;
    RaycastRenderer *_raycastRenderer;
    PathTraceRenderer *_pathTraceRenderer;
    SceneOverlayRenderer *_overlayRenderer;
    GeneratorEngine *_generatorEngine;

    macvoxel::Camera _camera;
    NSTrackingArea *_trackingArea;

    // Tracks transitions for auto-committing the floating buffer:
    // tool switch / entering render mode / etc. are "user moved on"
    // gestures, so we drop whatever's floating before letting the new
    // context see a stale buffer.
    macvoxel::ToolKind _lastToolForFB;
    bool _lastPathTracedForFB;
    bool _wasPathTraced;

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
        initWithDevice:device colorFormat:self.colorPixelFormat];
    if (_overlayRenderer == nil) return nil;

    _generatorEngine = [[GeneratorEngine alloc]
        initWithDevice:device commandQueue:_commandQueue];
    if (_generatorEngine == nil) return nil;

    _interaction.gen_gizmo.active_drag_face = -1;  // 0 means -X face — explicit nil.
    _wasPathTraced = NO;
    _lastToolForFB = _ctx->tool.tool;
    _lastPathTracedForFB = _ctx->render_settings.path_traced;
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
}

- (BOOL)exportRenderToURL:(NSURL *)url error:(NSError **)error {
    if (url == nil) {
        if (error) *error = [NSError errorWithDomain:@"MacVoxel" code:10
            userInfo:@{NSLocalizedDescriptionKey: @"No URL provided."}];
        return NO;
    }
    const BOOL aces = _ctx->render_settings.aces_tonemap ? YES : NO;
    return [_pathTraceRenderer exportPNGToURL:url
                                  acesTonemap:aces
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

- (macvoxel::generator_controller::GenerateFn)generateFn {
    GeneratorEngine *engine = _generatorEngine;
    return [engine](macvoxel::generators::Kind kind,
                    macvoxel::generators::Bounds3i bounds,
                    macvoxel::generators::Params params,
                    std::vector<macvoxel::shapes::Vec3i> &out) {
        [engine generateInto:out kind:kind bounds:bounds params:params];
    };
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

- (void)autoCommitFloatingBuffer {
    if (!_ctx->floating_buffer.active) return;
    macvoxel::CommitFloatingBuffer(*_ctx);
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

    // Cancel a pending shape anchor on Escape or when the user
    // switches tools mid-stroke. Same intent as the old VoxelView
    // version; Escape comes from _escapePending now instead of ImGui.
    const BOOL escape_now = _escapePending;
    _escapePending = NO;
    if (_interaction.anchor.has_anchor) {
        if (_ctx->tool.tool != _interaction.anchor.tool || escape_now) {
            if (_interaction.drag_mode == DragMode::Shape) {
                _ctx->preview.Clear();
                _interaction.drag_mode = DragMode::None;
            }
            _interaction.anchor.has_anchor = NO;
            _interaction.face.seed_cells.clear();
        }
    }

    // Generator gizmo per-frame tick: cancel on Esc / tool-switch and
    // re-run the engine on kind / bounds / params / palette dirtying.
    macvoxel::generator_controller::Tick(
        *_ctx, _interaction, _ctx->tool.tool, escape_now,
        [self generateFn]);

    // Auto-commit the floating buffer on "user moved on" gestures
    // detectable from the per-frame loop: tool switch and render-mode
    // toggle. (Other paths — save / open / new / deselect — handle
    // it themselves through bridge actions.)
    {
        macvoxel::FloatingBuffer &fb_t = _ctx->floating_buffer;
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
    macvoxel::generator_controller::DrawOverlay(
        _interaction, vc, _od, mouse_captured_by_ui);

    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
    cmd.label = @"MacVoxel Frame";

    const bool pt_now = _ctx->render_settings.path_traced;
    if (pt_now != _wasPathTraced) {
        // Toggling either direction invalidates whatever the path
        // tracer had accumulated (or wants to start fresh on enable).
        [_pathTraceRenderer invalidate];
        _wasPathTraced = pt_now;
    }

    const CGSize ds = view.drawableSize;
    const simd::float2 viewport_pixels = {
        static_cast<float>(self.bounds.size.width),
        static_cast<float>(self.bounds.size.height),
    };

    if (pt_now) {
        // Path-traced: PathTraceRenderer handles its own accumulation
        // + display passes. Overlay draws into a follow-up encoder
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
                                   viewportSize:viewport_pixels];
            [enc endEncoding];
        }
    } else {
        // Realtime ray-cast renderer + overlay share one render encoder.
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
        if (!_od.empty()) {
            [_overlayRenderer encodeWithEncoder:enc
                                        overlay:_od
                                   viewportSize:viewport_pixels];
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
        _interaction.brush.last_drag_location = event.locationInWindow;
        return;
    }
    if (_interaction.gen_gizmo.active) {
        macvoxel::generator_controller::OnGizmoClick(
            *_ctx, _interaction, [self viewContext],
            [self mouseEventFromNSEvent:event]);
    } else if (macvoxel::xform_handle_controller::OnMouseDown(
                   *_ctx, _interaction, [self viewContext],
                   [self mouseEventFromNSEvent:event])) {
        // Click on a transform-gizmo face arrow.
    } else if (hasCommand &&
               (_ctx->tool.tool == macvoxel::ToolKind::Marquee ||
                _ctx->tool.tool == macvoxel::ToolKind::BoxSelect ||
                _ctx->tool.tool == macvoxel::ToolKind::FloodSelect) &&
               macvoxel::move_select_controller::OnMouseDown(
                   *_ctx, _interaction, [self viewContext],
                   [self mouseEventFromNSEvent:event])) {
        // Cmd-drag on a selected voxel.
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

- (void)mouseDragged:(NSEvent *)event {
    if (_interaction.drag_mode == DragMode::None) return;
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
        case DragMode::None: break;
    }
}

- (void)mouseUp:(NSEvent *)event {
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

// Right-click drives camera orbit, middle (other) click drives pan.
// Both share the dragged-delta math in mouseDragged: by routing
// through _interaction.drag_mode.
- (void)rightMouseDown:(NSEvent *)event {
    _interaction.drag_mode = DragMode::Orbit;
    _interaction.brush.last_drag_location = event.locationInWindow;
}

- (void)rightMouseDragged:(NSEvent *)event { [self mouseDragged:event]; }

- (void)rightMouseUp:(NSEvent *)__unused event {
    if (_interaction.drag_mode == DragMode::Orbit) _interaction.drag_mode = DragMode::None;
}

- (void)otherMouseDown:(NSEvent *)event {
    _interaction.drag_mode = DragMode::Pan;
    _interaction.brush.last_drag_location = event.locationInWindow;
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
