#import "McpServer.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "Camera.h"
#include "Document.h"
#include "EditHistory.h"
#include "EditVolume.h"
#include "EditorContext.h"
#include "Json.h"
#include "MeshExport.h"
#include "PathTraceRenderer.h"
#include "SceneOps.h"
#include "VoxFile.h"
#include "VoxScene.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace macvoxel {
namespace {

constexpr int64_t kParseError = -32700;
constexpr int64_t kInvalidRequest = -32600;
constexpr int64_t kMethodNotFound = -32601;
constexpr int64_t kInvalidParams = -32602;
constexpr size_t kMaxLineBytes = 16 * 1024 * 1024;
constexpr size_t kMaxSetCells = 200000;
constexpr int64_t kMaxFillCells = 2000000;
constexpr size_t kMaxReadCells = 100000;
constexpr int32_t kMaxModelAxis = 256;

const char* kProtocol = "2025-06-18";
const char* kSupported[] = {"2026-07-28", "2025-06-18", "2025-03-26", "2024-11-05"};

const char* kInstructions =
    "MacVoxel edits one MagicaVoxel .vox document. Coordinates are world "
    "voxels of the active object: x and y are horizontal, z is up, and the "
    "world is [-1024, 1024). Palette index 0 erases; 1..255 are colors. Each "
    "object is at most 256 voxels on a side. inspect_document describes the "
    "open file; set_voxel, set_voxels and fill_box edit it; undo and redo "
    "walk that history. set_active_object chooses which object those edits "
    "apply to. save_file writes the .vox, render writes a path-traced PNG, and "
    "export_mesh writes a glTF .glb of the whole scene. "
    "This server is headless: a running MacVoxel window does not update.";

// ---------------------------------------------------------------------------
// JSON-RPC helpers
// ---------------------------------------------------------------------------

Json RpcResult(const Json& id, Json result) {
    Json msg = Json::object();
    msg.set("jsonrpc", Json::str("2.0"));
    msg.set("id", id);
    msg.set("result", std::move(result));
    return msg;
}

Json RpcError(const Json& id, int64_t code, const std::string& message) {
    Json err = Json::object();
    err.set("code", Json::integer(code));
    err.set("message", Json::str(message));
    Json msg = Json::object();
    msg.set("jsonrpc", Json::str("2.0"));
    msg.set("id", id);
    msg.set("error", std::move(err));
    return msg;
}

Json ToolText(const Json& payload, bool is_error) {
    Json block = Json::object();
    block.set("type", Json::str("text"));
    block.set("text", Json::str(is_error ? payload.string() : payload.DumpPretty()));
    Json content = Json::array();
    content.push(std::move(block));
    Json msg = Json::object();
    msg.set("content", std::move(content));
    msg.set("isError", Json::boolean(is_error));
    return msg;
}

Json ToolError(const std::string& message) {
    return ToolText(Json::str(message), true);
}

void WriteLine(const Json& msg) {
    const std::string line = msg.Dump();
    std::fwrite(line.data(), 1, line.size(), stdout);
    std::fputc('\n', stdout);
    std::fflush(stdout);
}

bool ReadLine(std::string* out, bool* too_long) {
    out->clear();
    *too_long = false;
    while (true) {
        const int c = std::fgetc(stdin);
        if (c == EOF) return !out->empty();
        if (c == '\n') return true;
        if (out->size() >= kMaxLineBytes) {
            *too_long = true;
            while (true) {
                const int d = std::fgetc(stdin);
                if (d == EOF || d == '\n') break;
            }
            out->clear();
            return true;
        }
        out->push_back(static_cast<char>(c));
    }
}

bool AsInt(const Json& j, int64_t* out) {
    if (!j.is_number()) return false;
    if (j.is_int()) {
        *out = j.integer();
        return true;
    }
    const double d = j.number();
    if (!std::isfinite(d)) return false;
    const auto i = static_cast<int64_t>(d);
    if (static_cast<double>(i) != d) return false;
    *out = i;
    return true;
}

bool ArgInt(const Json& args, const char* key, int32_t* out, std::string* error) {
    const Json* v = args.find(key);
    if (v == nullptr) {
        *error = std::string("missing integer ") + key;
        return false;
    }
    int64_t i = 0;
    if (!AsInt(*v, &i) || i < INT32_MIN || i > INT32_MAX) {
        *error = std::string(key) + " must be an integer";
        return false;
    }
    *out = static_cast<int32_t>(i);
    return true;
}

bool ArgString(const Json& args, const char* key, std::string* out, std::string* error) {
    const Json* v = args.find(key);
    if (v == nullptr || !v->is_string()) {
        *error = std::string("missing string ") + key;
        return false;
    }
    *out = v->string();
    return true;
}

bool InWorld(int32_t x, int32_t y, int32_t z) {
    return x >= -kWorldHalf && y >= -kWorldHalf && z >= -kWorldHalf && x < kWorldHalf &&
           y < kWorldHalf && z < kWorldHalf;
}

void OrderBox(int32_t* a, int32_t* b) {
    if (*a > *b) std::swap(*a, *b);
}

bool FitsModel(const Bounds3& current, const Bounds3& next, std::string* error) {
    if (next.empty() || (next.size_x() <= kMaxModelAxis && next.size_y() <= kMaxModelAxis &&
                         next.size_z() <= kMaxModelAxis)) {
        return true;
    }
    char buf[160];
    std::snprintf(buf, sizeof(buf),
                  "edit would make the active object %dx%dx%d; .vox models are at most "
                  "%d per axis (current %dx%dx%d)",
                  next.size_x(), next.size_y(), next.size_z(), kMaxModelAxis,
                  current.empty() ? 0 : current.size_x(), current.empty() ? 0 : current.size_y(),
                  current.empty() ? 0 : current.size_z());
    *error = buf;
    return false;
}

void Include(Bounds3* b, int32_t x, int32_t y, int32_t z) {
    if (b->empty()) {
        b->min_x = b->max_x = x;
        b->min_y = b->max_y = y;
        b->min_z = b->max_z = z;
        return;
    }
    b->min_x = std::min(b->min_x, x);
    b->min_y = std::min(b->min_y, y);
    b->min_z = std::min(b->min_z, z);
    b->max_x = std::max(b->max_x, x);
    b->max_y = std::max(b->max_y, y);
    b->max_z = std::max(b->max_z, z);
}

Json BoundsJson(const Bounds3& b) {
    if (b.empty()) return Json::null();
    Json min = Json::array();
    min.push(Json::integer(b.min_x));
    min.push(Json::integer(b.min_y));
    min.push(Json::integer(b.min_z));
    Json max = Json::array();
    max.push(Json::integer(b.max_x));
    max.push(Json::integer(b.max_y));
    max.push(Json::integer(b.max_z));
    Json o = Json::object();
    o.set("min", std::move(min));
    o.set("max", std::move(max));
    return o;
}

std::string HexColor(Color c) {
    char buf[12];
    std::snprintf(buf, sizeof(buf), "#%02x%02x%02x%02x", c.r, c.g, c.b, c.a);
    return buf;
}

struct CellKey {
    int32_t x, y, z;
    bool operator==(const CellKey& o) const { return x == o.x && y == o.y && z == o.z; }
};

struct CellKeyHash {
    size_t operator()(const CellKey& c) const noexcept {
        uint64_t h = static_cast<uint32_t>(c.x);
        h = h * 0x9E3779B185EBCA87ULL + static_cast<uint32_t>(c.y);
        h = h * 0x9E3779B185EBCA87ULL + static_cast<uint32_t>(c.z);
        return static_cast<size_t>(h);
    }
};

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

Json SString(const char* desc) {
    Json j = Json::object();
    j.set("type", Json::str("string"));
    j.set("description", Json::str(desc));
    return j;
}

Json SInt(const char* desc) {
    Json j = Json::object();
    j.set("type", Json::str("integer"));
    j.set("description", Json::str(desc));
    return j;
}

Json SBool(const char* desc) {
    Json j = Json::object();
    j.set("type", Json::str("boolean"));
    j.set("description", Json::str(desc));
    return j;
}

Json SNumber(const char* desc) {
    Json j = Json::object();
    j.set("type", Json::str("number"));
    j.set("description", Json::str(desc));
    return j;
}

Json Required(std::initializer_list<const char*> keys) {
    Json a = Json::array();
    for (const char* k : keys) a.push(Json::str(k));
    return a;
}

Json Tool(const char* name, const char* description, Json properties, Json required) {
    Json schema = Json::object();
    schema.set("type", Json::str("object"));
    schema.set("properties", std::move(properties));
    schema.set("required", std::move(required));
    schema.set("additionalProperties", Json::boolean(false));
    Json t = Json::object();
    t.set("name", Json::str(name));
    t.set("description", Json::str(description));
    t.set("inputSchema", std::move(schema));
    return t;
}

Json ToolList() {
    Json xyz = Json::object();
    xyz.set("x", SInt("World x"));
    xyz.set("y", SInt("World y"));
    xyz.set("z", SInt("World z (up)"));

    Json set_props = xyz;
    set_props.set("palette", SInt("Palette index. 0 erases. 1..255 paint."));

    Json cells = Json::object();
    cells.set("type", Json::str("array"));
    cells.set("maxItems", Json::integer(static_cast<int64_t>(kMaxSetCells)));
    cells.set("description",
              Json::str("Cells to write, last duplicate wins. Each item is "
                        "{x,y,z,palette} or [x,y,z,palette]."));
    Json cell_obj = Json::object();
    cell_obj.set("type", Json::str("object"));
    Json cell_props = Json::object();
    cell_props.set("x", SInt("World x"));
    cell_props.set("y", SInt("World y"));
    cell_props.set("z", SInt("World z"));
    cell_props.set("palette", SInt("Palette index, 0 erases"));
    cell_obj.set("properties", std::move(cell_props));
    Json cell_arr = Json::object();
    cell_arr.set("type", Json::str("array"));
    cell_arr.set("minItems", Json::integer(4));
    cell_arr.set("maxItems", Json::integer(4));
    cell_arr.set("items", SInt("x, y, z, palette"));
    Json items = Json::array();
    items.push(std::move(cell_obj));
    items.push(std::move(cell_arr));
    Json any = Json::object();
    any.set("anyOf", std::move(items));
    cells.set("items", std::move(any));

    Json many = Json::object();
    many.set("cells", std::move(cells));

    Json box = Json::object();
    box.set("x0", SInt("Inclusive min x"));
    box.set("y0", SInt("Inclusive min y"));
    box.set("z0", SInt("Inclusive min z"));
    box.set("x1", SInt("Inclusive max x"));
    box.set("y1", SInt("Inclusive max y"));
    box.set("z1", SInt("Inclusive max z"));

    Json fill = box;
    fill.set("palette", SInt("Palette index written into every cell. 0 erases."));

    Json pal = Json::object();
    pal.set("index", SInt("Palette slot 0..255"));
    pal.set("r", SInt("Red 0..255"));
    pal.set("g", SInt("Green 0..255"));
    pal.set("b", SInt("Blue 0..255"));
    pal.set("a", SInt("Alpha 0..255. Defaults to 255."));

    Json render = Json::object();
    render.set("path", SString("PNG file to write"));
    render.set("width", SInt("Pixels, 1..1024. Default 256."));
    render.set("height", SInt("Pixels, 1..1024. Default 256."));
    render.set("samples", SInt("Path-trace samples, 1..128. Default 16."));
    render.set("bounces", SInt("Max bounces, 0..8. Default 4."));
    render.set("seed", SInt("Sampling seed. Default 1."));
    render.set("denoise", SBool("Run Open Image Denoise before writing. Default true."));
    render.set("yaw", SNumber("Orbit yaw in degrees. Omit to keep the framing angle (30)."));
    render.set("pitch",
               SNumber("Orbit pitch in degrees, -90..90. 90 looks straight down. "
                       "Omit to keep the framing angle (25)."));
    render.set("distance",
               SNumber("Multiple of the framing distance, greater than 0 and at most 100. "
                       "Default 1."));

    Json tools = Json::array();
    tools.push(Tool("new_document",
                    "Replace the session with an empty one-object document and "
                    "the default palette. The file path is cleared.",
                    Json::object(), Json::array()));
    Json open_p = Json::object();
    open_p.set("path", SString("Path of a .vox file to open"));
    tools.push(Tool("open_file", "Open a .vox file, replacing the session document.",
                    std::move(open_p), Required({"path"})));
    Json save_p = Json::object();
    save_p.set("path", SString("Where to write. Omit to overwrite the open file."));
    tools.push(Tool("save_file",
                    "Write the document as a .vox scene. Folds the active object's "
                    "edits back into the scene graph first.",
                    std::move(save_p), Json::array()));
    tools.push(Tool("inspect_document",
                    "Summarize the open document: path, voxel count, bounds, objects "
                    "and the 256-color palette.",
                    Json::object(), Json::array()));
    tools.push(Tool("get_voxel", "Read one world cell of the active object. 0 is empty.",
                    xyz, Required({"x", "y", "z"})));
    tools.push(Tool("set_voxel", "Write one world cell of the active object. One undo step.",
                    set_props, Required({"x", "y", "z", "palette"})));
    tools.push(Tool("set_voxels",
                    "Write many cells of the active object as one undo step. "
                    "At most 200000 cells.",
                    std::move(many), Required({"cells"})));
    tools.push(Tool("fill_box",
                    "Fill an inclusive axis-aligned box in the active object as one "
                    "undo step. At most 2000000 cells.",
                    std::move(fill), Required({"x0", "y0", "z0", "x1", "y1", "z1", "palette"})));
    tools.push(Tool("get_voxels",
                    "List the non-empty cells of the active object inside an inclusive "
                    "box. At most 100000 cells are returned.",
                    std::move(box), Required({"x0", "y0", "z0", "x1", "y1", "z1"})));
    Json entry_props = Json::object();
    entry_props.set("index", SInt("Palette slot 0..255"));
    entry_props.set("r", SInt("Red 0..255"));
    entry_props.set("g", SInt("Green 0..255"));
    entry_props.set("b", SInt("Blue 0..255"));
    entry_props.set("a", SInt("Alpha 0..255. Default 255."));
    Json entry = Json::object();
    entry.set("type", Json::str("object"));
    entry.set("properties", std::move(entry_props));
    Json entries = Json::object();
    entries.set("type", Json::str("array"));
    entries.set("description",
                Json::str("Replace many slots as one undo step. Each item is "
                          "{index, r, g, b, a?}. A later duplicate index wins. "
                          "At most 256 items. Omit this and pass index, r, g, b "
                          "for one slot."));
    entries.set("items", std::move(entry));
    pal.set("entries", std::move(entries));
    tools.push(Tool("set_palette",
                    "Replace one palette slot, or many via entries, as one undo step.",
                    std::move(pal), Json::array()));
    Json active = Json::object();
    active.set("index", SInt("Object index from inspect_document"));
    tools.push(Tool("set_active_object",
                    "Edit a different object. Folds the current object's edits first.",
                    std::move(active), Required({"index"})));
    tools.push(Tool("undo", "Undo the last edit.", Json::object(), Json::array()));
    tools.push(Tool("redo", "Redo the last undone edit.", Json::object(), Json::array()));
    tools.push(Tool("render",
                    "Path-trace the whole scene to a PNG. Blocks until the file is "
                    "written. The camera frames the scene; yaw, pitch, and distance "
                    "orbit that frame.",
                    std::move(render), Required({"path"})));
    Json mesh = Json::object();
    mesh.set("path", SString("glTF binary (.glb) file to write"));
    mesh.set("vertexColors",
             SBool("Bake each voxel's palette color into COLOR_0 and do not write a "
                   "texture. Default false (one palette texture)."));
    mesh.set("merge",
             SBool("Greedy-merge coplanar exposed faces that share a palette slot. "
                   "Default false: one quad per exposed face."));
    tools.push(Tool(
        "export_mesh",
        "Export the whole scene as a glTF 2.0 mesh (.glb) that Blender imports. "
        "Folds the active object's edits in first. Without vertexColors, colors "
        "are a palette texture; with vertexColors, each vertex carries the palette "
        "color and no image is written. merge combines coplanar faces of one "
        "palette slot; leave it false for one quad per exposed face.",
        std::move(mesh), Required({"path"})));

    Json result = Json::object();
    result.set("tools", std::move(tools));
    return result;
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

struct Gpu {
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> queue = nil;
    PathTraceRenderer* renderer = nil;
};

struct Session {
    EditorContext ctx;
    Gpu gpu;
    bool initialized = false;
    bool modern = false;
};

// A fresh Document's BumpAll starts the typed counters over at 1. The
// path tracer only re-uploads when those numbers differ from its cache,
// so a second open can reuse the previous scene's buffers. Continue
// each counter from the document being replaced.
void CarryVersions(Document* fresh, const Document& old) {
    fresh->version = old.version + 1;
    fresh->geometry_version = old.geometry_version + 1;
    fresh->palette_version = old.palette_version + 1;
    fresh->material_version = old.material_version + 1;
    fresh->scene_version = old.scene_version + 1;
    fresh->synced_geometry_version = fresh->geometry_version;
}

void ReplaceDocument(Session* session, Document fresh) {
    CarryVersions(&fresh, session->ctx.document);
    session->ctx.document = std::move(fresh);
    session->ctx.history.Clear();
    session->ctx.selection.Clear();
    session->ctx.ClearObjectSelection();
    session->ctx.editor_mode = EditorMode::Model;
}

Json ObjectJson(const Document& doc, int index, bool active) {
    const SceneObject& o = doc.scene.objects[static_cast<size_t>(index)];
    Json j = Json::object();
    j.set("index", Json::integer(index));
    j.set("name", Json::str(o.name));
    j.set("hidden", Json::boolean(o.hidden));
    j.set("active", Json::boolean(active));
    j.set("model", Json::integer(o.model_id));
    if (active) {
        j.set("voxels", Json::integer(static_cast<int64_t>(doc.grid.FilledCount())));
        j.set("bounds", BoundsJson(doc.grid.Bounds()));
    } else {
        int64_t voxels = 0;
        if (o.model_id >= 0 &&
            static_cast<size_t>(o.model_id) < doc.scene.models.size()) {
            voxels = static_cast<int64_t>(
                doc.scene.models[static_cast<size_t>(o.model_id)].grid.FilledCount());
        }
        j.set("voxels", Json::integer(voxels));
        Bounds3 b;
        if (ObjectWorldBounds(doc.scene, index, &b)) {
            j.set("bounds", BoundsJson(b));
        } else {
            j.set("bounds", Json::null());
        }
    }
    return j;
}

Json Inspect(const Session& session) {
    const Document& doc = session.ctx.document;
    Json objects = Json::array();
    for (int i = 0; i < static_cast<int>(doc.scene.objects.size()); ++i) {
        objects.push(ObjectJson(doc, i, i == doc.active_object));
    }
    Json palette = Json::array();
    for (int i = 0; i < 256; ++i) {
        palette.push(Json::str(HexColor(doc.palette.Get(static_cast<uint8_t>(i)))));
    }
    int64_t voxels = static_cast<int64_t>(doc.grid.FilledCount());
    for (int i = 0; i < static_cast<int>(doc.scene.objects.size()); ++i) {
        if (i == doc.active_object) continue;
        const SceneObject& o = doc.scene.objects[static_cast<size_t>(i)];
        if (o.model_id < 0 || static_cast<size_t>(o.model_id) >= doc.scene.models.size()) {
            continue;
        }
        voxels += static_cast<int64_t>(
            doc.scene.models[static_cast<size_t>(o.model_id)].grid.FilledCount());
    }
    Json j = Json::object();
    j.set("path", Json::str(doc.path));
    j.set("activeObject", Json::integer(doc.active_object));
    j.set("objectCount", Json::integer(static_cast<int64_t>(doc.scene.objects.size())));
    j.set("voxels", Json::integer(voxels));
    j.set("bounds", BoundsJson(doc.scene.WorldBounds()));
    j.set("activeBounds", BoundsJson(doc.grid.Bounds()));
    j.set("unsynced", Json::boolean(doc.geometry_version != doc.synced_geometry_version));
    j.set("canUndo", Json::boolean(session.ctx.history.CanUndo()));
    j.set("canRedo", Json::boolean(session.ctx.history.CanRedo()));
    j.set("objects", std::move(objects));
    j.set("palette", std::move(palette));
    return j;
}

void ResetEmpty(Session* session) {
    Document fresh;
    fresh.palette.ResetToDefault();
    fresh.scene = Scene::FromSingleGrid(fresh.grid);
    fresh.active_object = 0;
    fresh.RebakeActiveObject();
    fresh.BumpAll();
    ReplaceDocument(session, std::move(fresh));
}

Json OpenFile(Session* session, const Json& args) {
    std::string path;
    std::string error;
    if (!ArgString(args, "path", &path, &error)) return ToolError(error);
    if (path.empty()) return ToolError("path is empty");
    Document fresh;
    if (!LoadVoxScene(path, &fresh.scene, &fresh.palette, &error)) return ToolError(error);
    fresh.path = path;
    fresh.EnsureSceneInWorld();
    fresh.active_object = 0;
    fresh.RebakeActiveObject();
    fresh.BumpAll();
    ReplaceDocument(session, std::move(fresh));
    Json j = Json::object();
    j.set("path", Json::str(path));
    j.set("objectCount",
          Json::integer(static_cast<int64_t>(session->ctx.document.scene.objects.size())));
    j.set("voxels", Json::integer(static_cast<int64_t>(session->ctx.document.grid.FilledCount())));
    return ToolText(j, false);
}

Json SaveFile(Session* session, const Json& args) {
    std::string path = session->ctx.document.path;
    if (const Json* p = args.find("path")) {
        if (!p->is_string()) return ToolError("path must be a string");
        path = p->string();
    }
    if (path.empty()) return ToolError("document has no path; pass path");
    Document& doc = session->ctx.document;
    doc.SyncActiveModel();
    std::string error;
    if (!SaveVoxScene(path, doc.scene, doc.palette, &error)) return ToolError(error);
    doc.path = path;
    Json j = Json::object();
    j.set("path", Json::str(path));
    return ToolText(j, false);
}

bool ReadCell(const Json& item, int32_t* x, int32_t* y, int32_t* z, int32_t* palette,
              std::string* error) {
    if (item.is_array()) {
        const auto& a = item.elements();
        if (a.size() != 4) {
            *error = "cell array must be [x, y, z, palette]";
            return false;
        }
        int64_t xi = 0, yi = 0, zi = 0, pi = 0;
        if (!AsInt(a[0], &xi) || !AsInt(a[1], &yi) || !AsInt(a[2], &zi) || !AsInt(a[3], &pi)) {
            *error = "cell array values must be integers";
            return false;
        }
        if (xi < INT32_MIN || xi > INT32_MAX || yi < INT32_MIN || yi > INT32_MAX ||
            zi < INT32_MIN || zi > INT32_MAX) {
            *error = "cell coordinate out of range";
            return false;
        }
        *x = static_cast<int32_t>(xi);
        *y = static_cast<int32_t>(yi);
        *z = static_cast<int32_t>(zi);
        *palette = static_cast<int32_t>(pi);
        return true;
    }
    if (!item.is_object()) {
        *error = "each cell must be an object or [x, y, z, palette]";
        return false;
    }
    if (!ArgInt(item, "x", x, error) || !ArgInt(item, "y", y, error) ||
        !ArgInt(item, "z", z, error) || !ArgInt(item, "palette", palette, error)) {
        return false;
    }
    return true;
}

// `writes` is deduped, last value wins. Rejects anything outside the world
// or a palette slot, and any solid write that would push the active object
// past 256 on an axis. Erases do not grow the object.
bool PrepareWrites(const Document& doc, const std::vector<std::array<int32_t, 4>>& raw,
                   std::vector<CellChange>* out, std::string* error) {
    std::unordered_map<CellKey, size_t, CellKeyHash> index;
    index.reserve(raw.size());
    std::vector<std::array<int32_t, 4>> cells;
    cells.reserve(raw.size());
    for (const auto& r : raw) {
        if (!InWorld(r[0], r[1], r[2])) {
            *error = "coordinate outside the world [-1024, 1024)";
            return false;
        }
        if (r[3] < 0 || r[3] > 255) {
            *error = "palette must be 0..255";
            return false;
        }
        CellKey key{r[0], r[1], r[2]};
        const auto it = index.find(key);
        if (it == index.end()) {
            index.emplace(key, cells.size());
            cells.push_back(r);
        } else {
            cells[it->second][3] = r[3];
        }
    }
    Bounds3 grown = doc.grid.Bounds();
    for (const auto& c : cells) {
        if (c[3] != 0) Include(&grown, c[0], c[1], c[2]);
    }
    if (!FitsModel(doc.grid.Bounds(), grown, error)) return false;

    out->clear();
    out->reserve(cells.size());
    for (const auto& c : cells) {
        const auto old = doc.grid.Get(c[0], c[1], c[2]);
        const auto neu = static_cast<uint8_t>(c[3]);
        if (old == neu) continue;
        CellChange ch{};
        ch.x = c[0];
        ch.y = c[1];
        ch.z = c[2];
        ch.old_val = old;
        ch.new_val = neu;
        out->push_back(ch);
    }
    return true;
}

Json ApplyWrites(Session* session, std::vector<CellChange> changes) {
    Document& doc = session->ctx.document;
    const auto n = static_cast<int64_t>(changes.size());
    if (!changes.empty()) {
        session->ctx.history.BeginOp();
        session->ctx.history.RecordBatch(changes.data(), changes.size());
        doc.ApplyChanges(changes.data(), changes.size());
        session->ctx.history.CommitOp();
        doc.BumpGeometry();
    }
    Json j = Json::object();
    j.set("changed", Json::integer(n));
    j.set("voxels", Json::integer(static_cast<int64_t>(doc.grid.FilledCount())));
    return ToolText(j, false);
}

Json SetVoxel(Session* session, const Json& args) {
    int32_t x = 0, y = 0, z = 0, palette = 0;
    std::string error;
    if (!ArgInt(args, "x", &x, &error) || !ArgInt(args, "y", &y, &error) ||
        !ArgInt(args, "z", &z, &error) || !ArgInt(args, "palette", &palette, &error)) {
        return ToolError(error);
    }
    std::vector<CellChange> changes;
    if (!PrepareWrites(session->ctx.document, {{x, y, z, palette}}, &changes, &error)) {
        return ToolError(error);
    }
    return ApplyWrites(session, std::move(changes));
}

Json SetVoxels(Session* session, const Json& args) {
    const Json* cells = args.find("cells");
    if (cells == nullptr || !cells->is_array()) return ToolError("missing array cells");
    if (cells->elements().size() > kMaxSetCells) {
        return ToolError("too many cells (limit 200000)");
    }
    std::vector<std::array<int32_t, 4>> raw;
    raw.reserve(cells->elements().size());
    std::string error;
    for (const Json& item : cells->elements()) {
        int32_t x = 0, y = 0, z = 0, palette = 0;
        if (!ReadCell(item, &x, &y, &z, &palette, &error)) return ToolError(error);
        raw.push_back({x, y, z, palette});
    }
    std::vector<CellChange> changes;
    if (!PrepareWrites(session->ctx.document, raw, &changes, &error)) return ToolError(error);
    return ApplyWrites(session, std::move(changes));
}

Json FillBox(Session* session, const Json& args) {
    int32_t x0 = 0, y0 = 0, z0 = 0, x1 = 0, y1 = 0, z1 = 0, palette = 0;
    std::string error;
    if (!ArgInt(args, "x0", &x0, &error) || !ArgInt(args, "y0", &y0, &error) ||
        !ArgInt(args, "z0", &z0, &error) || !ArgInt(args, "x1", &x1, &error) ||
        !ArgInt(args, "y1", &y1, &error) || !ArgInt(args, "z1", &z1, &error) ||
        !ArgInt(args, "palette", &palette, &error)) {
        return ToolError(error);
    }
    OrderBox(&x0, &x1);
    OrderBox(&y0, &y1);
    OrderBox(&z0, &z1);
    if (!InWorld(x0, y0, z0) || !InWorld(x1, y1, z1)) {
        return ToolError("coordinate outside the world [-1024, 1024)");
    }
    if (palette < 0 || palette > 255) return ToolError("palette must be 0..255");
    const int64_t nx = static_cast<int64_t>(x1) - x0 + 1;
    const int64_t ny = static_cast<int64_t>(y1) - y0 + 1;
    const int64_t nz = static_cast<int64_t>(z1) - z0 + 1;
    if (nx > kMaxFillCells || ny > kMaxFillCells || nz > kMaxFillCells ||
        nx > kMaxFillCells / ny || nx * ny > kMaxFillCells / nz) {
        return ToolError("box is larger than 2000000 cells");
    }
    std::vector<std::array<int32_t, 4>> raw;
    raw.reserve(static_cast<size_t>(nx * ny * nz));
    for (int32_t z = z0; z <= z1; ++z) {
        for (int32_t y = y0; y <= y1; ++y) {
            for (int32_t x = x0; x <= x1; ++x) raw.push_back({x, y, z, palette});
        }
    }
    std::vector<CellChange> changes;
    if (!PrepareWrites(session->ctx.document, raw, &changes, &error)) return ToolError(error);
    return ApplyWrites(session, std::move(changes));
}

Json GetVoxel(const Session& session, const Json& args) {
    int32_t x = 0, y = 0, z = 0;
    std::string error;
    if (!ArgInt(args, "x", &x, &error) || !ArgInt(args, "y", &y, &error) ||
        !ArgInt(args, "z", &z, &error)) {
        return ToolError(error);
    }
    if (!InWorld(x, y, z)) return ToolError("coordinate outside the world [-1024, 1024)");
    Json j = Json::object();
    j.set("x", Json::integer(x));
    j.set("y", Json::integer(y));
    j.set("z", Json::integer(z));
    j.set("palette", Json::integer(session.ctx.document.grid.Get(x, y, z)));
    return ToolText(j, false);
}

Json GetVoxels(const Session& session, const Json& args) {
    int32_t x0 = 0, y0 = 0, z0 = 0, x1 = 0, y1 = 0, z1 = 0;
    std::string error;
    if (!ArgInt(args, "x0", &x0, &error) || !ArgInt(args, "y0", &y0, &error) ||
        !ArgInt(args, "z0", &z0, &error) || !ArgInt(args, "x1", &x1, &error) ||
        !ArgInt(args, "y1", &y1, &error) || !ArgInt(args, "z1", &z1, &error)) {
        return ToolError(error);
    }
    OrderBox(&x0, &x1);
    OrderBox(&y0, &y1);
    OrderBox(&z0, &z1);
    struct Cell {
        int32_t x, y, z;
        uint8_t v;
    };
    std::vector<Cell> found;
    constexpr int32_t cs = static_cast<int32_t>(VoxelGrid::kChunkSize);
    for (const auto& [coord, chunk] : session.ctx.document.grid.chunks()) {
        if (chunk->filled_count == 0) continue;
        for (int32_t lz = 0; lz < cs; ++lz) {
            for (int32_t ly = 0; ly < cs; ++ly) {
                for (int32_t lx = 0; lx < cs; ++lx) {
                    const uint8_t v = chunk->cells[VoxelGrid::LocalIndex(lx, ly, lz)];
                    if (v == 0) continue;
                    const int32_t x = coord.x * cs + lx;
                    const int32_t y = coord.y * cs + ly;
                    const int32_t z = coord.z * cs + lz;
                    if (x < x0 || x > x1 || y < y0 || y > y1 || z < z0 || z > z1) continue;
                    if (found.size() >= kMaxReadCells) {
                        return ToolError("box contains more than 100000 filled cells");
                    }
                    found.push_back(Cell{x, y, z, v});
                }
            }
        }
    }
    std::sort(found.begin(), found.end(), [](const Cell& a, const Cell& b) {
        if (a.z != b.z) return a.z < b.z;
        if (a.y != b.y) return a.y < b.y;
        return a.x < b.x;
    });
    Json cells = Json::array();
    for (const Cell& c : found) {
        Json item = Json::object();
        item.set("x", Json::integer(c.x));
        item.set("y", Json::integer(c.y));
        item.set("z", Json::integer(c.z));
        item.set("palette", Json::integer(c.v));
        cells.push(std::move(item));
    }
    Json j = Json::object();
    j.set("count", Json::integer(static_cast<int64_t>(found.size())));
    j.set("cells", std::move(cells));
    return ToolText(j, false);
}

bool ByteChannel(const Json& args, const char* key, bool required, uint8_t fallback, uint8_t* out,
                 std::string* error) {
    const Json* v = args.find(key);
    if (v == nullptr) {
        if (!required) {
            *out = fallback;
            return true;
        }
        *error = std::string("missing integer ") + key;
        return false;
    }
    int64_t i = 0;
    if (!AsInt(*v, &i) || i < 0 || i > 255) {
        *error = std::string(key) + " must be an integer 0..255";
        return false;
    }
    *out = static_cast<uint8_t>(i);
    return true;
}

bool ReadColor(const Json& args, Color* out, std::string* error) {
    uint8_t r = 0, g = 0, b = 0, a = 255;
    if (!ByteChannel(args, "r", true, 0, &r, error) ||
        !ByteChannel(args, "g", true, 0, &g, error) ||
        !ByteChannel(args, "b", true, 0, &b, error) ||
        !ByteChannel(args, "a", false, 255, &a, error)) {
        return false;
    }
    *out = Color{r, g, b, a};
    return true;
}

Json SetPalette(Session* session, const Json& args) {
    const bool has_entries = args.find("entries") != nullptr;
    const bool has_index = args.find("index") != nullptr;
    if (has_entries && has_index) return ToolError("pass index or entries, not both");
    if (!has_entries && !has_index) return ToolError("missing integer index");

    struct Slot {
        bool set = false;
        Color color{};
    };
    std::array<Slot, 256> slots{};
    if (!has_entries) {
        int32_t index = 0;
        std::string error;
        if (!ArgInt(args, "index", &index, &error)) return ToolError(error);
        if (index < 0 || index > 255) return ToolError("index must be 0..255");
        Color color;
        if (!ReadColor(args, &color, &error)) return ToolError(error);
        slots[static_cast<size_t>(index)] = Slot{true, color};
    } else {
        const Json* entries = args.find("entries");
        if (!entries->is_array()) return ToolError("entries must be an array");
        if (entries->elements().empty()) return ToolError("entries is empty");
        if (entries->elements().size() > 256) {
            return ToolError("too many palette entries (limit 256)");
        }
        for (const Json& item : entries->elements()) {
            if (!item.is_object()) return ToolError("palette entry must be an object");
            int32_t index = 0;
            std::string error;
            if (!ArgInt(item, "index", &index, &error)) return ToolError(error);
            if (index < 0 || index > 255) return ToolError("index must be 0..255");
            Color color;
            if (!ReadColor(item, &color, &error)) return ToolError(error);
            slots[static_cast<size_t>(index)] = Slot{true, color};
        }
    }

    Document& doc = session->ctx.document;
    int64_t changed = 0;
    bool began = false;
    for (int i = 0; i < 256; ++i) {
        if (!slots[static_cast<size_t>(i)].set) continue;
        const auto slot = static_cast<uint8_t>(i);
        const Color old = doc.palette.Get(slot);
        const Color neu = slots[static_cast<size_t>(i)].color;
        if (old == neu) continue;
        if (!began) {
            session->ctx.history.BeginOp();
            began = true;
        }
        session->ctx.history.RecordPalette(slot, old, neu);
        doc.palette.Set(slot, neu);
        ++changed;
    }
    if (began) {
        session->ctx.history.CommitOp();
        doc.BumpPalette();
    }
    if (!has_entries) {
        int32_t index = 0;
        std::string error;
        ArgInt(args, "index", &index, &error);
        const Color neu = slots[static_cast<size_t>(index)].color;
        if (changed == 0) {
            Json j = Json::object();
            j.set("index", Json::integer(index));
            j.set("changed", Json::boolean(false));
            return ToolText(j, false);
        }
        Json j = Json::object();
        j.set("index", Json::integer(index));
        j.set("color", Json::str(HexColor(neu)));
        return ToolText(j, false);
    }
    Json j = Json::object();
    j.set("changed", Json::integer(changed));
    return ToolText(j, false);
}

Json SetActive(Session* session, const Json& args) {
    int32_t index = 0;
    std::string error;
    if (!ArgInt(args, "index", &index, &error)) return ToolError(error);
    const auto count = static_cast<int32_t>(session->ctx.document.scene.objects.size());
    if (index < 0 || index >= count) return ToolError("object index out of range");
    scene_ops::ActivateObject(session->ctx, index);
    return ToolText(ObjectJson(session->ctx.document, index, true), false);
}

Json Undo(Session* session) {
    if (!session->ctx.history.Undo(session->ctx.document, &session->ctx.selection)) {
        return ToolError("nothing to undo");
    }
    Json j = Json::object();
    j.set("canUndo", Json::boolean(session->ctx.history.CanUndo()));
    j.set("canRedo", Json::boolean(session->ctx.history.CanRedo()));
    j.set("voxels", Json::integer(static_cast<int64_t>(session->ctx.document.grid.FilledCount())));
    return ToolText(j, false);
}

Json Redo(Session* session) {
    if (!session->ctx.history.Redo(session->ctx.document, &session->ctx.selection)) {
        return ToolError("nothing to redo");
    }
    Json j = Json::object();
    j.set("canUndo", Json::boolean(session->ctx.history.CanUndo()));
    j.set("canRedo", Json::boolean(session->ctx.history.CanRedo()));
    j.set("voxels", Json::integer(static_cast<int64_t>(session->ctx.document.grid.FilledCount())));
    return ToolText(j, false);
}

void FitCamera(Camera* camera, const Document& doc) {
    const Bounds3 b = doc.scene.WorldBounds();
    simd::float3 target{0.0f, 0.0f, 0.0f};
    int32_t extent = 1;
    if (!b.empty()) {
        const float cx = (static_cast<float>(b.min_x) + static_cast<float>(b.max_x) + 1.0f) * 0.5f;
        const float cy = (static_cast<float>(b.min_y) + static_cast<float>(b.max_y) + 1.0f) * 0.5f;
        const float cz = (static_cast<float>(b.min_z) + static_cast<float>(b.max_z) + 1.0f) * 0.5f;
        target = simd::float3{cx, cz, -cy};
        extent = std::max({b.size_x(), b.size_y(), b.size_z()});
    }
    camera->Frame(target, static_cast<float>(extent));
}

// Missing key leaves *present false. Present non-numbers are an error.
bool ArgNumber(const Json& args, const char* key, double* out, bool* present, std::string* error) {
    const Json* v = args.find(key);
    if (v == nullptr) {
        *present = false;
        return true;
    }
    *present = true;
    if (!v->is_number() || !std::isfinite(v->number())) {
        *error = std::string(key) + " must be a number";
        return false;
    }
    *out = v->number();
    return true;
}

int32_t ArgIntOr(const Json& args, const char* key, int32_t fallback, int32_t lo, int32_t hi,
                 std::string* error) {
    const Json* v = args.find(key);
    if (v == nullptr) return fallback;
    int64_t i = 0;
    if (!AsInt(*v, &i) || i < lo || i > hi) {
        *error = std::string(key) + " is out of range";
        return fallback;
    }
    return static_cast<int32_t>(i);
}

Json Render(Session* session, const Json& args) {
    std::string path;
    std::string error;
    if (!ArgString(args, "path", &path, &error)) return ToolError(error);
    if (path.empty()) return ToolError("path is empty");
    const int32_t width = ArgIntOr(args, "width", 256, 1, 1024, &error);
    if (!error.empty()) return ToolError(error);
    const int32_t height = ArgIntOr(args, "height", 256, 1, 1024, &error);
    if (!error.empty()) return ToolError(error);
    const int32_t samples = ArgIntOr(args, "samples", 16, 1, 128, &error);
    if (!error.empty()) return ToolError(error);
    const int32_t bounces = ArgIntOr(args, "bounces", 4, 0, 8, &error);
    if (!error.empty()) return ToolError(error);
    const int32_t seed = ArgIntOr(args, "seed", 1, 0, INT32_MAX, &error);
    if (!error.empty()) return ToolError(error);
    bool denoise = true;
    if (const Json* d = args.find("denoise")) {
        if (!d->is_bool()) return ToolError("denoise must be a boolean");
        denoise = d->boolean();
    }
    bool yaw_set = false, pitch_set = false, distance_set = false;
    double yaw_deg = 0, pitch_deg = 0, distance_mul = 1;
    if (!ArgNumber(args, "yaw", &yaw_deg, &yaw_set, &error) ||
        !ArgNumber(args, "pitch", &pitch_deg, &pitch_set, &error) ||
        !ArgNumber(args, "distance", &distance_mul, &distance_set, &error)) {
        return ToolError(error);
    }
    if (pitch_set && (pitch_deg < -90.0 || pitch_deg > 90.0))
        return ToolError("pitch is out of range");
    if (distance_set && (!(distance_mul > 0.0) || distance_mul > 100.0))
        return ToolError("distance is out of range");

    Document& doc = session->ctx.document;
    doc.SyncActiveModel();
    if (doc.scene.empty()) return ToolError("document has no voxels");

    @autoreleasepool {
        if (session->gpu.device == nil) {
            session->gpu.device = MTLCreateSystemDefaultDevice();
            if (session->gpu.device == nil) return ToolError("no Metal device available");
            session->gpu.queue = [session->gpu.device newCommandQueue];
            if (session->gpu.queue == nil) return ToolError("could not create a Metal command queue");
            session->gpu.renderer =
                [[PathTraceRenderer alloc] initWithDevice:session->gpu.device
                                              colorFormat:MTLPixelFormatBGRA8Unorm];
            if (session->gpu.renderer == nil) return ToolError("could not initialize the path tracer");
        }
        Camera camera;
        FitCamera(&camera, doc);
        constexpr double kDeg = 3.14159265358979323846 / 180.0;
        if (yaw_set) camera.yaw = static_cast<float>(yaw_deg * kDeg);
        if (pitch_set) camera.pitch = static_cast<float>(pitch_deg * kDeg);
        if (distance_set)
            camera.distance = static_cast<float>(static_cast<double>(camera.distance) * distance_mul);
        NSError* nerr = nil;
        const CGSize size = CGSizeMake(static_cast<CGFloat>(width), static_cast<CGFloat>(height));
        if (![session->gpu.renderer renderHeadlessSamples:static_cast<uint32_t>(samples)
                                                  context:&session->ctx
                                                   camera:camera
                                                     size:size
                                               maxBounces:static_cast<uint32_t>(bounces)
                                                 baseSeed:static_cast<uint32_t>(seed)
                                             commandQueue:session->gpu.queue
                                                    error:&nerr]) {
            const char* msg = nerr != nil ? [[nerr localizedDescription] UTF8String] : "render failed";
            return ToolError(msg != nullptr ? msg : "render failed");
        }
        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
        if (url == nil) return ToolError("path is not valid UTF-8");
        if (![session->gpu.renderer exportPNGToURL:url
                                      acesTonemap:YES
                                          denoise:denoise ? YES : NO
                                     commandQueue:session->gpu.queue
                                            error:&nerr]) {
            const char* msg = nerr != nil ? [[nerr localizedDescription] UTF8String] : "export failed";
            return ToolError(msg != nullptr ? msg : "export failed");
        }
    }
    Json j = Json::object();
    j.set("path", Json::str(path));
    j.set("width", Json::integer(width));
    j.set("height", Json::integer(height));
    j.set("samples", Json::integer(samples));
    return ToolText(j, false);
}

Json ExportMesh(Session* session, const Json& args) {
    std::string path;
    std::string error;
    if (!ArgString(args, "path", &path, &error)) return ToolError(error);
    if (path.empty()) return ToolError("path is empty");
    bool vertex_colors = false;
    if (const Json* flag = args.find("vertexColors")) {
        if (!flag->is_bool()) return ToolError("vertexColors must be a boolean");
        vertex_colors = flag->boolean();
    }
    bool merge = false;
    if (const Json* flag = args.find("merge")) {
        if (!flag->is_bool()) return ToolError("merge must be a boolean");
        merge = flag->boolean();
    }
    const MeshColorMode mode =
        vertex_colors ? MeshColorMode::VertexColors : MeshColorMode::Texture;
    MeshExportStats stats;
    if (!ExportSceneGlb(session->ctx.document, path, mode, &stats, &error, merge)) {
        return ToolError(error);
    }
    Json j = Json::object();
    j.set("path", Json::str(path));
    j.set("colorMode", Json::str(vertex_colors ? "vertex-colors" : "texture"));
    j.set("merged", Json::boolean(merge));
    j.set("triangles", Json::integer(stats.triangles));
    j.set("vertices", Json::integer(stats.vertices));
    return ToolText(j, false);
}

Json CallTool(Session* session, const Json& params) {
    const Json* name = params.find("name");
    if (name == nullptr || !name->is_string()) return ToolError("missing tool name");
    const Json* args = params.find("arguments");
    Json empty = Json::object();
    const Json& a = (args != nullptr && args->is_object()) ? *args : empty;
    const std::string& n = name->string();
    if (n == "new_document") {
        ResetEmpty(session);
        Json j = Json::object();
        j.set("path", Json::str(""));
        j.set("objectCount", Json::integer(1));
        return ToolText(j, false);
    }
    if (n == "open_file") return OpenFile(session, a);
    if (n == "save_file") return SaveFile(session, a);
    if (n == "inspect_document") return ToolText(Inspect(*session), false);
    if (n == "get_voxel") return GetVoxel(*session, a);
    if (n == "set_voxel") return SetVoxel(session, a);
    if (n == "set_voxels") return SetVoxels(session, a);
    if (n == "fill_box") return FillBox(session, a);
    if (n == "get_voxels") return GetVoxels(*session, a);
    if (n == "set_palette") return SetPalette(session, a);
    if (n == "set_active_object") return SetActive(session, a);
    if (n == "undo") return Undo(session);
    if (n == "redo") return Redo(session);
    if (n == "render") return Render(session, a);
    if (n == "export_mesh") return ExportMesh(session, a);
    return ToolError("unknown tool " + n);
}

Json EmptyList(const char* key) {
    Json j = Json::object();
    j.set(key, Json::array());
    return j;
}

void Annotate(Json* result, bool modern) {
    if (!modern) return;
    result->set("resultType", Json::str("complete"));
    result->set("ttlMs", Json::integer(600000));
    result->set("cacheScope", Json::str("private"));
}

bool SupportedVersion(const std::string& v) {
    for (const char* s : kSupported) {
        if (v == s) return true;
    }
    return false;
}

Json Handle(Session* session, const Json& msg, bool* exit_ok) {
    *exit_ok = false;
    if (!msg.is_object()) return RpcError(Json::null(), kInvalidRequest, "request must be an object");
    const Json* version = msg.find("jsonrpc");
    if (version == nullptr || !version->is_string() || version->string() != "2.0") {
        return RpcError(Json::null(), kInvalidRequest, "jsonrpc must be \"2.0\"");
    }
    const Json* method_v = msg.find("method");
    if (method_v == nullptr || !method_v->is_string()) {
        return RpcError(Json::null(), kInvalidRequest, "missing method");
    }
    const std::string& method = method_v->string();
    const Json* id_v = msg.find("id");
    const bool notification = id_v == nullptr;
    const Json id = notification ? Json::null() : *id_v;
    const Json* params_v = msg.find("params");
    Json empty = Json::object();
    const Json& params = (params_v != nullptr && !params_v->is_null()) ? *params_v : empty;

    if (notification) {
        if (method == "notifications/initialized" || method == "initialized") {
            session->initialized = true;
        }
        *exit_ok = true;  // no reply
        return Json::null();
    }

    if (method == "ping") return RpcResult(id, Json::object());

    if (method == "initialize") {
        std::string asked = kProtocol;
        if (params.is_object()) {
            if (const Json* pv = params.find("protocolVersion")) {
                if (pv->is_string()) asked = pv->string();
            }
        }
        if (!SupportedVersion(asked)) asked = kProtocol;
        session->modern = asked == "2026-07-28";
        session->initialized = true;
        Json info = Json::object();
        info.set("name", Json::str("MacVoxel"));
        info.set("version", Json::str("0.1.0"));
        Json caps = Json::object();
        Json tools_cap = Json::object();
        tools_cap.set("listChanged", Json::boolean(false));
        caps.set("tools", std::move(tools_cap));
        Json result = Json::object();
        result.set("protocolVersion", Json::str(asked));
        result.set("capabilities", std::move(caps));
        result.set("serverInfo", std::move(info));
        result.set("instructions", Json::str(kInstructions));
        return RpcResult(id, std::move(result));
    }

    if (!session->initialized) {
        return RpcError(id, kInvalidRequest, "server not initialized");
    }

    if (method == "tools/list") {
        Json result = ToolList();
        Annotate(&result, session->modern);
        return RpcResult(id, std::move(result));
    }
    if (method == "tools/call") {
        if (!params.is_object()) return RpcError(id, kInvalidParams, "params must be an object");
        return RpcResult(id, CallTool(session, params));
    }
    if (method == "resources/list") {
        Json result = EmptyList("resources");
        Annotate(&result, session->modern);
        return RpcResult(id, std::move(result));
    }
    if (method == "resources/templates/list") {
        Json result = EmptyList("resourceTemplates");
        Annotate(&result, session->modern);
        return RpcResult(id, std::move(result));
    }
    if (method == "prompts/list") {
        Json result = EmptyList("prompts");
        Annotate(&result, session->modern);
        return RpcResult(id, std::move(result));
    }
    if (method == "logging/setLevel") return RpcResult(id, Json::object());
    return RpcError(id, kMethodNotFound, "method not found: " + method);
}

void PrintUsage() {
    std::fprintf(stderr,
                 "usage: MacVoxel mcp\n"
                 "\n"
                 "Model Context Protocol on stdin/stdout, one JSON-RPC message per line.\n"
                 "Headless: the desktop window is not started and does not update.\n");
}

}  // namespace

int RunMcp(int argc, const char* argv[]) {
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "-h") == 0 || std::strcmp(argv[i], "--help") == 0) {
            PrintUsage();
            return 0;
        }
        std::fprintf(stderr, "unknown arg: %s\n", argv[i]);
        PrintUsage();
        return 2;
    }

    std::setvbuf(stdout, nullptr, _IONBF, 0);
    Session session;
    ResetEmpty(&session);

    std::string line;
    bool too_long = false;
    while (ReadLine(&line, &too_long)) {
        if (too_long) {
            WriteLine(RpcError(Json::null(), kParseError, "line too long"));
            too_long = false;
            continue;
        }
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;
        Json msg;
        std::string error;
        if (!Json::Parse(line, &msg, &error)) {
            WriteLine(RpcError(Json::null(), kParseError,
                               error.empty() ? "parse error" : error));
            continue;
        }
        bool silent = false;
        Json reply = Handle(&session, msg, &silent);
        if (!silent) WriteLine(reply);
    }
    return 0;
}

}  // namespace macvoxel
