#pragma once

#include "Clipboard.h"
#include "Document.h"
#include "EditHistory.h"
#include "FloatingBuffer.h"
#include "GeneratorState.h"
#include "PanelState.h"
#include "PreviewOverlay.h"
#include "RenderState.h"
#include "Selection.h"
#include "ToolState.h"

namespace macvoxel {

// Single-document editor context — the owned home for everything an
// editing session reads or mutates. Replaces the grab-bag of
// `Current*()` global singletons that lived alongside the document
// in earlier phases. AppDelegate owns one (std::unique_ptr) for the
// app's lifetime; views, panels, and edit ops receive it by reference
// so the dependency surface is explicit.
//
// SwiftUI port path: this is the natural shape for an @Observable
// class injected via `.environment(...)` — every panel/view binds to
// the field it cares about, no free-function calls to bridge.
struct EditorContext {
    Document document;
    ToolSettings tool;
    Selection selection;
    RenderSettings render_settings;
    RenderProgress render_progress;
    GeneratorState generator;
    FloatingBuffer floating_buffer;
    PreviewOverlay preview;
    EditHistory history;
    Clipboard clipboard;
    PanelState panel;

    EditorContext();
};

}  // namespace macvoxel
