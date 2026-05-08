#pragma once

#import <MetalKit/MetalKit.h>

@interface VoxelView : MTKView <MTKViewDelegate>

// Tear down ImGui state. Must be called while the view's Metal device is
// still alive — typically from -[NSApplicationDelegate applicationWillTerminate:].
- (void)shutdownImGui;

// Reset the camera to fit the current document's bounds. Called when the
// document is intentionally replaced (New, Open) — not on edits, which
// would visually yank the camera out from under the user.
- (void)frameCameraToDocument;

// Drop both renderers' caches. Call when the document object is
// replaced wholesale (load, new). The raycast renderer's incremental
// dirty-chunk path can't tell when a chunk has been removed from the
// document, so without this, chunks from the previous file linger on
// the GPU as zombies.
- (void)invalidateRenderers;

@end
