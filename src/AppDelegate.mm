#import "AppDelegate.h"
#import "VoxelView.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <cstdio>
#include <memory>

#include "Document.h"
#include "VoxFile.h"
#include "ui/ModelPanel.h"

@implementation AppDelegate {
    std::unique_ptr<macvoxel::Document> _doc;
}

- (macvoxel::Document*)document {
    return _doc.get();
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

- (void)applicationDidFinishLaunching:(NSNotification*)__unused notification {
    _doc = std::make_unique<macvoxel::Document>();
    _doc->grid.Set(0, 0, 0, 1);  // single voxel so the panel has something to count
    _doc->version = 1;

    [self buildMainMenu];
    [self buildMainWindow];
    [self updateWindowTitle];
    [self frameCameraIfPossible];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)frameCameraIfPossible {
    VoxelView* view = (VoxelView*)self.window.contentView;
    if ([view isKindOfClass:[VoxelView class]]) {
        [view frameCameraToDocument];
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)__unused sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification*)__unused notification {
    // Tear down ImGui while the view (and its Metal device) is still alive.
    VoxelView* view = (VoxelView*)self.window.contentView;
    if ([view isKindOfClass:[VoxelView class]]) {
        [view shutdownImGui];
    }
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

    [menu addItemWithTitle:@"Show ImGui Demo"
                    action:@selector(toggleImGuiDemo:)
             keyEquivalent:@"d"];

    [item setSubmenu:menu];
    return item;
}

- (IBAction)toggleImGuiDemo:(id)__unused sender {
    macvoxel::ToggleImGuiDemoWindow();
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
// Document actions
// ---------------------------------------------------------------------------

- (void)updateWindowTitle {
    if (_doc->path.empty()) {
        [self.window setTitle:@"MacVoxel — Untitled"];
        [self.window setRepresentedFilename:@""];
    } else {
        NSString* p = [NSString stringWithUTF8String:_doc->path.c_str()];
        [self.window setTitleWithRepresentedFilename:p];
    }
}

- (void)showAlertTitle:(NSString*)title message:(NSString*)msg {
    NSAlert* a = [[NSAlert alloc] init];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = title;
    a.informativeText = msg;
    [a addButtonWithTitle:@"OK"];
    [a runModal];
}

- (NSArray<UTType*>*)voxContentTypes {
    UTType* t = [UTType typeWithFilenameExtension:@"vox"];
    return t ? @[t] : @[];
}

- (IBAction)newDocument:(id)__unused sender {
    _doc->grid.Clear();
    _doc->grid.Set(0, 0, 0, 1);
    _doc->palette.ResetToDefault();
    _doc->path.clear();
    ++_doc->version;
    [self updateWindowTitle];
    [self frameCameraIfPossible];
}

- (IBAction)openDocument:(id)__unused sender {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = [self voxContentTypes];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    if ([panel runModal] != NSModalResponseOK) return;
    NSURL* url = panel.URL;
    if (url == nil) return;

    const std::string path = [[url path] UTF8String];
    macvoxel::Document fresh;
    std::string err;
    if (!macvoxel::LoadVox(path, &fresh.grid, &fresh.palette, &err)) {
        [self showAlertTitle:@"Open Failed"
                     message:[NSString stringWithUTF8String:err.c_str()]];
        return;
    }
    fresh.path = path;
    fresh.version = _doc->version + 1;
    *_doc = std::move(fresh);
    [self updateWindowTitle];
    [self frameCameraIfPossible];
}

- (IBAction)saveDocument:(id)sender {
    if (_doc->path.empty()) {
        [self saveDocumentAs:sender];
        return;
    }
    std::string err;
    if (!macvoxel::SaveVox(_doc->path, _doc->grid, _doc->palette, &err)) {
        [self showAlertTitle:@"Save Failed"
                     message:[NSString stringWithUTF8String:err.c_str()]];
    }
}

- (IBAction)saveDocumentAs:(id)__unused sender {
    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = [self voxContentTypes];
    panel.nameFieldStringValue = @"Untitled.vox";
    if ([panel runModal] != NSModalResponseOK) return;
    NSURL* url = panel.URL;
    if (url == nil) return;

    const std::string path = [[url path] UTF8String];
    std::string err;
    if (!macvoxel::SaveVox(path, _doc->grid, _doc->palette, &err)) {
        [self showAlertTitle:@"Save Failed"
                     message:[NSString stringWithUTF8String:err.c_str()]];
        return;
    }
    _doc->path = path;
    [self updateWindowTitle];
}

- (IBAction)undo:(id)__unused sender { fprintf(stderr, "[stub] Edit > Undo\n"); }
- (IBAction)redo:(id)__unused sender { fprintf(stderr, "[stub] Edit > Redo\n"); }

@end
