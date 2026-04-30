#pragma once

#import <Cocoa/Cocoa.h>

namespace macvoxel { struct Document; }

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow* window;

// Opaque pointer for views/panels that need to read or display the
// current document. Lifetime is the AppDelegate's; never null after
// applicationDidFinishLaunching: returns.
- (macvoxel::Document*)document;

@end
