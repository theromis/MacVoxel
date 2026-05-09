#import "AppDelegate.h"
#import "VoxelView.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <cstdio>
#include <memory>

#include "Clipboard.h"
#include "Document.h"
#include "EditHistory.h"
#include "FloatingBuffer.h"
#include "FloatingBufferOps.h"
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

// Document setup runs in willFinishLaunching: so it's complete before
// AppKit dispatches application:openURLs: for files passed at cold-
// launch (Finder Open With, drag-onto-icon). Without this split, the
// open-URL fired before _doc existed, openDocumentAtURL: bailed, and
// the user got default.vox instead of the file they asked for.
- (void)applicationWillFinishLaunching:(NSNotification*)__unused notification {
    _doc = std::make_unique<macvoxel::Document>();
    [self seedDocumentFromDefault];
    _doc->version = 1;
}

- (void)applicationDidFinishLaunching:(NSNotification*)__unused notification {
    [self buildMainMenu];
    [self buildMainWindow];
    [self updateWindowTitle];
    [self frameCameraIfPossible];
    [NSApp activateIgnoringOtherApps:YES];
}

// Replace the document's grid + palette with resources/default.vox if it
// bundled successfully. The document remains "Untitled" — path is left
// empty so the first save prompts for a destination. Falls back to a
// single seed voxel if the bundle is missing the resource (development
// builds, or a corrupted .app).
- (void)seedDocumentFromDefault {
    NSString* path = [[NSBundle mainBundle] pathForResource:@"default"
                                                     ofType:@"vox"];
    if (path != nil) {
        const std::string p = [path UTF8String];
        std::string err;
        if (macvoxel::LoadVox(p, &_doc->grid, &_doc->palette, &err)) {
            return;
        }
        fprintf(stderr,
                "MacVoxel: failed to load bundled default.vox (%s); "
                "falling back to single-voxel seed\n", err.c_str());
    }
    _doc->grid.Clear();
    _doc->grid.Set(0, 0, 0, 1);
    _doc->palette.ResetToDefault();
}

- (void)frameCameraIfPossible {
    VoxelView* view = (VoxelView*)self.window.contentView;
    if ([view isKindOfClass:[VoxelView class]]) {
        [view frameCameraToDocument];
    }
}

// No-op when the window hasn't been built yet — cold-launch via
// application:openURLs: replaces the doc before the window exists,
// and that's fine: the renderers don't have any cached state yet
// because they haven't run a frame.
- (void)invalidateRenderersIfPossible {
    VoxelView* view = (VoxelView*)self.window.contentView;
    if ([view isKindOfClass:[VoxelView class]]) {
        [view invalidateRenderers];
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

    // Open Recent submenu — AppKit auto-injects the recent files list
    // above the "Clear Menu" item. Population is driven by our
    // noteNewRecentDocumentURL: calls in openDocumentAtURL: and
    // saveDocumentAs:. clearRecentDocuments: routes through the
    // responder chain to NSDocumentController; target=nil suffices.
    NSMenuItem* openRecentItem = [menu addItemWithTitle:@"Open Recent"
                                                  action:nil
                                           keyEquivalent:@""];
    NSMenu* recentMenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
    [recentMenu addItemWithTitle:@"Clear Menu"
                          action:@selector(clearRecentDocuments:)
                   keyEquivalent:@""];
    [openRecentItem setSubmenu:recentMenu];

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
    // The floating buffer references _doc via its grid storage; tearing
    // _doc out from under it would leave a stale singleton. Discard
    // unconditionally: the about-to-be-replaced document doesn't
    // benefit from a commit either.
    macvoxel::DiscardFloatingBuffer();
    [self seedDocumentFromDefault];
    _doc->path.clear();
    ++_doc->version;
    macvoxel::CurrentHistory().Clear();
    [self invalidateRenderersIfPossible];
    [self updateWindowTitle];
    [self frameCameraIfPossible];
}

- (IBAction)openDocument:(id)__unused sender {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = [self voxContentTypes];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    if ([panel runModal] != NSModalResponseOK) return;
    [self openDocumentAtURL:panel.URL];
}

// Path-based open used by openDocument:, application:openURLs: (which
// AppKit calls when the user clicks an Open Recent item or a file in
// Finder), and any future drag-and-drop wiring. Registers successful
// opens with NSDocumentController so they show up in Open Recent next
// time around — the framework persists the URL list across launches
// for free.
- (BOOL)openDocumentAtURL:(NSURL*)url {
    if (url == nil || _doc == nullptr) return NO;
    macvoxel::DiscardFloatingBuffer();
    const std::string path = [[url path] UTF8String];
    macvoxel::Document fresh;
    std::string err;
    if (!macvoxel::LoadVox(path, &fresh.grid, &fresh.palette, &err)) {
        [self showAlertTitle:@"Open Failed"
                     message:[NSString stringWithUTF8String:err.c_str()]];
        return NO;
    }
    fresh.path = path;
    fresh.version = _doc->version + 1;
    *_doc = std::move(fresh);
    macvoxel::CurrentHistory().Clear();
    [self invalidateRenderersIfPossible];
    [self updateWindowTitle];
    [self frameCameraIfPossible];
    [[NSDocumentController sharedDocumentController]
        noteNewRecentDocumentURL:url];
    return YES;
}

// Called by AppKit on Open Recent click and on Finder file-open. We're
// a single-document app, so take the first URL and ignore the rest.
- (void)application:(NSApplication*)__unused sender
           openURLs:(NSArray<NSURL*>*)urls {
    for (NSURL* url in urls) {
        if ([self openDocumentAtURL:url]) break;
    }
}

- (IBAction)saveDocument:(id)sender {
    if (_doc->path.empty()) {
        [self saveDocumentAs:sender];
        return;
    }
    // Drop the floating buffer onto the doc before serialising — the
    // user expects "save" to capture what's on screen, including any
    // mid-drag paste or move that hasn't been explicitly committed.
    if (macvoxel::CurrentFloatingBuffer().active) {
        macvoxel::CommitFloatingBuffer(*_doc);
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

    if (macvoxel::CurrentFloatingBuffer().active) {
        macvoxel::CommitFloatingBuffer(*_doc);
    }
    const std::string path = [[url path] UTF8String];
    std::string err;
    if (!macvoxel::SaveVox(path, _doc->grid, _doc->palette, &err)) {
        [self showAlertTitle:@"Save Failed"
                     message:[NSString stringWithUTF8String:err.c_str()]];
        return;
    }
    _doc->path = path;
    [self updateWindowTitle];
    [[NSDocumentController sharedDocumentController]
        noteNewRecentDocumentURL:url];
}

- (IBAction)undo:(id)__unused sender {
    if (_doc == nullptr) return;
    macvoxel::FloatingBuffer& fb = macvoxel::CurrentFloatingBuffer();
    if (fb.active) {
        // Undo while floating cancels the whole move-in-progress: the
        // lift didn't push an EditOp (we fold lift+drag+commit into a
        // single op at commit time), so we restore doc cells from the
        // buffer's stored source snapshot and pop nothing from history.
        // Paste-style buffers have no source cells to restore — the
        // discard is the entire revert.
        macvoxel::CancelFloatingLift(*_doc);
        ++_doc->version;
        return;
    }
    if (macvoxel::CurrentHistory().Undo(_doc->grid,
                                        &macvoxel::CurrentSelection())) {
        ++_doc->version;
    }
}

- (IBAction)redo:(id)__unused sender {
    if (_doc == nullptr) return;
    if (macvoxel::CurrentHistory().Redo(_doc->grid,
                                        &macvoxel::CurrentSelection())) {
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
        action == @selector(deleteSelection:)) {
        // Enabled if there's anything selected — either a doc-side
        // sparse selection or a floating buffer (the floating buffer
        // is the active selection while it's alive).
        const macvoxel::Selection& sel = macvoxel::CurrentSelection();
        const macvoxel::FloatingBuffer& fb = macvoxel::CurrentFloatingBuffer();
        if (fb.active && !fb.grid.empty()) return YES;
        return sel.active && !sel.voxels.empty();
    }
    if (action == @selector(deselect:)) {
        // Deselect just commits the floating buffer (if any) and
        // clears the marquee — fine whenever there's anything to drop.
        return macvoxel::CurrentSelection().active ||
               macvoxel::CurrentFloatingBuffer().active;
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
    macvoxel::Clipboard& cb = macvoxel::CurrentClipboard();
    macvoxel::FloatingBuffer& fb = macvoxel::CurrentFloatingBuffer();

    if (fb.active && !fb.grid.empty()) {
        // Floating selection: serialize the buffer's cells (with offset
        // baked into the world-coord origin so paste-in-place lands at
        // the buffer's current rendered position).
        const macvoxel::Bounds3 b = fb.grid.Bounds();
        cb.origin_x = b.min_x + fb.offset_x;
        cb.origin_y = b.min_y + fb.offset_y;
        cb.origin_z = b.min_z + fb.offset_z;
        cb.size_x = static_cast<uint32_t>(b.size_x());
        cb.size_y = static_cast<uint32_t>(b.size_y());
        cb.size_z = static_cast<uint32_t>(b.size_z());
        cb.cells.assign(static_cast<size_t>(cb.size_x) * cb.size_y * cb.size_z, 0);
        constexpr uint32_t kCS = macvoxel::VoxelGrid::kChunkSize;
        for (const auto& [coord, chunk] : fb.grid.chunks()) {
            if (chunk->filled_count == 0) continue;
            const int32_t base_x = coord.x * static_cast<int32_t>(kCS);
            const int32_t base_y = coord.y * static_cast<int32_t>(kCS);
            const int32_t base_z = coord.z * static_cast<int32_t>(kCS);
            for (uint32_t lz = 0; lz < kCS; ++lz)
            for (uint32_t ly = 0; ly < kCS; ++ly)
            for (uint32_t lx = 0; lx < kCS; ++lx) {
                const size_t idx = lx + ly * kCS + lz * kCS * kCS;
                const uint8_t pal = chunk->cells[idx];
                if (pal == 0) continue;
                const int32_t cx = base_x + static_cast<int32_t>(lx);
                const int32_t cy = base_y + static_cast<int32_t>(ly);
                const int32_t cz = base_z + static_cast<int32_t>(lz);
                cb.cells[cb.LinearIndex(
                    static_cast<uint32_t>(cx - b.min_x),
                    static_cast<uint32_t>(cy - b.min_y),
                    static_cast<uint32_t>(cz - b.min_z))] = pal;
            }
        }
        return;
    }

    const macvoxel::Selection& sel = macvoxel::CurrentSelection();
    if (!sel.active || sel.voxels.empty()) return;
    cb.origin_x = sel.box.min_x;
    cb.origin_y = sel.box.min_y;
    cb.origin_z = sel.box.min_z;
    cb.size_x = static_cast<uint32_t>(sel.box.size_x());
    cb.size_y = static_cast<uint32_t>(sel.box.size_y());
    cb.size_z = static_cast<uint32_t>(sel.box.size_z());
    cb.cells.assign(static_cast<size_t>(cb.size_x) * cb.size_y * cb.size_z, 0);
    for (const auto& v : sel.voxels) {
        const uint32_t lx = static_cast<uint32_t>(v[0] - sel.box.min_x);
        const uint32_t ly = static_cast<uint32_t>(v[1] - sel.box.min_y);
        const uint32_t lz = static_cast<uint32_t>(v[2] - sel.box.min_z);
        cb.cells[cb.LinearIndex(lx, ly, lz)] = _doc->grid.Get(v[0], v[1], v[2]);
    }
}

- (IBAction)cut:(id)sender {
    [self copy:sender];
    [self deleteSelection:sender];
}

- (IBAction)deleteSelection:(id)__unused sender {
    if (_doc == nullptr) return;
    macvoxel::FloatingBuffer& fb = macvoxel::CurrentFloatingBuffer();
    if (fb.active) {
        // Floating cells aren't on the document yet — discarding the
        // buffer IS the delete. (The lift that produced this buffer
        // remains on the undo stack; one more Cmd-Z restores the
        // pre-lift state.)
        macvoxel::DiscardFloatingBuffer();
        ++_doc->version;
        return;
    }
    const macvoxel::Selection& sel = macvoxel::CurrentSelection();
    if (!sel.active || sel.voxels.empty()) return;
    macvoxel::EditHistory& history = macvoxel::CurrentHistory();
    history.BeginOp();
    for (const auto& v : sel.voxels) {
        const uint8_t old = _doc->grid.Get(v[0], v[1], v[2]);
        if (old != 0) {
            _doc->grid.Set(v[0], v[1], v[2], 0);
            history.Record(v[0], v[1], v[2], old, 0);
        }
    }
    history.CommitOp();
    ++_doc->version;
}

- (IBAction)paste:(id)__unused sender {
    if (_doc == nullptr) return;
    const macvoxel::Clipboard& cb = macvoxel::CurrentClipboard();
    if (cb.empty()) return;

    // Whatever's already floating gets dropped first — the new paste
    // stages a fresh buffer.
    if (macvoxel::CurrentFloatingBuffer().active) {
        macvoxel::CommitFloatingBuffer(*_doc);
    }

    // Paste in place: land at the clipboard's recorded source origin.
    // Source geometry (if it's still on the doc) stays intact because
    // the paste stages into the floating buffer rather than writing
    // to doc.grid; user can drag the buffer to a new position before
    // committing.
    macvoxel::LiftClipboardToFloating(*_doc, cb,
                                      cb.origin_x, cb.origin_y, cb.origin_z);
    ++_doc->version;
}

- (IBAction)deselect:(id)__unused sender {
    // "Done with this selection" — drop any floating buffer onto the
    // document (the user expects the dragged paste / move to be a
    // permanent edit) and only then clear the selection.
    if (_doc != nullptr && macvoxel::CurrentFloatingBuffer().active) {
        macvoxel::CommitFloatingBuffer(*_doc);
    }
    macvoxel::CurrentSelection().Clear();
}

@end
