#pragma once

#include "Clipboard.h"
#include "Document.h"
#include "EditHistory.h"
#include "EditorMode.h"
#include "GeneratorState.h"
#include "MutatorState.h"
#include "PanelState.h"
#include "RenderState.h"
#include "Selection.h"
#include "ToolState.h"

namespace macvoxel {

class EditEngine;

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
// Whole-object clipboard (Scene mode). Holds a deep model copy plus
// enough leaf metadata to reconstruct the object anywhere; the world
// transform re-solves through the paste target's ancestors. Cleared on
// New / Open (models would dangle across documents otherwise).
struct ObjectClipboard {
    bool valid = false;
    SceneModel model;
    AttrDict trn_attrs;
    std::vector<AttrDict> frames;
    int32_t layer_id = -1;
    AttrDict shp_attrs;
    RotMat world_r{};
    Vec3i32 world_t{};
};

struct EditorContext {
    Document document;
    ToolSettings tool;
    Selection selection;
    RenderSettings render_settings;
    RenderProgress render_progress;
    GeneratorState generator;
    MutatorState mutator;
    // True while a tool is actively writing the GPU preview texture
    // (tex_t) — gates the rasterizer's `preview_active` uniform so the
    // composite pass only runs during a live shape/face/generator
    // gesture. Tools set this on gesture-begin and clear it on commit
    // or cancel.
    bool preview_active = false;
    // Alpha used to composite preview cells over the doc. 1.0 = opaque
    // (drag-time stamps look exactly like the committed result). < 1.0
    // = "ghost" — preview cells alpha-over the doc cell or sky behind
    // them. Used by Brush / Mutator hover previews to telegraph the
    // would-be stamp without claiming it's already committed.
    float preview_alpha = 1.0f;
    EditHistory history;
    Clipboard clipboard;
    ObjectClipboard object_clipboard;
    PanelState panel;
    // Model (voxel editing) vs Scene ("object mode"). See EditorMode.h.
    EditorMode editor_mode = EditorMode::Model;
    // Scene-mode selection: index into document.scene.objects, -1 = none.
    // v1 is single-select; widen to a set later.
    int32_t selected_object = -1;
    // Bridge-initiated activation, serviced by MetalScene's per-frame
    // loop (which owns the lift/gizmo commit preconditions). -1 = none.
    int32_t requested_active_object = -1;
    // Non-owning back-ref so non-Tool paths (SelectionOps, bridge
    // actions) can reach the GPU dispatch façade. MetalScene sets
    // this in its init right after MakeEditEngine; clears in dealloc.
    // Null = CPU-only mode (unit tests / headless render).
    EditEngine* engine = nullptr;

    EditorContext();
};

}  // namespace macvoxel
