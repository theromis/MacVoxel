# MacVoxel

A native macOS voxel editor in the spirit of MagicaVoxel. AppKit shell, Metal-backed
content view, Dear ImGui for all in-window UI.

This is the **Phase 0 shell** — window, menu bar, Metal clear, ImGui Hello panel. See
`PLAN.md` for the full roadmap.

## Build

Requires macOS 13 (Ventura) or later, Xcode command line tools, and CMake 3.24+.

```sh
git clone --recurse-submodules <repo-url> macvoxel
cd macvoxel
cmake -B build -G Ninja
cmake --build build
open build/MacVoxel.app
```

If you cloned without `--recurse-submodules`:

```sh
git submodule update --init --recursive
```

The `-G Ninja` flag is optional but produces faster, cleaner builds; omit it to use
CMake's default Makefile generator.

## What you should see

- Window titled **MacVoxel**, 1280×800, dark slate-blue (`#1e1e2e`) interior.
- Menu bar: **MacVoxel · File · Edit · View · Window**. File and Edit items are
  stubbed for Phase 0; they log to stderr when clicked.
- A "Hello, MacVoxel" ImGui panel with slider, color picker, click-counter, and
  frame-time readout.
- **⌘D** toggles the full ImGui demo window (also under View → Show ImGui Demo).
- **⌘Q** or closing the window quits cleanly.

The UI font is San Francisco, loaded at runtime from `/System/Library/Fonts/SFNS.ttf`.
Apple's license forbids bundling SF, so it is not committed; macOS 13+ ships it at
that path.

## License

MIT. See `LICENSE`.
