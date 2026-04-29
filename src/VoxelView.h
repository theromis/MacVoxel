#pragma once

#import <MetalKit/MetalKit.h>

@interface VoxelView : MTKView <MTKViewDelegate>

// Tear down ImGui state. Must be called while the view's Metal device is
// still alive — typically from -[NSApplicationDelegate applicationWillTerminate:].
- (void)shutdownImGui;

@end
