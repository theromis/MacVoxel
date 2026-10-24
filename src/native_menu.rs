//! macOS application menu bar. The window itself has no menu strip; items
//! dispatch through the same session methods as the keyboard shortcuts.
//!
//! Set `MACVOXEL_NO_NATIVE_MENU` to leave the process menu untouched (the
//! egui shortcuts then handle New, Open, Save, Undo, and Redo).

use std::path::PathBuf;
use std::str::FromStr;

use muda::accelerator::Accelerator;
use muda::{Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu};

use crate::state::Session;

pub struct NativeMenu {
    _menu: Menu,
    _app: Submenu,
    _file: Submenu,
    _edit: Submenu,
    recent: Submenu,
    _predefined: Vec<PredefinedMenuItem>,
    _items: Vec<MenuItem>,
    recent_items: Vec<MenuItem>,
    recent_paths: Vec<PathBuf>,
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
        ];
        for item in &predefined {
            let _ = app.append(item);
        }
        // The predefined Quit terminates the app without a close request,
        // which would skip the unsaved-changes prompt.
        let quit = item("mv-quit", "Quit MacVoxel", "Cmd+Q");
        let _ = app.append(&quit);
        let _ = menu.append(&app);

        let file = Submenu::new("File", true);
        let new = item("mv-new", "New", "Cmd+N");
        let open = item("mv-open", "Open…", "Cmd+O");
        let recent = Submenu::new("Open Recent", true);
        let recent_empty = item("mv-recent-empty", "No Recent Files", "");
        recent_empty.set_enabled(false);
        let _ = recent.append(&recent_empty);
        let save = item("mv-save", "Save", "Cmd+S");
        let save_as = item("mv-save-as", "Save As…", "Cmd+Shift+S");
        let export_mesh = item("mv-export", "Export Mesh…", "Cmd+Shift+E");
        let close = item("mv-close", "Close", "Cmd+W");
        let file_sep = PredefinedMenuItem::separator();
        let file_sep_2 = PredefinedMenuItem::separator();
        let file_sep_3 = PredefinedMenuItem::separator();
        let _ = file.append(&new);
        let _ = file.append(&open);
        let _ = file.append(&recent);
        let _ = file.append(&file_sep);
        let _ = file.append(&save);
        let _ = file.append(&save_as);
        let _ = file.append(&file_sep_2);
        let _ = file.append(&export_mesh);
        let _ = file.append(&file_sep_3);
        let _ = file.append(&close);
        predefined.extend([file_sep, file_sep_2, file_sep_3]);
        let _ = menu.append(&file);

        let edit = Submenu::new("Edit", true);
        let undo = item("mv-undo", "Undo", "Cmd+Z");
        let redo = item("mv-redo", "Redo", "Cmd+Shift+Z");
        let edit_sep = PredefinedMenuItem::separator();
        let cut = item("mv-cut", "Cut", "Cmd+X");
        let copy = item("mv-copy", "Copy", "Cmd+C");
        let paste = item("mv-paste", "Paste", "Cmd+V");
        let delete = item("mv-delete", "Delete", "Cmd+Backspace");
        let new_object = item("mv-new-object", "New Object", "Cmd+Shift+N");
        let duplicate = item("mv-duplicate", "Duplicate", "Cmd+D");
        let deselect = item("mv-deselect", "Deselect", "Cmd+Shift+D");
        let _ = edit.append(&undo);
        let _ = edit.append(&redo);
        let _ = edit.append(&edit_sep);
        let _ = edit.append(&cut);
        let _ = edit.append(&copy);
        let _ = edit.append(&paste);
        let _ = edit.append(&delete);
        let _ = edit.append(&new_object);
        let _ = edit.append(&duplicate);
        let _ = edit.append(&deselect);
        predefined.push(edit_sep);
        let _ = menu.append(&edit);

        menu.init_for_nsapp();
        Self {
            _menu: menu,
            _app: app,
            _file: file,
            _edit: edit,
            recent,
            _predefined: predefined,
            _items: vec![
                quit,
                new,
                open,
                save,
                save_as,
                export_mesh,
                close,
                undo,
                redo,
                cut,
                copy,
                paste,
                delete,
                new_object,
                duplicate,
                deselect,
            ],
            recent_items: vec![recent_empty],
            recent_paths: Vec::new(),
        }
    }

    pub fn poll(&mut self, session: &mut Session, ctx: &egui::Context) {
        while let Ok(ev) = MenuEvent::receiver().try_recv() {
            let id = ev.id.as_ref();
            if let Some(rest) = id.strip_prefix("mv-recent-") {
                if let Ok(index) = rest.parse::<usize>() {
                    if let Some(path) = session.recent_paths().get(index).cloned() {
                        session.load_path(&path);
                    }
                    ctx.request_repaint();
                    continue;
                }
            }
            match id {
                "mv-new" => session.new_document(),
                "mv-open" => session.open_dialog(),
                "mv-save" => session.save(),
                "mv-save-as" => session.save_as(),
                "mv-export" => session.export_mesh_dialog(),
                "mv-close" | "mv-quit" => ctx.send_viewport_cmd(egui::ViewportCommand::Close),
                "mv-undo" => session.undo(),
                "mv-redo" => session.redo(),
                "mv-cut" => session.cut_picked(),
                "mv-copy" => session.copy_picked(),
                "mv-paste" => session.paste_clipboard(),
                "mv-delete" => session.delete_picked(),
                "mv-new-object" => session.new_object(),
                "mv-duplicate" => session.duplicate_object(),
                "mv-deselect" => session.deselect(),
                _ => continue,
            }
            ctx.request_repaint();
        }
        self.sync_recent(session);
    }

    fn sync_recent(&mut self, session: &Session) {
        let paths = session.recent_paths();
        if paths == self.recent_paths {
            return;
        }
        while self.recent.remove_at(0).is_some() {}
        self.recent_items.clear();
        if paths.is_empty() {
            let empty = item("mv-recent-empty", "No Recent Files", "");
            empty.set_enabled(false);
            let _ = self.recent.append(&empty);
            self.recent_items.push(empty);
        } else {
            for (index, path) in paths.iter().enumerate() {
                let name = path
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_else(|| path.display().to_string());
                let entry = MenuItem::with_id(format!("mv-recent-{index}"), name, true, None);
                let _ = self.recent.append(&entry);
                self.recent_items.push(entry);
            }
        }
        self.recent_paths = paths;
    }
}
