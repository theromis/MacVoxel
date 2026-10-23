//! Model Context Protocol on stdin/stdout.
//!
//! `macvoxel-egui mcp` edits an in-process document and has no window.
//! `macvoxel-egui mcp --connect 127.0.0.1:PORT` drives an editor started with
//! `--control PORT`. `--launch` opens that editor when the port is closed.
//! Screenshots exist only on the connected window. There is no path tracer.

use std::io::{self, BufRead, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::control::ControlClient;
use crate::remote::{self, apply};
use crate::state::Session;

const PROTOCOL: &str = "2025-06-18";
const SUPPORTED: &[&str] = &["2024-11-05", "2025-03-26", "2025-06-18", "2026-07-28"];

pub enum ShotRegion {
    Window,
    Viewport,
    Rect {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    },
}

pub fn parse_shot(params: &Value) -> Result<(ShotRegion, Option<String>), String> {
    let path = remote::opt_str(params, "path")?;
    if params.get("x").is_some()
        || params.get("y").is_some()
        || params.get("width").is_some()
        || params.get("height").is_some()
    {
        let x = num(params, "x")?;
        let y = num(params, "y")?;
        let width = num(params, "width")?;
        let height = num(params, "height")?;
        return Ok((
            ShotRegion::Rect {
                x,
                y,
                width,
                height,
            },
            path,
        ));
    }
    match params
        .get("region")
        .and_then(Value::as_str)
        .unwrap_or("window")
    {
        "window" => Ok((ShotRegion::Window, path)),
        "viewport" => Ok((ShotRegion::Viewport, path)),
        other => Err(format!(
            "region must be \"window\" or \"viewport\", or pass x, y, width, height ({other})"
        )),
    }
}

pub fn run(args: &[String]) -> i32 {
    match parse_args(args) {
        Ok(None) => 0,
        Ok(Some(mode)) => serve(mode),
        Err(err) => {
            eprintln!("{err}");
            2
        }
    }
}

enum Mode {
    Headless,
    Remote { addr: String },
}

fn parse_args(args: &[String]) -> Result<Option<Mode>, String> {
    let mut connect: Option<String> = None;
    let mut launch = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-h" | "--help" => {
                print_help();
                return Ok(None);
            }
            "--launch" => launch = true,
            "--connect" => {
                i += 1;
                let addr = args
                    .get(i)
                    .filter(|s| !s.starts_with('-'))
                    .cloned()
                    .ok_or_else(|| "--connect needs HOST:PORT".to_string())?;
                if addr
                    .rsplit(':')
                    .next()
                    .and_then(|p| p.parse::<u16>().ok())
                    .is_none()
                {
                    return Err(format!("--connect {addr} needs HOST:PORT"));
                }
                connect = Some(addr);
            }
            other => return Err(format!("unknown argument `{other}`")),
        }
        i += 1;
    }
    if launch && connect.is_none() {
        return Err("--launch needs --connect HOST:PORT".into());
    }
    match connect {
        None => Ok(Some(Mode::Headless)),
        Some(addr) => {
            if let Err(err) = prepare_remote(&addr, launch) {
                return Err(err.to_string());
            }
            Ok(Some(Mode::Remote { addr }))
        }
    }
}

fn prepare_remote(addr: &str, launch: bool) -> io::Result<()> {
    if probe(addr) {
        return Ok(());
    }
    if !launch {
        return Err(io::Error::other(format!(
            "MacVoxel is not answering at {addr}. Open it with `macvoxel-egui --control PORT`, or pass --launch"
        )));
    }
    let port = addr.rsplit(':').next().unwrap();
    let exe = std::env::current_exe()?;
    let mut child = Command::new(exe)
        .args(["--control", port])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()?;
    let start = Instant::now();
    loop {
        if child.try_wait()?.is_some() {
            return Err(io::Error::other(
                "the editor exited before the control port opened",
            ));
        }
        if probe(addr) {
            // The editor keeps running after this process drops the handle.
            return Ok(());
        }
        if start.elapsed() > Duration::from_secs(20) {
            return Err(io::Error::other(format!(
                "timed out waiting for the editor at {addr}"
            )));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn probe(addr: &str) -> bool {
    let Ok(sock) = addr.parse() else { return false };
    std::net::TcpStream::connect_timeout(&sock, Duration::from_millis(200)).is_ok()
}

fn serve(mode: Mode) -> i32 {
    let stdin = io::stdin();
    let mut stdout = io::stdout();
    let mut state = Proto::default();
    let mut session = Session::new();
    session.replace_empty();
    let mut remote = match &mode {
        Mode::Headless => None,
        Mode::Remote { addr } => match ControlClient::connect(addr) {
            Ok(client) => Some(client),
            Err(err) => {
                eprintln!("{err}");
                return 1;
            }
        },
    };
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(line) => line,
            Err(err) => {
                eprintln!("stdin: {err}");
                return 1;
            }
        };
        if line.len() > 16 * 1024 * 1024 {
            let _ = writeln!(
                stdout,
                r#"{{"jsonrpc":"2.0","id":null,"error":{{"code":-32700,"message":"line too long"}}}}"#
            );
            let _ = stdout.flush();
            continue;
        }
        if line.trim().is_empty() {
            continue;
        }
        let msg: Value = match serde_json::from_str::<Value>(&line) {
            Ok(msg) => msg,
            Err(_) => {
                let _ = writeln!(
                    stdout,
                    r#"{{"jsonrpc":"2.0","id":null,"error":{{"code":-32700,"message":"parse error"}}}}"#
                );
                let _ = stdout.flush();
                continue;
            }
        };
        if let Some(reply) = dispatch(&mut state, &mut session, remote.as_mut(), &msg) {
            if writeln!(stdout, "{reply}").is_err() || stdout.flush().is_err() {
                return 0;
            }
        }
    }
    0
}

struct Proto {
    initialized: bool,
}

impl Default for Proto {
    fn default() -> Self {
        Self { initialized: false }
    }
}

fn dispatch(
    state: &mut Proto,
    session: &mut Session,
    remote: Option<&mut ControlClient>,
    msg: &Value,
) -> Option<Value> {
    if !msg.is_object() {
        return Some(rpc_error(Value::Null, -32600, "request must be an object"));
    }
    if msg.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
        return Some(rpc_error(Value::Null, -32600, "jsonrpc must be \"2.0\""));
    }
    let Some(method) = msg.get("method").and_then(Value::as_str) else {
        return Some(rpc_error(Value::Null, -32600, "missing method"));
    };
    let id = msg.get("id").cloned();
    let notification = id.is_none();
    let id = id.unwrap_or(Value::Null);
    let params = msg.get("params").cloned().unwrap_or(json!({}));

    if notification {
        if method == "notifications/initialized" || method == "initialized" {
            state.initialized = true;
        }
        return None;
    }
    if method == "ping" {
        return Some(rpc_ok(id, json!({})));
    }
    if method == "initialize" {
        let asked = params
            .get("protocolVersion")
            .and_then(Value::as_str)
            .unwrap_or(PROTOCOL);
        let version = if SUPPORTED.contains(&asked) {
            asked
        } else {
            PROTOCOL
        };
        state.initialized = true;
        return Some(rpc_ok(
            id,
            json!({
                "protocolVersion": version,
                "capabilities": {"tools": {"listChanged": false}},
                "serverInfo": {"name": "MacVoxel", "version": "0.1.0"},
                "instructions": "Edits apply to the active object, in that object's local cells. screenshot, screenshot_viewport, and screenshot_region need an editor started with --control and this server started with --connect. There is no path tracer."
            }),
        ));
    }
    if !state.initialized {
        return Some(rpc_error(id, -32600, "server not initialized"));
    }
    let result = match method {
        "tools/list" => json!({"tools": tools()}),
        "tools/call" => call_tool(session, remote, &params),
        "resources/list" => json!({"resources": []}),
        "resources/templates/list" => json!({"resourceTemplates": []}),
        "prompts/list" => json!({"prompts": []}),
        "logging/setLevel" => json!({}),
        other => return Some(rpc_error(id, -32601, &format!("method not found: {other}"))),
    };
    Some(rpc_ok(id, result))
}

fn call_tool(session: &mut Session, remote: Option<&mut ControlClient>, params: &Value) -> Value {
    if !params.is_object() {
        return rpc_tool_error_value(-32602, "params must be an object");
    }
    let Some(name) = params.get("name").and_then(Value::as_str) else {
        return tool_error("missing tool name");
    };
    let args = params.get("arguments").cloned().unwrap_or(json!({}));
    if !args.is_object() {
        return tool_error("arguments must be an object");
    }
    let mapped = match map_tool(name, &args) {
        Ok(mapped) => mapped,
        Err(err) => return tool_error(&err),
    };
    let result = match remote {
        Some(client) => client.call(&mapped.0, &mapped.1),
        None => apply(session, &mapped.0, &mapped.1),
    };
    match result {
        Ok(value) => tool_ok(value),
        Err(err) => tool_error(&err),
    }
}

fn map_tool(name: &str, args: &Value) -> Result<(String, Value), String> {
    let method = match name {
        "new_document" => "document.new",
        "open_file" => "document.open",
        "save_file" => "document.save",
        "inspect_document" => "document.inspect",
        "get_voxel" => "voxel.get",
        "set_voxel" => "voxel.set",
        "set_voxels" => "voxel.set_many",
        "fill_box" => "voxel.fill",
        "get_voxels" => "voxel.get_box",
        "set_palette" => "palette.set",
        "set_active_object" => "object.set_active",
        "undo" => "edit.undo",
        "redo" => "edit.redo",
        "screenshot" => "ui.screenshot",
        "screenshot_viewport" => "ui.screenshot",
        "screenshot_region" => "ui.screenshot",
        other => return Err(format!("unknown tool `{other}`")),
    };
    let params = match name {
        "screenshot_viewport" => {
            let mut params = args.clone();
            params["region"] = json!("viewport");
            params
        }
        "screenshot_region" => args.clone(),
        _ => args.clone(),
    };
    if name == "screenshot" || name == "screenshot_viewport" || name == "screenshot_region" {
        parse_shot(&params)?;
    }
    Ok((method.to_string(), params))
}

fn tool_ok(value: Value) -> Value {
    let mut shown = value.clone();
    let image = shown
        .as_object_mut()
        .and_then(|obj| obj.remove("pngBase64"))
        .and_then(|v| v.as_str().map(str::to_string));
    let text = serde_json::to_string_pretty(&shown).unwrap_or_else(|_| shown.to_string());
    let mut content = vec![json!({"type": "text", "text": text})];
    if let Some(data) = image {
        content.push(json!({"type": "image", "data": data, "mimeType": "image/png"}));
    }
    json!({"content": content, "isError": false})
}

fn tool_error(message: &str) -> Value {
    json!({
        "content": [{"type": "text", "text": message}],
        "isError": true
    })
}

fn rpc_tool_error_value(code: i32, message: &str) -> Value {
    let text = format!("{code}: {message}");
    json!({"content": [{"type": "text", "text": text}], "isError": true})
}

fn rpc_ok(id: Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn rpc_error(id: Value, code: i32, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

fn num(value: &Value, key: &str) -> Result<f32, String> {
    value
        .get(key)
        .and_then(Value::as_f64)
        .map(|n| n as f32)
        .ok_or_else(|| format!("missing number {key}"))
}

fn tools() -> Vec<Value> {
    vec![
        tool("new_document", "Replace the session with an empty one-object document and the default palette.", json!({}), &[]),
        tool("open_file", "Open a .vox file, replacing the session document.", json!({"path": str_prop("Path of a .vox file")}), &["path"]),
        tool("save_file", "Write the active volume as a .vox file.", json!({"path": str_prop("Where to write. Omit to overwrite the open file.")}), &[]),
        tool("inspect_document", "Path, voxel count, bounds, objects, and the 256-color palette.", json!({}), &[]),
        tool("get_voxel", "Read one local cell of the active object. 0 is empty.", xyz_props(), &["x", "y", "z"]),
        tool("set_voxel", "Write one local cell of the active object. One undo step.", {
            let mut p = xyz_props();
            p["palette"] = int_prop("Palette index. 0 erases. 1..255 paint.");
            p
        }, &["x", "y", "z", "palette"]),
        tool("set_voxels", "Write up to 200000 cells of the active object as one undo step.", json!({"cells": {"type": "array", "description": "Each item is {x,y,z,palette} or [x,y,z,palette]. Last duplicate wins."}}), &["cells"]),
        tool("fill_box", "Fill an inclusive box in the active object. At most 2000000 cells. One undo step.", {
            let mut p = json!({});
            for key in ["x0", "y0", "z0", "x1", "y1", "z1"] {
                p[key] = int_prop("Inclusive box corner");
            }
            p["palette"] = int_prop("Palette index. 0 erases.");
            p
        }, &["x0", "y0", "z0", "x1", "y1", "z1", "palette"]),
        tool("get_voxels", "List non-empty cells of the active object inside an inclusive box. At most 100000.", {
            let mut p = json!({});
            for key in ["x0", "y0", "z0", "x1", "y1", "z1"] {
                p[key] = int_prop("Inclusive box corner");
            }
            p
        }, &["x0", "y0", "z0", "x1", "y1", "z1"]),
        tool("set_palette", "Replace one palette slot, or many via entries, as one undo step.", json!({
            "index": int_prop("Palette slot 0..255"),
            "r": int_prop("Red 0..255"),
            "g": int_prop("Green 0..255"),
            "b": int_prop("Blue 0..255"),
            "a": int_prop("Alpha 0..255. Defaults to 255."),
            "entries": {"type": "array", "description": "Batch of {index,r,g,b,a?}. Omit when passing index."}
        }), &[]),
        tool("set_active_object", "Edit a different object from inspect_document.", json!({"index": int_prop("Object index")}), &["index"]),
        tool("undo", "Undo the last edit.", json!({}), &[]),
        tool("redo", "Redo the last undone edit.", json!({}), &[]),
        tool("screenshot", "PNG of the whole editor window. Only when connected to a window.", json!({"path": str_prop("Optional file to write")}), &[]),
        tool("screenshot_viewport", "PNG of the 3D viewport. Only when connected to a window.", json!({"path": str_prop("Optional file to write")}), &[]),
        tool("screenshot_region", "PNG of a rectangle in window points, origin at the top-left of the client area. Only when connected to a window.", json!({
            "x": num_prop("Left edge, window points"),
            "y": num_prop("Top edge, window points"),
            "width": num_prop("Width in window points"),
            "height": num_prop("Height in window points"),
            "path": str_prop("Optional file to write")
        }), &["x", "y", "width", "height"]),
    ]
}

fn tool(name: &str, description: &str, properties: Value, required: &[&str]) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false
        }
    })
}

fn str_prop(description: &str) -> Value {
    json!({"type": "string", "description": description})
}

fn int_prop(description: &str) -> Value {
    json!({"type": "integer", "description": description})
}

fn num_prop(description: &str) -> Value {
    json!({"type": "number", "description": description})
}

fn xyz_props() -> Value {
    json!({
        "x": int_prop("Local x of the active object"),
        "y": int_prop("Local y"),
        "z": int_prop("Local z (up)")
    })
}

fn print_help() {
    eprintln!(
        "\
usage: macvoxel-egui mcp [--connect HOST:PORT] [--launch]

Model Context Protocol on stdin/stdout, one JSON-RPC message per line.
Without --connect the session is in-process and has no window.
Screenshots need the editor:

  macvoxel-egui --control 7979
  macvoxel-egui mcp --connect 127.0.0.1:7979

--launch opens the editor with that control port when nothing is listening.
There is no path tracer."
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn headless_tool_call_edits_and_refuses_a_screenshot() {
        let mut state = Proto::default();
        let mut session = Session::new();
        session.replace_empty();
        dispatch(
            &mut state,
            &mut session,
            None,
            &json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
        );
        let reply = dispatch(
            &mut state,
            &mut session,
            None,
            &json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "set_voxel", "arguments": {"x": 0, "y": 0, "z": 0, "palette": 9}}}),
        )
        .unwrap();
        assert_eq!(reply["result"]["isError"], false);
        assert_eq!(session.active().cells.get(&(0, 0, 0)), Some(&9));
        let reply = dispatch(
            &mut state,
            &mut session,
            None,
            &json!({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "screenshot_viewport", "arguments": {}}}),
        )
        .unwrap();
        assert_eq!(reply["result"]["isError"], true);
    }
}
