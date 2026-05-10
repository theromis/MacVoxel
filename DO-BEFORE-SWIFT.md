# Do Before Swift

The structural prep that has to land *before* a SwiftUI port is a
reasonable undertaking. Each item is also a defensible refactor on its
own — none of them require committing to SwiftUI to be worth doing —
but together they're the prerequisites.

The viewport (`VoxelView` / `MTKView`) is expected to stay AppKit and
bridge into SwiftUI via `NSViewRepresentable`. The "before Swift" work
is everything around the viewport, not the viewport itself.

## Load-bearing prerequisites

### 1. Define an explicit editor state model — DATA-MODEL #1

Today's state is split across global singletons and a grab-bag of
`VoxelView` ivars. SwiftUI needs observable, owned state objects that
views can subscribe to; right now there's nothing coherent to publish.

Target shape (from DATA-MODEL):

- `DocumentModel` — `Document` (already exists, fine).
- `ToolSettings` — current tool, mode, palette index, per-tool options
  (currently `ToolState`).
- `RenderSettings` — user-editable render config.
- `RenderProgress` — sample count, convergence, GPU stats. Today these
  are mixed into `RenderState`; split them so settings (input) and
  progress (output) aren't the same object.
- `SelectionModel` — already in good shape after #5; `Selection` is
  sparse-first with derived bounds.
- `InteractionState` — current gesture, anchors, hover cell, active
  preview, active gizmo. Today these are private ivars on `VoxelView`.
- `PanelState` — UI-only state (palette slot drag, context menu target,
  etc.). Today these are `static` locals inside panel functions.

The structural goal: when SwiftUI says "I want to bind a slider to
X", X has an actual owner you can name.

### 2. Replace globals with an EditorContext — DATA-MODEL #2

Pass an `EditorContext` (or whatever it gets called) explicitly instead
of reaching into `CurrentTool()` / `CurrentSelection()` / etc. The
single-document app can still be single-document; the context just
becomes a real object owned at the app/document/view layer.

Globals that need to migrate:

- `CurrentTool()` (ToolState)
- `CurrentSelection()` (Selection)
- `CurrentRenderState()` (RenderState)
- `CurrentGeneratorState()` (GeneratorState)
- `CurrentFloatingBuffer()` (FloatingBuffer)
- `CurrentPreview()` (PreviewOverlay)
- `CurrentHistory()` (EditHistory)
- `CurrentClipboard()` (Clipboard)

Why for SwiftUI: SwiftUI views can't observe free functions returning
process-globals. They can observe properties on owned objects.

Useful side effect: tool logic becomes testable against a context
without needing to instantiate `VoxelView`.

### 3. Move interaction logic out of `VoxelView` — DATA-MODEL #10

`VoxelView` should be the platform view/render-event adapter, not the
owner of every modeling state machine. Extract the gesture controllers
(brush, shape preview/commit, face extrusion, generator gizmo,
selection creation, selection move/transform) into per-tool controllers
or pure functions that take an `EditorContext` (from #2) plus
camera/picking services.

The current `VoxelView.mm` is ~3500 lines, most of it interaction
state. After the extraction it should be a thin AppKit shell:
NSView/MTKView lifecycle, mouse/key event routing, camera state,
per-frame draw dispatch.

Why for SwiftUI: SwiftUI gestures call model actions. If those actions
live inside an AppKit view subclass, they're not callable from a
SwiftUI control. If they live on a controller object reachable through
the EditorContext, they are.

This is the biggest of the three. It's also the most valuable to do
*last* — it absorbs and codifies the boundaries the first two
established.

## Adjacent (might come up; not strictly prerequisites)

- **#4 Unified edit transactions.** Was dismissed as premature
  abstraction during the data-model pass. If SwiftUI bindings end up
  wanting a uniform "begin/preview/commit/cancel" surface for menu
  items and gestures, revisit. Otherwise the existing patterns (brush
  stream, preview overlay, floating buffer, generator gizmo) stay
  shape-distinct because they genuinely *are* different shapes.

- **Render settings ↔ render progress separation.** Mentioned under
  #1 above. The current `RenderState` mixes user-editable inputs
  (samples target, glass mode, NEE toggles) and progressive outputs
  (live `sample_count`). For Combine/Observable bindings the inputs
  and outputs want to be different objects.

- **Panel state extraction.** A handful of palette / render panels
  hold gesture-coalescing state in `static` locals (drag snapshots,
  drag-active flags). Those would move to `PanelState` under #1 so
  SwiftUI views can re-render without losing mid-gesture state.

## Out of scope for the SwiftUI prep

- The viewport stays AppKit + Metal. MTKView wraps cleanly with
  `NSViewRepresentable`; no port needed.
- Path tracer, raycast renderer, and the typed-dirty signal layer
  (DATA-MODEL #7) are renderer-internal. SwiftUI doesn't see them.
- `VoxelGrid`, `Palette`, `Material`, `EditHistory`, `PreviewOverlay`,
  `FloatingBuffer` — pure model code, no SwiftUI implications.
- Headless render path (`MacVoxel render`) doesn't go through any
  of this. Keep it bypassable.
