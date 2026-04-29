#import "AppDelegate.h"
#import "VoxelView.h"

#import <cstdio>

@implementation AppDelegate

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

- (void)applicationDidFinishLaunching:(NSNotification*)__unused notification {
    [self buildMainMenu];
    [self buildMainWindow];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)__unused sender {
    return YES;
}

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

- (void)buildMainWindow {
    const NSRect frame = NSMakeRect(0, 0, 1280, 800);
    const NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                    NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;

    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:style
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    [self.window setTitle:@"MacVoxel"];
    [self.window setReleasedWhenClosed:NO];

    VoxelView* view = [[VoxelView alloc] initWithFrame:frame];
    [self.window setContentView:view];
    [self.window makeFirstResponder:view];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
}

// ---------------------------------------------------------------------------
// Menu bar
// ---------------------------------------------------------------------------

- (void)buildMainMenu {
    NSMenu* mainMenu = [[NSMenu alloc] init];

    [mainMenu addItem:[self buildAppMenuItem]];
    [mainMenu addItem:[self buildFileMenuItem]];
    [mainMenu addItem:[self buildEditMenuItem]];
    [mainMenu addItem:[self buildViewMenuItem]];
    [mainMenu addItem:[self buildWindowMenuItem]];

    [NSApp setMainMenu:mainMenu];
}

- (NSMenuItem*)buildAppMenuItem {
    NSMenuItem* item = [[NSMenuItem alloc] init];
    NSMenu* menu = [[NSMenu alloc] init];
    NSString* appName = @"MacVoxel";

    [menu addItemWithTitle:[NSString stringWithFormat:@"About %@", appName]
                    action:@selector(orderFrontStandardAboutPanel:)
             keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenu* services = [[NSMenu alloc] init];
    NSMenuItem* servicesItem = [[NSMenuItem alloc] initWithTitle:@"Services"
                                                          action:nil
                                                   keyEquivalent:@""];
    [servicesItem setSubmenu:services];
    [menu addItem:servicesItem];
    [NSApp setServicesMenu:services];
    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:[NSString stringWithFormat:@"Hide %@", appName]
                    action:@selector(hide:)
             keyEquivalent:@"h"];
    NSMenuItem* hideOthers = [menu addItemWithTitle:@"Hide Others"
                                             action:@selector(hideOtherApplications:)
                                      keyEquivalent:@"h"];
    [hideOthers setKeyEquivalentModifierMask:NSEventModifierFlagCommand |
                                             NSEventModifierFlagOption];
    [menu addItemWithTitle:@"Show All"
                    action:@selector(unhideAllApplications:)
             keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
                    action:@selector(terminate:)
             keyEquivalent:@"q"];

    [item setSubmenu:menu];
    return item;
}

- (NSMenuItem*)buildFileMenuItem {
    NSMenuItem* item = [[NSMenuItem alloc] init];
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"File"];

    [menu addItemWithTitle:@"New" action:@selector(newDocument:) keyEquivalent:@"n"];
    [menu addItemWithTitle:@"Open…"
                    action:@selector(openDocument:)
             keyEquivalent:@"o"];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    [menu addItemWithTitle:@"Save" action:@selector(saveDocument:) keyEquivalent:@"s"];
    NSMenuItem* saveAs = [menu addItemWithTitle:@"Save As…"
                                         action:@selector(saveDocumentAs:)
                                  keyEquivalent:@"S"];
    [saveAs setKeyEquivalentModifierMask:NSEventModifierFlagCommand |
                                         NSEventModifierFlagShift];

    [item setSubmenu:menu];
    return item;
}

- (NSMenuItem*)buildEditMenuItem {
    NSMenuItem* item = [[NSMenuItem alloc] init];
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Edit"];

    [menu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    NSMenuItem* redo = [menu addItemWithTitle:@"Redo"
                                       action:@selector(redo:)
                                keyEquivalent:@"Z"];
    [redo setKeyEquivalentModifierMask:NSEventModifierFlagCommand |
                                       NSEventModifierFlagShift];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [menu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [menu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [menu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    [item setSubmenu:menu];
    return item;
}

- (NSMenuItem*)buildViewMenuItem {
    NSMenuItem* item = [[NSMenuItem alloc] init];
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"View"];
    [item setSubmenu:menu];
    return item;
}

- (NSMenuItem*)buildWindowMenuItem {
    NSMenuItem* item = [[NSMenuItem alloc] init];
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Window"];

    [menu addItemWithTitle:@"Minimize"
                    action:@selector(performMiniaturize:)
             keyEquivalent:@"m"];
    [menu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Bring All to Front"
                    action:@selector(arrangeInFront:)
             keyEquivalent:@""];

    [item setSubmenu:menu];
    [NSApp setWindowsMenu:menu];
    return item;
}

// ---------------------------------------------------------------------------
// Stub document actions (Phase 0: log only)
// ---------------------------------------------------------------------------

- (IBAction)newDocument:(id)__unused sender { fprintf(stderr, "[stub] File > New\n"); }
- (IBAction)openDocument:(id)__unused sender { fprintf(stderr, "[stub] File > Open\n"); }
- (IBAction)saveDocument:(id)__unused sender { fprintf(stderr, "[stub] File > Save\n"); }
- (IBAction)saveDocumentAs:(id)__unused sender { fprintf(stderr, "[stub] File > Save As\n"); }
- (IBAction)undo:(id)__unused sender { fprintf(stderr, "[stub] Edit > Undo\n"); }
- (IBAction)redo:(id)__unused sender { fprintf(stderr, "[stub] Edit > Redo\n"); }

@end
