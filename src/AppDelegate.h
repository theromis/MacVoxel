#pragma once

#import <Cocoa/Cocoa.h>

namespace macvoxel { struct EditorContext; }

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow* window;

// Owned editor context — single-document app, single instance for the
// app's lifetime. Views, panels, and edit ops receive it by pointer
// from here. Never null after applicationWillFinishLaunching: returns.
- (macvoxel::EditorContext*)context;

@end
