//! macOS application menu bar. The window itself has no menu strip; items
//! dispatch through the same session methods as the keyboard shortcuts.
//!
//! Set `MACVOXEL_NO_NATIVE_MENU` to leave the process menu untouched (the
//! egui shortcuts then handle New, Open, Save, Undo, and Redo).

use std::str::FromStr;

use muda::accelerator::Accelerator;
use muda::{Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu};

use crate::state::Session;

pub struct NativeMenu {
    _menu: Menu,
    _app: Submenu,
    _file: Submenu,
    _edit: Submenu,
    _predefined: Vec<PredefinedMenuItem>,
    _items: Vec<MenuItem>,
}

fn accel(sc: &str) -> Option<Accelerator> {
    Accelerator::from_str(&sc.replace("Cmd", "CMD").replace("Shift", "SHIFT")).ok()
}

fn item(id: &str, label: &str, shortcut: &str) -> MenuItem {
    MenuItem::with_id(id, label, true, accel(shortcut))
}

impl NativeMenu {
    pub fn install() -> Self {
        let menu = Menu::new();
        let app = Submenu::new("MacVoxel", true);
        let mut predefined = vec![
            PredefinedMenuItem::hide(Some("Hide MacVoxel")),
            PredefinedMenuItem::hide_others(Some("Hide Others")),
            PredefinedMenuItem::show_all(Some("Show All")),
            PredefinedMenuItem::separator(),
            PredefinedMenuItem::quit(Some("Quit MacVoxel")),
        ];
        for item in &predefined {
            let _ = app.append(item);
        }
        let _ = menu.append(&app);

        let file = Submenu::new("File", true);
        let new = item("mv-new", "New", "Cmd+N");
        let open = item("mv-open", "Open…", "Cmd+O");
        let save = item("mv-save", "Save", "Cmd+S");
        let save_as = item("mv-save-as", "Save As…", "Cmd+Shift+S");
        let file_sep = PredefinedMenuItem::separator();
        let _ = file.append(&new);
        let _ = file.append(&open);
        let _ = file.append(&file_sep);
        let _ = file.append(&save);
        let _ = file.append(&save_as);
        predefined.push(file_sep);
        let _ = menu.append(&file);

        let edit = Submenu::new("Edit", true);
        let undo = item("mv-undo", "Undo", "Cmd+Z");
        let redo = item("mv-redo", "Redo", "Cmd+Shift+Z");
        let _ = edit.append(&undo);
        let _ = edit.append(&redo);
        let _ = menu.append(&edit);

        menu.init_for_nsapp();
        Self {
            _menu: menu,
            _app: app,
            _file: file,
            _edit: edit,
            _predefined: predefined,
            _items: vec![new, open, save, save_as, undo, redo],
        }
    }

    pub fn poll(&self, session: &mut Session, ctx: &egui::Context) {
        while let Ok(ev) = MenuEvent::receiver().try_recv() {
            match ev.id.as_ref() {
                "mv-new" => session.new_document(),
                "mv-open" => session.open_dialog(),
                "mv-save" => session.save(),
                "mv-save-as" => session.save_as(),
                "mv-undo" => session.undo(),
                "mv-redo" => session.redo(),
                _ => continue,
            }
            ctx.request_repaint();
        }
    }
}
