# Legacy MacVoxel

The SwiftUI / C++ / Metal editor. The current editor is the Rust crate at the
repository root.

Build from this directory, on macOS 14 or later, with CMake 3.24+ and the
Xcode command line tools:

```sh
cmake -B build -G Ninja
cmake --build build
open build/MacVoxel.app
```

`src/` is the old editor. `CLAUDE.md` and `PATH-TRACER-REVIEW.md` describe
that code, including the Metal path tracer. The Rust editor does not link it.
