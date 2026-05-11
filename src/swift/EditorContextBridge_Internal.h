#pragma once

#import "EditorContextBridge.h"

namespace macvoxel { struct EditorContext; }

// Obj-C++-only category exposing the underlying C++ context. Included
// by Obj-C++ callers (MetalScene, controllers' dispatcher) but never
// reaches Swift — the Swift bridging header only pulls in
// EditorContextBridge.h.
@interface EditorContextBridge ()

// Non-owning pointer to the underlying context. Stable for the
// bridge's lifetime; never store past it.
- (macvoxel::EditorContext *)context;

@end
