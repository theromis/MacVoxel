import SwiftUI

// SwiftUI replacement for AppDelegate's buildMainMenu. Hooks into
// the standard CommandGroup placements so File / Edit menus appear
// in their canonical spots and Open Recent is auto-populated by
// NSDocumentController (we call noteNewRecentDocumentURL from the
// bridge on every successful open / save).
struct MacVoxelCommands: Commands {
    @Bindable var state: EditorState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") {
                state.newDocument()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Open\u{2026}") {
                state.openDocumentDialog()
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            // Replacing .newItem strips the standard Close item; the
            // user still needs Cmd-W. SwiftUI gives us performClose
            // via the responder chain on whatever window is key.
            Button("Close") {
                NSApplication.shared.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                state.saveDocument()
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Save As\u{2026}") {
                state.saveDocumentAsDialog()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { state.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!state.canUndo)
            Button("Redo") { state.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!state.canRedo)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { state.cut() }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(!state.canCutOrCopyOrDelete)
            Button("Copy") { state.copy() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!state.canCutOrCopyOrDelete)
            Button("Paste") { state.paste() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!state.canPaste)
            Button("Delete") { state.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!state.canCutOrCopyOrDelete)
            Divider()
            Button("Deselect") { state.deselect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!state.canDeselect)
        }
    }
}
