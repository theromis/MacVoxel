#pragma once

namespace macvoxel {

// Headless MCP server on stdin/stdout. `argv` is positioned past the
// `mcp` subcommand. Returns a process exit code.
int RunMcp(int argc, const char* argv[]);

}  // namespace macvoxel
