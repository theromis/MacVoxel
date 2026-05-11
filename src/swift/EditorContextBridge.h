#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Obj-C wrapper around macvoxel::EditorContext. Owns the C++ context
// via std::unique_ptr behind the @implementation; Swift sees only this
// Obj-C interface (pulled in by MacVoxel-Bridging-Header.h). Pure C++
// accessors live in EditorContextBridge_Internal.h and are only
// available to Obj-C++ callers.
@interface EditorContextBridge : NSObject

// Constructs a fresh editor context. Seeds the document from the
// bundled default.vox if available, falling back to a single-voxel
// grid. Bumps all dirty counters so renderers see fresh data on the
// first frame.
- (instancetype)init;

// Last-path-component of the document path, or "Untitled" if unsaved.
@property (nonatomic, readonly) NSString *documentTitle;

// Absolute path on disk, or empty if the document hasn't been saved.
@property (nonatomic, readonly) NSString *documentPath;

// True once the document has been saved or loaded from a path.
@property (nonatomic, readonly) BOOL hasDocumentPath;

// ---------------------------------------------------------------------------
// Document actions. Mutate EditorContext, bump dirty counters, clear
// undo history when appropriate. Renderer-cache invalidation +
// camera reframing happens in MetalScene; callers (EditorState) call
// the scene-side helpers after these return.
// ---------------------------------------------------------------------------

// Replace the document with a fresh default-seeded one.
- (void)newDocument;

// Load `url` as a .vox file. Returns NO on parse failure; populates
// `error` with the underlying message in that case.
- (BOOL)openDocumentAtURL:(NSURL *)url error:(NSError **)error;

// Serialize the document to `url`. Returns NO with `error` on failure.
// Commits any active floating buffer first so what's on screen is
// what gets persisted.
- (BOOL)saveDocumentToURL:(NSURL *)url error:(NSError **)error;

// Save to the document's current path. Returns NO if there is no
// path yet (caller should fall back to Save As…).
- (BOOL)saveDocumentInPlace:(NSError **)error;

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

@property (nonatomic, readonly) BOOL canUndo;
@property (nonatomic, readonly) BOOL canRedo;
- (void)undo;
- (void)redo;

// ---------------------------------------------------------------------------
// Selection-aware edit menu. Same predicates as AppDelegate's
// validateMenuItem: today.
// ---------------------------------------------------------------------------

@property (nonatomic, readonly) BOOL canCutOrCopyOrDelete;
@property (nonatomic, readonly) BOOL canPaste;
@property (nonatomic, readonly) BOOL canDeselect;

- (void)cut;
- (void)copy;
- (void)paste;
- (void)deleteSelection;
- (void)deselect;

@end

NS_ASSUME_NONNULL_END
