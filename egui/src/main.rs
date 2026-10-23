//! egui shell preview.
//!
//! ```sh
//! cargo run --manifest-path egui/Cargo.toml
//! cargo run --manifest-path egui/Cargo.toml -- path/to/model.vox
//! cargo run --manifest-path egui/Cargo.toml -- --control 7979
//! cargo run --manifest-path egui/Cargo.toml -- mcp
//! cargo run --manifest-path egui/Cargo.toml -- mcp --connect 127.0.0.1:7979 --launch
//! ```
//!
//! `mcp` speaks Model Context Protocol on stdin/stdout. Without `--connect`
//! the session is in-process and has no window. `--connect` drives an editor
//! that was started with `--control`, which is where screenshots come from.
//! `--launch` opens that editor. There is no path tracer.
//!
//! The window is independent of the SwiftUI/Metal editor. On macOS the
//! File and Edit commands live on the application menu bar. Brush strokes
//! edit an in-memory volume so the panels can be tried against a viewport.

mod control;
mod export;
mod gpu;
mod mcp;
mod mesh;
#[cfg(target_os = "macos")]
mod native_menu;
mod panels;
mod remote;
mod state;
mod tools;
mod viewport;

use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::mpsc::Sender;

use egui::{Color32, RichText, Visuals};
use serde_json::Value;

use control::ControlServer;
use mcp::ShotRegion;
use state::{Session, UiAction};
use viewport::ViewCache;

fn main() -> eframe::Result {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|arg| arg == "mcp") {
        std::process::exit(mcp::run(&args[1..]));
    }
    let (port, file) = match parse_gui(&args) {
        Ok(parsed) => parsed,
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(2);
        }
    };
    let control = match port {
        Some(port) => match ControlServer::start(port) {
            Ok(server) => Some(server),
            Err(err) => {
                eprintln!("control port {port}: {err}");
                std::process::exit(1);
            }
        },
        None => None,
    };
    let mut session = Session::new();
    if let Some(path) = file {
        session.load_path(path.as_path());
    }

    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([1280.0, 800.0])
            .with_min_inner_size([960.0, 640.0])
            .with_title("MacVoxel"),
        renderer: eframe::Renderer::Wgpu,
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
                control,
                shots: VecDeque::new(),
                inflight: None,
                next_shot: 0,
                viewport_rect: egui::Rect::NOTHING,
                #[cfg(target_os = "macos")]
                native_menu: None,
            }))
        }),
    )
}

struct Shell {
    session: Session,
    cache: ViewCache,
    control: Option<ControlServer>,
    shots: VecDeque<PendingShot>,
    inflight: Option<InflightShot>,
    next_shot: u64,
    viewport_rect: egui::Rect,
    #[cfg(target_os = "macos")]
    native_menu: Option<native_menu::NativeMenu>,
}

struct PendingShot {
    region: ShotRegion,
    path: Option<String>,
    reply: Sender<Result<Value, String>>,
}

struct InflightShot {
    id: u64,
    region: ShotRegion,
    path: Option<String>,
    reply: Sender<Result<Value, String>>,
    pixels_per_point: f32,
    viewport: egui::Rect,
}

impl eframe::App for Shell {
    fn update(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {
        if let Some(control) = &self.control {
            control.bind_context(ctx);
        }
        self.take_screenshot(ctx);
        self.take_control();
        self.session.clear_ui();
        let screen = ctx.input(|input| input.screen_rect());
        self.session
            .note_ui("window", "Window", screen, UiAction::None);
        #[cfg(target_os = "macos")]
        {
            if self.native_menu.is_none() && std::env::var_os("MACVOXEL_NO_NATIVE_MENU").is_none() {
                self.native_menu = Some(native_menu::NativeMenu::install());
            }
            if let Some(menu) = &mut self.native_menu {
                menu.poll(&mut self.session, ctx);
            }
        }

        let title = format!("MacVoxel — {}", self.session.document_label());
        ctx.send_viewport_cmd(egui::ViewportCommand::Title(title));
        self.session.take_drops(ctx);
        self.session.take_keys(ctx);

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
            self.viewport_rect = viewport::show(
                ctx,
                ui,
                frame.wgpu_render_state(),
                &mut self.session,
                &mut self.cache,
            );
        });
        self.issue_screenshot(ctx);
    }
}

impl Shell {
    fn take_control(&mut self) {
        let Some(control) = &self.control else {
            return;
        };
        for job in control.poll() {
            if job.method == "ui.screenshot" {
                match mcp::parse_shot(&job.params) {
                    Ok((region, path)) => self.shots.push_back(PendingShot {
                        region,
                        path,
                        reply: job.reply,
                    }),
                    Err(err) => {
                        let _ = job.reply.send(Err(err));
                    }
                }
            } else if job.method == "ui.inspect" {
                let _ = job.reply.send(Ok(self.session.describe_ui()));
            } else if job.method == "ui.click" {
                let _ = job.reply.send(self.click_ui(&job.params));
            } else {
                let result = remote::apply(&mut self.session, &job.method, &job.params);
                let _ = job.reply.send(result);
            }
        }
    }

    fn click_ui(&mut self, params: &Value) -> Result<Value, String> {
        let x = params
            .get("x")
            .and_then(Value::as_f64)
            .ok_or("missing number x")? as f32;
        let y = params
            .get("y")
            .and_then(Value::as_f64)
            .ok_or("missing number y")? as f32;
        let Some(region) = self.session.ui_target(x, y) else {
            return Err(format!("no control at {x}, {y}"));
        };
        if region.action == UiAction::Viewport {
            let rect = egui::Rect::from_min_size(
                egui::pos2(region.x, region.y),
                egui::vec2(region.w, region.h),
            );
            let ray = viewport::ray_through(&self.session, rect, egui::pos2(x, y));
            self.session.click_viewport(ray);
        } else {
            self.session.activate_ui(&region)?;
        }
        Ok(serde_json::json!({"id": region.id, "label": region.label}))
    }

    fn take_screenshot(&mut self, ctx: &egui::Context) {
        let events: Vec<_> = ctx.input(|input| input.events.clone());
        for event in events {
            let egui::Event::Screenshot {
                image, user_data, ..
            } = event
            else {
                continue;
            };
            let Some(id) = user_data
                .data
                .as_ref()
                .and_then(|data| data.downcast_ref::<u64>().copied())
            else {
                continue;
            };
            if self.inflight.as_ref().is_some_and(|shot| shot.id == id) {
                let shot = self.inflight.take().expect("shot");
                let _ = shot.reply.send(finish_shot(&shot, &image));
            }
        }
    }

    fn issue_screenshot(&mut self, ctx: &egui::Context) {
        if self.inflight.is_some() {
            ctx.request_repaint();
            return;
        }
        let Some(shot) = self.shots.pop_front() else {
            return;
        };
        self.next_shot = self.next_shot.wrapping_add(1);
        let id = self.next_shot;
        ctx.send_viewport_cmd(egui::ViewportCommand::Screenshot(egui::UserData::new(id)));
        self.inflight = Some(InflightShot {
            id,
            region: shot.region,
            path: shot.path,
            reply: shot.reply,
            pixels_per_point: ctx.pixels_per_point(),
            viewport: self.viewport_rect,
        });
        ctx.request_repaint();
    }
}

fn finish_shot(shot: &InflightShot, image: &egui::ColorImage) -> Result<Value, String> {
    let pixels: Vec<[u8; 4]> = image.pixels.iter().map(|color| color.to_array()).collect();
    let (width, height) = (image.size[0], image.size[1]);
    let region = match shot.region {
        ShotRegion::Window => None,
        ShotRegion::Viewport => Some(pixel_rect(
            shot.viewport,
            shot.pixels_per_point,
            width as i32,
            height as i32,
        )),
        ShotRegion::Rect {
            x,
            y,
            width: w,
            height: h,
        } => Some(pixel_rect(
            egui::Rect::from_min_size(egui::pos2(x, y), egui::vec2(w, h)),
            shot.pixels_per_point,
            width as i32,
            height as i32,
        )),
    };
    let (png, w, h) = remote::png_region(&pixels, width, height, region)?;
    if let Some(path) = &shot.path {
        std::fs::write(path, &png).map_err(|err| format!("{path}: {err}"))?;
    }
    Ok(serde_json::json!({
        "width": w,
        "height": h,
        "path": shot.path,
        "pngBase64": remote::base64_encode(&png),
    }))
}

fn pixel_rect(
    rect: egui::Rect,
    pixels_per_point: f32,
    width: i32,
    height: i32,
) -> (i32, i32, i32, i32) {
    let x = (rect.min.x * pixels_per_point).round() as i32;
    let y = (rect.min.y * pixels_per_point).round() as i32;
    let right = (rect.max.x * pixels_per_point).round() as i32;
    let bottom = (rect.max.y * pixels_per_point).round() as i32;
    let x = x.clamp(0, width);
    let y = y.clamp(0, height);
    let right = right.clamp(x, width);
    let bottom = bottom.clamp(y, height);
    (x, y, right - x, bottom - y)
}

fn parse_gui(args: &[String]) -> Result<(Option<u16>, Option<PathBuf>), String> {
    let mut port = std::env::var("MACVOXEL_CONTROL_PORT")
        .ok()
        .map(|text| parse_port(&text))
        .transpose()?;
    let mut file = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-h" | "--help" => {
                eprintln!(
                    "\
usage: macvoxel-egui [--control PORT] [file.vox]
       macvoxel-egui mcp [--connect HOST:PORT] [--launch]"
                );
                std::process::exit(0);
            }
            "--control" => {
                i += 1;
                let text = args
                    .get(i)
                    .filter(|s| !s.starts_with('-'))
                    .ok_or_else(|| "--control needs a port".to_string())?;
                port = Some(parse_port(text)?);
            }
            other if other.starts_with('-') => return Err(format!("unknown argument `{other}`")),
            other => {
                if file.is_some() {
                    return Err(format!("unexpected argument `{other}`"));
                }
                file = Some(PathBuf::from(other));
            }
        }
        i += 1;
    }
    Ok((port, file))
}

fn parse_port(text: &str) -> Result<u16, String> {
    text.parse::<u16>()
        .map_err(|_| format!("port `{text}` is not a number"))
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
