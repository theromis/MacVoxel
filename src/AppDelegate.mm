#import "AppDelegate.h"
#import "VoxelView.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <cstdio>
#include <memory>

#include "Clipboard.h"
#include "Document.h"
#include "EditHistory.h"
#include "Selection.h"
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
    // Don't makeFirstResponder:view — ImGui's OSX backend installs a
    // hidden KeyEventResponder subview that needs to remain first
    // responder so keyDown events get absorbed and routed through
    // interpretKeyEvents: into ImGui's text input. Forcing the
    // VoxelView to be first responder leaves keystrokes unhandled
    // and produces system beeps when typing in ImGui input fields.
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

    NSMenuItem* undo = [menu addItemWithTitle:@"Undo"
                                       action:@selector(undo:)
                                keyEquivalent:@"z"];
    [undo setTarget:self];
    NSMenuItem* redo = [menu addItemWithTitle:@"Redo"
                                       action:@selector(redo:)
                                keyEquivalent:@"Z"];
    [redo setKeyEquivalentModifierMask:NSEventModifierFlagCommand |
                                       NSEventModifierFlagShift];
    [redo setTarget:self];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* cut = [menu addItemWithTitle:@"Cut"
                                      action:@selector(cut:)
                               keyEquivalent:@"x"];
    [cut setTarget:self];
    NSMenuItem* copy = [menu addItemWithTitle:@"Copy"
                                       action:@selector(copy:)
                                keyEquivalent:@"c"];
    [copy setTarget:self];
    NSMenuItem* paste = [menu addItemWithTitle:@"Paste"
                                        action:@selector(paste:)
                                 keyEquivalent:@"v"];
    [paste setTarget:self];
    NSMenuItem* del = [menu addItemWithTitle:@"Delete"
                                      action:@selector(deleteSelection:)
                               keyEquivalent:@"\b"];  // Backspace
    [del setKeyEquivalentModifierMask:0];
    [del setTarget:self];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* deselect = [menu addItemWithTitle:@"Deselect"
                                           action:@selector(deselect:)
                                    keyEquivalent:@"D"];
    [deselect setKeyEquivalentModifierMask:NSEventModifierFlagCommand |
                                           NSEventModifierFlagShift];
    [deselect setTarget:self];

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
    macvoxel::CurrentHistory().Clear();
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
    macvoxel::CurrentHistory().Clear();
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

- (IBAction)undo:(id)__unused sender {
    if (_doc == nullptr) return;
    if (macvoxel::CurrentHistory().Undo(_doc->grid)) {
        ++_doc->version;
    }
}

- (IBAction)redo:(id)__unused sender {
    if (_doc == nullptr) return;
    if (macvoxel::CurrentHistory().Redo(_doc->grid)) {
        ++_doc->version;
    }
}

// Grey items when their preconditions aren't met — standard Mac UX.
- (BOOL)validateMenuItem:(NSMenuItem*)item {
    const SEL action = item.action;
    if (action == @selector(undo:)) {
        return macvoxel::CurrentHistory().CanUndo();
    }
    if (action == @selector(redo:)) {
        return macvoxel::CurrentHistory().CanRedo();
    }
    if (action == @selector(cut:) || action == @selector(copy:) ||
        action == @selector(deleteSelection:) || action == @selector(deselect:)) {
        const macvoxel::Selection& sel = macvoxel::CurrentSelection();
        return sel.active && !sel.box.empty();
    }
    if (action == @selector(paste:)) {
        return !macvoxel::CurrentClipboard().empty();
    }
    return YES;
}

// ---------------------------------------------------------------------------
// Selection-aware Edit menu actions. Selection bounds drive what gets
// copied/cut/deleted; paste lands at the current selection's min corner
// (or origin if there's no selection). All cell-modifying paths go
// through CurrentHistory so they're undoable.
// ---------------------------------------------------------------------------

- (IBAction)copy:(id)__unused sender {
    if (_doc == nullptr) return;
    const macvoxel::Selection& sel = macvoxel::CurrentSelection();
    if (!sel.active || sel.box.empty()) return;
    macvoxel::Clipboard& cb = macvoxel::CurrentClipboard();
    cb.size_x = static_cast<uint32_t>(sel.box.size_x());
    cb.size_y = static_cast<uint32_t>(sel.box.size_y());
    cb.size_z = static_cast<uint32_t>(sel.box.size_z());
    cb.cells.assign(static_cast<size_t>(cb.size_x) * cb.size_y * cb.size_z, 0);
    for (uint32_t z = 0; z < cb.size_z; ++z) {
        for (uint32_t y = 0; y < cb.size_y; ++y) {
            for (uint32_t x = 0; x < cb.size_x; ++x) {
                const int32_t gx = sel.box.min_x + static_cast<int32_t>(x);
                const int32_t gy = sel.box.min_y + static_cast<int32_t>(y);
                const int32_t gz = sel.box.min_z + static_cast<int32_t>(z);
                cb.cells[cb.LinearIndex(x, y, z)] = _doc->grid.Get(gx, gy, gz);
            }
        }
    }
}

- (IBAction)cut:(id)sender {
    [self copy:sender];
    [self deleteSelection:sender];
}

- (IBAction)deleteSelection:(id)__unused sender {
    if (_doc == nullptr) return;
    const macvoxel::Selection& sel = macvoxel::CurrentSelection();
    if (!sel.active || sel.box.empty()) return;
    macvoxel::EditHistory& history = macvoxel::CurrentHistory();
    history.BeginOp();
    for (int32_t z = sel.box.min_z; z <= sel.box.max_z; ++z) {
        for (int32_t y = sel.box.min_y; y <= sel.box.max_y; ++y) {
            for (int32_t x = sel.box.min_x; x <= sel.box.max_x; ++x) {
                const uint8_t old = _doc->grid.Get(x, y, z);
                if (old != 0) {
                    _doc->grid.Set(x, y, z, 0);
                    history.Record(x, y, z, old, 0);
                }
            }
        }
    }
    history.CommitOp();
    ++_doc->version;
}

- (IBAction)paste:(id)__unused sender {
    if (_doc == nullptr) return;
    const macvoxel::Clipboard& cb = macvoxel::CurrentClipboard();
    if (cb.empty()) return;
    const macvoxel::Selection& sel = macvoxel::CurrentSelection();
    int32_t origin_x = 0, origin_y = 0, origin_z = 0;
    if (sel.active && !sel.box.empty()) {
        origin_x = sel.box.min_x;
        origin_y = sel.box.min_y;
        origin_z = sel.box.min_z;
    }
    macvoxel::EditHistory& history = macvoxel::CurrentHistory();
    history.BeginOp();
    for (uint32_t z = 0; z < cb.size_z; ++z) {
        for (uint32_t y = 0; y < cb.size_y; ++y) {
            for (uint32_t x = 0; x < cb.size_x; ++x) {
                const uint8_t v = cb.cells[cb.LinearIndex(x, y, z)];
                if (v == 0) continue;  // empty cells in the clipboard don't overwrite
                const int32_t gx = origin_x + static_cast<int32_t>(x);
                const int32_t gy = origin_y + static_cast<int32_t>(y);
                const int32_t gz = origin_z + static_cast<int32_t>(z);
                const uint8_t old = _doc->grid.Get(gx, gy, gz);
                if (old != v) {
                    _doc->grid.Set(gx, gy, gz, v);
                    history.Record(gx, gy, gz, old, v);
                }
            }
        }
    }
    history.CommitOp();
    ++_doc->version;
}

- (IBAction)deselect:(id)__unused sender {
    macvoxel::CurrentSelection().Clear();
}

@end
