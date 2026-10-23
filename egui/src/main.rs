//! egui shell preview.
//!
//! ```sh
//! cargo run --manifest-path egui/Cargo.toml
//! cargo run --manifest-path egui/Cargo.toml -- path/to/model.vox
//! ```
//!
//! The window is independent of the SwiftUI/Metal editor. Brush strokes
//! edit an in-memory volume so the panels can be tried against a viewport.

mod panels;
mod state;
mod viewport;

use std::path::PathBuf;

use egui::{Color32, RichText, Visuals};

use state::Session;
use viewport::ViewCache;

fn main() -> eframe::Result {
    let mut session = Session::new();
    if let Some(path) = std::env::args().nth(1) {
        session.load_path(PathBuf::from(path).as_path());
    }

    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([1280.0, 800.0])
            .with_min_inner_size([960.0, 640.0])
            .with_title("MacVoxel"),
        ..Default::default()
    };
    eframe::run_native(
        "MacVoxel",
        options,
        Box::new(move |cc| {
            apply_theme(&cc.egui_ctx);
            Ok(Box::new(Shell {
                session,
                cache: ViewCache::new(),
            }))
        }),
    )
}

struct Shell {
    session: Session,
    cache: ViewCache,
}

impl eframe::App for Shell {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let title = format!("MacVoxel — {}", self.session.document_label());
        ctx.send_viewport_cmd(egui::ViewportCommand::Title(title));
        self.session.take_drops(ctx);
        self.session.take_keys(ctx);

        egui::TopBottomPanel::top("menu").show(ctx, |ui| {
            egui::menu::bar(ui, |ui| {
                ui.menu_button("File", |ui| {
                    if ui.button("New").clicked() {
                        self.session.new_document();
                        ui.close_menu();
                    }
                    if ui.button("Open…").clicked() {
                        self.session.open_dialog();
                        ui.close_menu();
                    }
                });
                ui.menu_button("Edit", |ui| {
                    if ui.button("Undo").clicked() {
                        self.session.undo();
                        ui.close_menu();
                    }
                    if ui.button("Redo").clicked() {
                        self.session.redo();
                        ui.close_menu();
                    }
                });
            });
        });

        egui::TopBottomPanel::bottom("status").show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.label(
                    RichText::new(&self.session.status)
                        .small()
                        .color(Color32::from_gray(150)),
                );
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    let n = self.session.voxel_count();
                    ui.monospace(format!("{n} voxels"));
                });
            });
        });

        egui::SidePanel::left("tools")
            .resizable(true)
            .default_width(200.0)
            .width_range(170.0..=280.0)
            .show(ctx, |ui| {
                egui::ScrollArea::vertical().show(ui, |ui| {
                    panels::left(ui, &mut self.session);
                });
            });

        egui::SidePanel::right("inspector")
            .resizable(true)
            .default_width(280.0)
            .width_range(260.0..=380.0)
            .show(ctx, |ui| {
                egui::ScrollArea::vertical().show(ui, |ui| {
                    panels::right(ui, &mut self.session);
                });
            });

        egui::CentralPanel::default().show(ctx, |ui| {
            viewport::show(ctx, ui, &mut self.session, &mut self.cache);
        });
    }
}

fn apply_theme(ctx: &egui::Context) {
    let mut visuals = Visuals::dark();
    visuals.window_fill = Color32::from_rgb(28, 28, 30);
    visuals.panel_fill = Color32::from_rgb(32, 32, 36);
    visuals.extreme_bg_color = Color32::from_rgb(20, 20, 22);
    visuals.faint_bg_color = Color32::from_rgb(44, 44, 48);
    visuals.widgets.noninteractive.bg_fill = Color32::from_rgb(32, 32, 36);
    visuals.widgets.inactive.bg_fill = Color32::from_rgb(48, 48, 54);
    visuals.widgets.hovered.bg_fill = Color32::from_rgb(64, 64, 72);
    visuals.widgets.active.bg_fill = Color32::from_rgb(48, 96, 168);
    visuals.widgets.open.bg_fill = Color32::from_rgb(42, 42, 48);
    visuals.selection.bg_fill = Color32::from_rgb(48, 110, 190);
    visuals.hyperlink_color = Color32::from_rgb(130, 176, 255);
    visuals.window_corner_radius = egui::CornerRadius::ZERO;
    ctx.set_visuals(visuals);

    let mut style = (*ctx.style()).clone();
    style.spacing.item_spacing = egui::vec2(8.0, 5.0);
    style.spacing.button_padding = egui::vec2(8.0, 3.0);
    for (kind, size) in [
        (egui::TextStyle::Body, 13.0),
        (egui::TextStyle::Button, 13.0),
        (egui::TextStyle::Small, 11.0),
        (egui::TextStyle::Monospace, 12.0),
    ] {
        if let Some(font) = style.text_styles.get_mut(&kind) {
            font.size = size;
        }
    }
    ctx.set_style(style);
}
