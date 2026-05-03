#pragma once

namespace macvoxel {

// Headless `MacVoxel render ...` entry point. Argv is positioned past the
// `render` subcommand (so argv[0] is "render", argv[1..] are flags).
// Returns a process exit code.
int RunCliRender(int argc, const char* argv[]);

}  // namespace macvoxel
