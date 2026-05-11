#pragma once

#import <MetalKit/MetalKit.h>

#import "swift/EditorContextBridge.h"

// 3-D scene NSView for the SwiftUI shell. MTKView subclass that owns
// the Metal command queue, the raycast / path-trace / generator
// renderers, the editor camera, and the per-tool gesture controllers'
// shared InteractionState. Per-frame work composes the renderer pass
// (raycast or path-trace) with a native Metal overlay pass driven by
// SceneOverlayRenderer, so no ImGui code path remains.
//
// Wrapped from Swift via MetalSceneView (NSViewRepresentable). The
// EditorContextBridge is the only handle Swift sees; the C++
// EditorContext is reached internally via [bridge context] (declared
// in EditorContextBridge_Internal.h, Obj-C++-only).
@interface MetalScene : MTKView <MTKViewDelegate>

- (instancetype)initWithFrame:(NSRect)frame
                       bridge:(EditorContextBridge *)bridge;

// Reset the camera to fit the current document's bounds. Call when
// the document is intentionally replaced (New, Open) — not on edits,
// which would visually yank the camera out from under the user.
- (void)frameCameraToDocument;

// Drop both renderers' caches. Call when the document object is
// replaced wholesale (load, new). The raycast renderer's incremental
// dirty-chunk path can't tell when a chunk has been removed from the
// document, so without this, chunks from the previous file linger on
// the GPU as zombies.
- (void)invalidateRenderers;

@end
