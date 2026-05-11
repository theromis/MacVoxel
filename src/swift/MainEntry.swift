import Foundation

// Entry point exposed to C++ via @_cdecl. main.mm calls this after the
// argv "render" subcommand check has been declined; the call never
// returns until the SwiftUI app quits.
@_cdecl("MacVoxelRunApp")
public func MacVoxelRunApp() {
    MacVoxelApp.main()
}
