#import <Cocoa/Cocoa.h>

#import "AppDelegate.h"
#include "CliRender.h"

#include <cstring>

int main(int argc, const char* argv[]) {
    // Headless subcommand dispatch. Skips NSApplicationMain entirely so
    // running from CI / scripts doesn't spawn a GUI process.
    if (argc >= 2 && std::strcmp(argv[1], "render") == 0) {
        return macvoxel::RunCliRender(argc - 1, argv + 1);
    }

    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        AppDelegate* delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];

        [app run];
    }
    return 0;
}
