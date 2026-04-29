# Voxel Editor — Implementation Plan (Phase 0)

## Project: a MagicaVoxel-inspired voxel editor and renderer for macOS

This document is a handoff for Claude Code. It describes the goals, technology choices, and step-by-step plan for **Phase 0** of the project: getting a window on screen with a Metal view that clears to a color, with Dear ImGui rendering on top of it. Later phases are sketched at the end for context but are **out of scope** for this handoff.

---

## Goals and non-goals

### What we are building

A native macOS application — a voxel editor in the spirit of MagicaVoxel — with a heavy emphasis on UI responsiveness. The whole UI is drawn into a single Metal-backed view using Dear ImGui (immediate-mode), so there is no AppKit view hierarchy for tool panels, sliders, or color pickers. The app shell (window, menu bar, file dialogs) is native AppKit; everything inside the content view is ImGui + Metal.

### What we are not building (yet)

- Path-traced rendering. The eventual "render mode" is a long-horizon goal, not Phase 0.
- Cross-platform support. macOS only. ARM64 only is fine; Intel support is not a goal.
- A plugin system, scripting, or networked features.
- Anything resembling a voxel data structure or rendering — Phase 0 is purely the shell.

### Definition of done for Phase 0

When you run `cmake --build build && ./build/MacVoxel.app/Contents/MacOS/MacVoxel` (or open the app bundle in Finder), the following must be true:

1. A native macOS window opens, titled "MacVoxel", at a reasonable starting size (1280×800).
2. The window has a native menu bar with at minimum: MacVoxel → About / Quit, File → New / Open / Save / Save As (stubbed, no-op except Quit), Edit → Undo / Redo (stubbed), View → (empty for now).
3. The content view is a `MTKView` (or equivalent `CAMetalLayer`-backed view) that clears to a recognizable non-default color each frame (suggested: `#1e1e2e`).
4. Dear ImGui renders on top of the Metal clear, drawing one demo panel ("Hello, MacVoxel") with a slider, a color picker, and a button. The button increments a counter shown in the same panel.
5. The ImGui demo window (`ImGui::ShowDemoWindow`) is also accessible via a debug menu item or keyboard shortcut (⌘D).
6. The app responds to mouse, keyboard, and trackpad input with no perceptible latency. Resizing the window does not produce flicker or layout glitches.
7. The window's close button quits the app cleanly. ⌘Q quits cleanly.
8. The app is built and runnable via a single CMake invocation. No Xcode project file is checked in.

---

## Technology choices (already decided — do not relitigate)

- **Language:** C++ (C++20). Use Objective-C++ (`.mm`) only where AppKit/Metal interop requires it.
- **Window/menu bar/input:** Native AppKit, via `imgui_impl_osx.mm` from Dear ImGui's official backends.
- **Graphics API:** Metal, via `imgui_impl_metal.mm` from Dear ImGui's official backends.
- **GUI:** Dear ImGui (latest stable release, docking branch is fine and probably wanted long-term, but master is acceptable for Phase 0).
- **Build system:** CMake 3.24+. No Xcode project. The CMake build should produce a proper `.app` bundle.
- **Dependency management:** Vendor Dear ImGui as a git submodule under `third_party/imgui`. Do not use a package manager (vcpkg, Conan) for Phase 0.
- **Minimum macOS deployment target:** macOS 13 (Ventura).
- **Architecture:** ARM64. Universal binary is not required.

If any of these choices turns out to be infeasible for a concrete technical reason during Phase 0, stop and surface the problem rather than silently substituting an alternative.

---

## Repository layout

```
MacVoxel/
├── CMakeLists.txt
├── README.md
├── .gitignore
├── .gitmodules
├── cmake/
│   └── (any helper modules — likely empty in Phase 0)
├── src/
│   ├── main.mm              # NSApplication setup, window creation, run loop
│   ├── AppDelegate.h
│   ├── AppDelegate.mm       # Menu bar, app lifecycle
│   ├── VoxelView.h
│   ├── VoxelView.mm         # MTKView subclass, Metal + ImGui frame loop
│   └── ui/
│       └── HelloPanel.cpp   # The Phase 0 demo panel — pure C++, no Obj-C
│       └── HelloPanel.h
├── resources/
│   └── Info.plist.in        # CMake-templated Info.plist
└── third_party/
    └── imgui/               # git submodule
```

The split between `.mm` (Obj-C++) and `.cpp` (pure C++) is deliberate: anything that touches AppKit, Metal, or the ImGui backend `_impl` files lives in `.mm`. Application logic — including future voxel data structures, tools, and ImGui panel code — should live in `.cpp` to keep it portable and easy to test.

---

## Step-by-step plan

Work in this order. Commit after each step. Do not skip ahead.

### Step 1: Repository scaffolding

1. Initialize a git repository.
2. Create the directory structure above (empty files are fine for now).
3. Add a `.gitignore` covering `build/`, `.DS_Store`, Xcode user files, and CMake artifacts.
4. Add Dear ImGui as a submodule: `git submodule add https://github.com/ocornut/imgui.git third_party/imgui`. Pin to a specific tag (e.g. `v1.91.5` or whatever is current stable).
5. Write a placeholder `README.md` with the project name, a one-line description, and build instructions (`cmake -B build && cmake --build build`).

**Verification:** `git status` is clean, `git submodule status` shows imgui present.

### Step 2: Minimal CMakeLists.txt that builds an empty .app bundle

1. Set `CMAKE_CXX_STANDARD 20`, `CMAKE_OSX_DEPLOYMENT_TARGET 13.0`.
2. Define an executable target `MacVoxel` with `MACOSX_BUNDLE` set to `TRUE`.
3. Configure an `Info.plist` from `resources/Info.plist.in` with `CFBundleName`, `CFBundleIdentifier` (`horse.disk.MacVoxel` or similar — pick a stable reverse-DNS identifier), `CFBundleVersion`, `LSMinimumSystemVersion`, and `NSHighResolutionCapable=true`.
4. At this stage, `src/main.mm` can contain a stub `int main() { return 0; }`.
5. Link against the required frameworks: `Cocoa`, `Metal`, `MetalKit`, `QuartzCore`.

**Verification:** `cmake -B build && cmake --build build` produces `build/MacVoxel.app`. Opening it does nothing visible (it exits immediately), but Finder recognizes it as an app bundle.

### Step 3: Open a native window with a menu bar

In `main.mm` and `AppDelegate.mm`:

1. Create an `NSApplication`, set its activation policy to `NSApplicationActivationPolicyRegular`.
2. Build a menu bar programmatically with the menus listed in "Definition of done" item 2. All items except Quit can be no-ops (use empty selectors or log to stderr).
3. Create an `NSWindow` (1280×800, titled "MacVoxel", standard window style mask: titled, closable, miniaturizable, resizable).
4. Wire up `NSApplicationDelegate` to terminate the app when the last window closes.
5. Run the event loop with `[NSApp run]`.

**Verification:** Running the app opens a blank window with a working menu bar. ⌘Q quits. Closing the window quits.

### Step 4: Add a Metal-backed content view that clears each frame

1. Create a `VoxelView` subclass of `MTKView` (or, if you prefer, an `NSView` hosting a `CAMetalLayer` directly — `MTKView` is simpler and recommended).
2. In its initializer: create an `MTLDevice` via `MTLCreateSystemDefaultDevice()`, assign it to the view, set `colorPixelFormat = MTLPixelFormatBGRA8Unorm`, set `clearColor` to `(0.118, 0.118, 0.18, 1.0)` (≈ `#1e1e2e`).
3. Implement `drawInMTKView:`: get the current `MTLCommandBuffer`, get the current `MTLRenderPassDescriptor`, begin and end a render encoder (which performs the clear), present, commit.
4. Set the window's `contentView` to an instance of `VoxelView`.

**Verification:** The window now has a dark slate-blue interior. Resizing the window keeps it filled with no flicker.

### Step 5: Integrate Dear ImGui

1. In `CMakeLists.txt`, add the necessary ImGui sources to the target:
   - `third_party/imgui/imgui.cpp`
   - `third_party/imgui/imgui_draw.cpp`
   - `third_party/imgui/imgui_tables.cpp`
   - `third_party/imgui/imgui_widgets.cpp`
   - `third_party/imgui/imgui_demo.cpp`
   - `third_party/imgui/backends/imgui_impl_metal.mm`
   - `third_party/imgui/backends/imgui_impl_osx.mm`
   - Add `third_party/imgui` and `third_party/imgui/backends` as include directories.
2. In `VoxelView.mm`, in the view's initializer:
   - `IMGUI_CHECKVERSION(); ImGui::CreateContext();`
   - Configure `ImGuiIO` (enable keyboard nav).
   - `ImGui_ImplMetal_Init(device);`
   - `ImGui_ImplOSX_Init(self);`
3. In `drawInMTKView:`, around the existing clear:
   - `ImGui_ImplMetal_NewFrame(renderPassDescriptor);`
   - `ImGui_ImplOSX_NewFrame(self);`
   - `ImGui::NewFrame();`
   - Call into `HelloPanel::Draw(state)` (defined in `src/ui/HelloPanel.cpp`).
   - `ImGui::Render();`
   - After encoding the clear pass, call `ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), commandBuffer, renderEncoder);`
   - End encoder, present, commit.
4. In `dealloc` / app termination: `ImGui_ImplMetal_Shutdown(); ImGui_ImplOSX_Shutdown(); ImGui::DestroyContext();`

**Verification:** The Hello panel appears over the Metal clear. The slider, color picker, and button all work. Counter increments on click. ⌘D toggles the ImGui demo window.

### Step 5.5: Load San Francisco as the UI font

Apple's license prohibits bundling SF in the app, but it's present on every supported macOS version at a known path. Load it from the system at runtime.

1. After `ImGui::CreateContext()` and before `ImGui_ImplMetal_Init`, configure fonts:
   ```cpp
   ImGuiIO& io = ImGui::GetIO();
   const char* sf_path = "/System/Library/Fonts/SFNS.ttf";
   const float font_size_pt = 13.0f;
   const float scale = 2.0f;  // load at 2x for Retina, scale down via FontGlobalScale

   ImFont* font = io.Fonts->AddFontFromFileTTF(sf_path, font_size_pt * scale);
   if (font == nullptr) {
       fprintf(stderr, "warning: failed to load %s, falling back to ImGui default\n", sf_path);
       io.Fonts->AddFontDefault();
   }
   io.FontGlobalScale = 1.0f / scale;
   ```
2. Verify the font loaded by checking that the Hello panel renders in San Francisco rather than ImGui's default Proggy bitmap font. The difference is unmistakable — if you see chunky pixelated text, the load failed.
3. Do **not** add the font file to the repository or app bundle. Loading from `/System/Library/Fonts/` is the supported approach.

**Verification:** Hello panel and ImGui demo window both render in San Francisco. Text is crisp on a Retina display. No font files are checked into the repo.

**Note for later phases:** Glyph ranges are limited to basic Latin by default; expanding to CJK, symbol fonts, or icon fonts (e.g. for tool icons) is a Phase 1+ concern. Variable font axes (optical sizing for display vs. text cuts) are not driven by ImGui — a single cut at one size is fine for now.

### Step 6: Polish and verify the definition of done

1. Verify HiDPI: open the app on a Retina display, confirm ImGui text is crisp (this typically requires setting `ImGuiIO::DisplayFramebufferScale` and `FontGlobalScale` correctly — the OSX backend handles most of this, but verify).
2. Verify input: trackpad scroll should scroll ImGui windows. Cmd+click should be distinguishable from regular click.
3. Verify resize: drag the window to various sizes. ImGui windows should remain responsive and the Metal clear should fill the view.
4. Verify clean exit: ⌘Q produces no console errors, no leaked Metal objects (run once under `leaks` or with the address sanitizer if convenient — not strictly required but a good check).
5. Update the `README.md` with a screenshot and confirmed build steps.

**Verification:** Walk through every item in "Definition of done" and confirm.

---

## Conventions and ground rules

- **Commit granularity:** one commit per step above, with a descriptive message. If a step is large (Step 5 in particular), multiple commits are fine.
- **Code style:** follow the style of Dear ImGui itself — `CamelCase` for public functions, `snake_case` for locals, prefer free functions over classes where state is minimal. No exceptions thrown across the C++/ObjC boundary.
- **Formatting:** add a `.clang-format` file based on the LLVM style with column limit 100, but don't bikeshed it.
- **No premature abstraction:** do not introduce a "renderer" interface, an "application" base class, or any other indirection in Phase 0. The whole shell should be three or four files of straightforward code.
- **Dependencies:** Dear ImGui is the only third-party dependency. Do not add others without surfacing the need first.
- **Warnings as errors:** turn on `-Wall -Wextra -Wpedantic` and treat warnings as errors for project sources (not for `third_party/`).

---

## Out of scope (for context only — do not implement)

The following phases will follow Phase 0, in roughly this order. They are listed so the Phase 0 architecture doesn't accidentally box them out, not so they should be built now:

1. **Camera and a hardcoded cube.** Render a single textured cube with orbit/pan/zoom controls.
2. **Voxel grid data structure.** A dense 3D array of palette indices, plus a palette of RGBA colors. `.vox` file load/save.
3. **Naive voxel rendering.** One cube per filled voxel. Will not perform — that's the point.
4. **Greedy meshing.** Generate an optimized triangle mesh from the grid; only re-mesh dirty regions.
5. **Editing tools.** Place, erase, paint, with brush sizes. Raycast from mouse into the grid.
6. **Selection, copy/paste, undo/redo.**
7. **Palette and material editor UI.**
8. **Path-traced render mode** (much later).

---

## Open questions for the human (Paul) to resolve before Claude Code starts

1. **Bundle identifier.** Suggested: `horse.disk.MacVoxel`. Confirm or override.
2. **App name.** "MacVoxel" is a placeholder. Final name?
3. **License.** MIT is the obvious default for a project that depends on Dear ImGui (also MIT). Confirm.
4. **ImGui docking branch?** The docking branch enables multi-viewport and dockable panels, both of which a MagicaVoxel-style editor will eventually want. Adopting it now costs nothing and saves a migration later. Recommend yes; confirm.