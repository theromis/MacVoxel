#import "EditorContextBridge.h"
#import "EditorContextBridge_Internal.h"

#import <AppKit/AppKit.h>

#include <cstdio>
#include <memory>
#include <string>
#include <utility>

#include "Clipboard.h"
#include "Document.h"
#include "EditHistory.h"
#include "EditorContext.h"
#include "FloatingBuffer.h"
#include "FloatingBufferOps.h"
#include "Palette.h"
#include "Selection.h"
#include "VoxFile.h"
#include "VoxelGrid.h"

@implementation EditorContextBridge {
    std::unique_ptr<macvoxel::EditorContext> _ctx;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _ctx = std::make_unique<macvoxel::EditorContext>();
    [self seedDocumentFromDefault];
    _ctx->document.BumpAll();
    return self;
}

// Mirrors AppDelegate's seedDocumentFromDefault: load the bundled
// default.vox if available, otherwise drop a single seed voxel so the
// renderers have something to draw. Document path stays empty —
// "Untitled" until the user saves.
- (void)seedDocumentFromDefault {
    macvoxel::Document &doc = _ctx->document;
    NSString *path = [[NSBundle mainBundle] pathForResource:@"default"
                                                     ofType:@"vox"];
    if (path != nil) {
        const std::string p = [path UTF8String];
        std::string err;
        if (macvoxel::LoadVox(p, &doc.grid, &doc.palette, &err)) {
            return;
        }
        std::fprintf(stderr,
                     "MacVoxel: failed to load bundled default.vox (%s); "
                     "falling back to single-voxel seed\n",
                     err.c_str());
    }
    doc.grid.Clear();
    doc.grid.Set(0, 0, 0, 1);
    doc.palette.ResetToDefault();
}

- (macvoxel::EditorContext *)context {
    return _ctx.get();
}

- (NSString *)documentTitle {
    const std::string &p = _ctx->document.path;
    if (p.empty()) return @"Untitled";
    NSString *path = [NSString stringWithUTF8String:p.c_str()];
    return [path lastPathComponent];
}

- (NSString *)documentPath {
    const std::string &p = _ctx->document.path;
    if (p.empty()) return @"";
    return [NSString stringWithUTF8String:p.c_str()];
}

- (BOOL)hasDocumentPath {
    return !_ctx->document.path.empty();
}

// ---------------------------------------------------------------------------
// Document actions
// ---------------------------------------------------------------------------

- (void)newDocument {
    macvoxel::Document &doc = _ctx->document;
    // FloatingBuffer references the doc's grid; discard before replacing
    // (matches AppDelegate's invariant — see the original comment in
    // newDocument:).
    macvoxel::DiscardFloatingBuffer(*_ctx);
    [self seedDocumentFromDefault];
    doc.path.clear();
    doc.BumpAll();
    _ctx->history.Clear();
}

- (BOOL)openDocumentAtURL:(NSURL *)url error:(NSError **)error {
    if (url == nil) {
        if (error) *error = [NSError errorWithDomain:@"MacVoxel" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"No URL provided."}];
        return NO;
    }
    macvoxel::DiscardFloatingBuffer(*_ctx);
    const std::string path = [[url path] UTF8String];
    macvoxel::Document fresh;
    std::string err;
    if (!macvoxel::LoadVox(path, &fresh.grid, &fresh.palette, &err)) {
        if (error) {
            NSString *msg = [NSString stringWithUTF8String:err.c_str()];
            *error = [NSError errorWithDomain:@"MacVoxel" code:2
                userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }
    fresh.path = path;
    _ctx->document = std::move(fresh);
    _ctx->document.BumpAll();
    _ctx->history.Clear();
    [[NSDocumentController sharedDocumentController]
        noteNewRecentDocumentURL:url];
    return YES;
}

- (BOOL)saveDocumentToURL:(NSURL *)url error:(NSError **)error {
    if (url == nil) {
        if (error) *error = [NSError errorWithDomain:@"MacVoxel" code:3
            userInfo:@{NSLocalizedDescriptionKey: @"No URL provided."}];
        return NO;
    }
    if (_ctx->floating_buffer.active) {
        macvoxel::CommitFloatingBuffer(*_ctx);
    }
    macvoxel::Document &doc = _ctx->document;
    const std::string path = [[url path] UTF8String];
    std::string err;
    if (!macvoxel::SaveVox(path, doc.grid, doc.palette, &err)) {
        if (error) {
            NSString *msg = [NSString stringWithUTF8String:err.c_str()];
            *error = [NSError errorWithDomain:@"MacVoxel" code:4
                userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }
    doc.path = path;
    [[NSDocumentController sharedDocumentController]
        noteNewRecentDocumentURL:url];
    return YES;
}

- (BOOL)saveDocumentInPlace:(NSError **)error {
    if (_ctx->document.path.empty()) {
        if (error) *error = [NSError errorWithDomain:@"MacVoxel" code:5
            userInfo:@{NSLocalizedDescriptionKey:
                @"Document has no on-disk path yet."}];
        return NO;
    }
    NSURL *url = [NSURL fileURLWithPath:
        [NSString stringWithUTF8String:_ctx->document.path.c_str()]];
    return [self saveDocumentToURL:url error:error];
}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

- (BOOL)canUndo {
    if (_ctx->floating_buffer.active) return YES;  // undo cancels the lift
    return _ctx->history.CanUndo();
}

- (BOOL)canRedo {
    return _ctx->history.CanRedo();
}

- (void)undo {
    macvoxel::Document &doc = _ctx->document;
    macvoxel::FloatingBuffer &fb = _ctx->floating_buffer;
    if (fb.active) {
        // Undo while floating cancels the whole move-in-progress; we
        // restore from the buffer's source snapshot and pop nothing
        // from history (the lift didn't push an EditOp). Same logic
        // as AppDelegate's undo:.
        macvoxel::CancelFloatingLift(*_ctx);
        doc.BumpGeometry();
        return;
    }
    _ctx->history.Undo(doc, &_ctx->selection);
}

- (void)redo {
    _ctx->history.Redo(_ctx->document, &_ctx->selection);
}

// ---------------------------------------------------------------------------
// Selection-aware Edit menu
// ---------------------------------------------------------------------------

- (BOOL)canCutOrCopyOrDelete {
    const macvoxel::Selection &sel = _ctx->selection;
    const macvoxel::FloatingBuffer &fb = _ctx->floating_buffer;
    if (fb.active && !fb.grid.empty()) return YES;
    return sel.active() && !sel.empty();
}

- (BOOL)canPaste {
    return !_ctx->clipboard.empty();
}

- (BOOL)canDeselect {
    return _ctx->selection.active() || _ctx->floating_buffer.active;
}

- (void)copy {
    macvoxel::Document &doc = _ctx->document;
    macvoxel::Clipboard &cb = _ctx->clipboard;
    macvoxel::FloatingBuffer &fb = _ctx->floating_buffer;

    if (fb.active && !fb.grid.empty()) {
        const macvoxel::Bounds3 b = fb.grid.Bounds();
        cb.origin_x = b.min_x + fb.offset_x;
        cb.origin_y = b.min_y + fb.offset_y;
        cb.origin_z = b.min_z + fb.offset_z;
        cb.size_x = static_cast<uint32_t>(b.size_x());
        cb.size_y = static_cast<uint32_t>(b.size_y());
        cb.size_z = static_cast<uint32_t>(b.size_z());
        cb.cells.assign(
            static_cast<size_t>(cb.size_x) * cb.size_y * cb.size_z, 0);
        constexpr uint32_t kCS = macvoxel::VoxelGrid::kChunkSize;
        for (const auto &[coord, chunk] : fb.grid.chunks()) {
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

    const macvoxel::Selection &sel = _ctx->selection;
    if (!sel.active() || sel.empty()) return;
    const macvoxel::Bounds3 &sb = sel.bounds();
    cb.origin_x = sb.min_x;
    cb.origin_y = sb.min_y;
    cb.origin_z = sb.min_z;
    cb.size_x = static_cast<uint32_t>(sb.size_x());
    cb.size_y = static_cast<uint32_t>(sb.size_y());
    cb.size_z = static_cast<uint32_t>(sb.size_z());
    cb.cells.assign(
        static_cast<size_t>(cb.size_x) * cb.size_y * cb.size_z, 0);
    for (const auto &v : sel.voxels()) {
        const uint32_t lx = static_cast<uint32_t>(v[0] - sb.min_x);
        const uint32_t ly = static_cast<uint32_t>(v[1] - sb.min_y);
        const uint32_t lz = static_cast<uint32_t>(v[2] - sb.min_z);
        cb.cells[cb.LinearIndex(lx, ly, lz)] =
            doc.grid.Get(v[0], v[1], v[2]);
    }
}

- (void)cut {
    [self copy];
    [self deleteSelection];
}

- (void)deleteSelection {
    macvoxel::Document &doc = _ctx->document;
    macvoxel::FloatingBuffer &fb = _ctx->floating_buffer;
    if (fb.active) {
        // Floating cells aren't on the doc yet — discarding IS the
        // delete. The lift that produced this buffer stays on the
        // undo stack; one more Cmd-Z restores the pre-lift state.
        macvoxel::DiscardFloatingBuffer(*_ctx);
        doc.BumpGeometry();
        return;
    }
    const macvoxel::Selection &sel = _ctx->selection;
    if (!sel.active() || sel.empty()) return;
    macvoxel::EditHistory &history = _ctx->history;
    history.BeginOp();
    for (const auto &v : sel.voxels()) {
        const uint8_t old = doc.grid.Get(v[0], v[1], v[2]);
        if (old != 0) {
            doc.grid.Set(v[0], v[1], v[2], 0);
            history.Record(v[0], v[1], v[2], old, 0);
        }
    }
    history.CommitOp();
    doc.BumpGeometry();
}

- (void)paste {
    macvoxel::Document &doc = _ctx->document;
    const macvoxel::Clipboard &cb = _ctx->clipboard;
    if (cb.empty()) return;

    if (_ctx->floating_buffer.active) {
        macvoxel::CommitFloatingBuffer(*_ctx);
    }
    // Paste in place: land at the clipboard's recorded source origin.
    macvoxel::LiftClipboardToFloating(*_ctx, cb,
                                      cb.origin_x, cb.origin_y, cb.origin_z);
    doc.BumpGeometry();
}

- (void)deselect {
    // "Done with this selection" — drop any floating buffer onto the
    // document, then clear.
    if (_ctx->floating_buffer.active) {
        macvoxel::CommitFloatingBuffer(*_ctx);
    }
    _ctx->selection.Clear();
}

@end
