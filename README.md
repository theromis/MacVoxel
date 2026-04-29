# MacVoxel

A native macOS voxel editor in the spirit of MagicaVoxel. AppKit shell, Metal-backed
content view, Dear ImGui for all in-window UI.

This is the Phase 0 shell. See `PLAN.md` for the full roadmap.

## Build

Requires macOS 13+, Xcode command line tools, and CMake 3.24+.

```sh
git clone --recurse-submodules <repo-url> macvoxel
cd macvoxel
cmake -B build -G Ninja        # or omit -G for the default Makefile generator
cmake --build build
open build/MacVoxel.app
```

If you cloned without `--recurse-submodules`, run:

```sh
git submodule update --init --recursive
```

## License

MIT. See `LICENSE`.
