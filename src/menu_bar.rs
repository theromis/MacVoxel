//! Menu strip at the top of the window. On macOS it sits beside the
//! application menu in `native_menu.rs`; both dispatch through the same
//! session methods. `Session::take_keys` or the macOS menu handles the
//! shortcuts it lists, so the items only show them.

use egui::{Key, KeyboardShortcut, Modifiers};

use crate::state::Session;

const CMD: Modifiers = Modifiers::COMMAND;
const CMD_SHIFT: Modifiers = Modifiers::COMMAND.plus(Modifiers::SHIFT);

fn item(ui: &mut egui::Ui, label: &str, shortcut: Option<KeyboardShortcut>) -> bool {
    let mut button = egui::Button::new(label);
    if let Some(shortcut) = shortcut {
        button = button.shortcut_text(ui.ctx().format_shortcut(&shortcut));
    }
    ui.add(button).clicked()
}

fn key(modifiers: Modifiers, key: Key) -> Option<KeyboardShortcut> {
    Some(KeyboardShortcut::new(modifiers, key))
}

pub fn show(ui: &mut egui::Ui, session: &mut Session) {
    let ctx = ui.ctx().clone();
    let quit = KeyboardShortcut::new(CMD, Key::Q);
    // The macOS application menu already owns Cmd+Q.
    let native_owns_quit =
        cfg!(target_os = "macos") && std::env::var_os("MACVOXEL_NO_NATIVE_MENU").is_none();
    if !native_owns_quit
        && !ctx.egui_wants_keyboard_input()
        && ctx.input_mut(|i| i.consume_shortcut(&quit))
    {
        ctx.send_viewport_cmd(egui::ViewportCommand::Close);
    }

    egui::Panel::top("menu_bar").show(ui, |ui| {
        egui::MenuBar::new().ui(ui, |ui| {
            ui.menu_button("File", |ui| {
                if item(ui, "New", key(CMD, Key::N)) {
                    session.new_document();
                }
                if item(ui, "Open…", key(CMD, Key::O)) {
                    session.open_dialog();
                }
                ui.menu_button("Open Recent", |ui| {
                    let paths = session.recent_paths();
                    if paths.is_empty() {
                        ui.add_enabled(false, egui::Button::new("No Recent Files"));
                    }
                    for path in paths {
                        let name = path
                            .file_name()
                            .map(|name| name.to_string_lossy().into_owned())
                            .unwrap_or_else(|| path.display().to_string());
                        let response = ui.button(name).on_hover_text(path.display().to_string());
                        if response.clicked() {
                            session.load_path(&path);
                        }
                    }
                });
                ui.separator();
                if item(ui, "Save", key(CMD, Key::S)) {
                    session.save();
                }
                if item(ui, "Save As…", key(CMD_SHIFT, Key::S)) {
                    session.save_as();
                }
                ui.separator();
                if item(ui, "Export Mesh…", key(CMD_SHIFT, Key::E)) {
                    session.export_mesh_dialog();
                }
                ui.separator();
                if item(ui, "Close", key(CMD, Key::W)) {
                    ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                }
                if item(ui, "Quit", Some(quit)) {
                    ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                }
            });

            ui.menu_button("Edit", |ui| {
                if item(ui, "Undo", key(CMD, Key::Z)) {
                    session.undo();
                }
                if item(ui, "Redo", key(CMD_SHIFT, Key::Z)) {
                    session.redo();
                }
                ui.separator();
                if item(ui, "Cut", key(CMD, Key::X)) {
                    session.cut_picked();
                }
                if item(ui, "Copy", key(CMD, Key::C)) {
                    session.copy_picked();
                }
                if item(ui, "Paste", key(CMD, Key::V)) {
                    session.paste_clipboard();
                }
                if item(ui, "Delete", None) {
                    session.delete_picked();
                }
                if item(ui, "New Object", key(CMD_SHIFT, Key::N)) {
                    session.new_object();
                }
                if item(ui, "Duplicate", key(CMD, Key::D)) {
                    session.duplicate_object();
                }
                if item(ui, "Deselect", key(CMD_SHIFT, Key::D)) {
                    session.deselect();
                }
            });
        });
    });
}
