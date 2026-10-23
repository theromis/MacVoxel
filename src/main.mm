#import <Cocoa/Cocoa.h>

#include "CliRender.h"
#include "McpServer.h"
#include "VoxRoundTrip.h"

#include <cstring>

// Defined in src/swift/MainEntry.swift via @_cdecl. Runs SwiftUI's
// event loop and never returns until the app quits.
extern "C" void MacVoxelRunApp(void);

int main(int argc, const char* argv[]) {
    // Headless subcommand dispatch. Skips the SwiftUI App entirely so
    // running from CI / scripts doesn't spawn a GUI process.
    if (argc >= 2 && std::strcmp(argv[1], "render") == 0) {
        return macvoxel::RunCliRender(argc - 1, argv + 1);
    }
    if (argc >= 2 && std::strcmp(argv[1], "voxrt") == 0) {
        return macvoxel::RunVoxRoundTrip(argc - 1, argv + 1);
    }
    if (argc >= 2 && std::strcmp(argv[1], "mcp") == 0) {
        return macvoxel::RunMcp(argc - 1, argv + 1);
    }

    MacVoxelRunApp();
    return 0;
}
