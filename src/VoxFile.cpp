#include "VoxFile.h"

#include "Material.h"
#include "Palette.h"
#include "VoxScene.h"
#include "VoxelGrid.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <vector>

namespace macvoxel {
namespace {

constexpr uint32_t kVoxVersion = 150;
constexpr int32_t kInt16RenderCap = 32000;  // leaves headroom under 32767

bool ChunkIdEquals(const char id[4], const char* tag) {
    return id[0] == tag[0] && id[1] == tag[1] && id[2] == tag[2] && id[3] == tag[3];
}

class Reader {
public:
    Reader(const uint8_t* buf, size_t size) : buf_(buf), size_(size) {}
    size_t pos() const { return pos_; }
    size_t remaining() const { return size_ - pos_; }
    bool Eof() const { return pos_ >= size_; }

    bool Read(void* dst, size_t n) {
        if (n > remaining()) return false;
        std::memcpy(dst, buf_ + pos_, n);
        pos_ += n;
        return true;
    }
    bool ReadU32(uint32_t* v) { return Read(v, 4); }
    bool ReadI32(int32_t* v) { return Read(v, 4); }
    bool ReadId(char id[4]) { return Read(id, 4); }
    bool Skip(size_t n) {
        if (n > remaining()) return false;
        pos_ += n;
        return true;
    }
    const uint8_t* PeekPtr() const { return buf_ + pos_; }

    bool ReadString(std::string* out) {
        int32_t n = 0;
        if (!ReadI32(&n) || n < 0) return false;
        if (static_cast<size_t>(n) > remaining()) return false;
        out->assign(reinterpret_cast<const char*>(buf_ + pos_), static_cast<size_t>(n));
        pos_ += static_cast<size_t>(n);
        return true;
    }

    bool ReadDict(std::map<std::string, std::string>* out) {
        int32_t n = 0;
        if (!ReadI32(&n) || n < 0) return false;
        for (int32_t i = 0; i < n; ++i) {
            std::string k, v;
            if (!ReadString(&k) || !ReadString(&v)) return false;
            (*out)[std::move(k)] = std::move(v);
        }
        return true;
    }

private:
    const uint8_t* buf_;
    size_t size_;
    size_t pos_ = 0;
};

bool ReadFile(const std::string& path, std::vector<uint8_t>* out) {
    std::ifstream in(path, std::ios::binary | std::ios::ate);
    if (!in) return false;
    const std::streamsize sz = in.tellg();
    if (sz < 0) return false;
    in.seekg(0, std::ios::beg);
    out->resize(static_cast<size_t>(sz));
    if (sz > 0 && !in.read(reinterpret_cast<char*>(out->data()), sz)) {
        return false;
    }
    return true;
}

void SetError(std::string* out_error, const std::string& msg) {
    if (out_error) *out_error = msg;
}

bool ParseTranslation(const std::string& s, Vec3i32* out) {
    return std::sscanf(s.c_str(), "%d %d %d", &out->x, &out->y, &out->z) == 3;
}

// ---------------------------------------------------------------------------
// Intermediate parse structures
// ---------------------------------------------------------------------------

struct ModelDims { uint32_t x = 0, y = 0, z = 0; };

struct ParsedModel {
    ModelDims dims{};
    std::vector<uint8_t> voxels;  // 4 bytes per voxel: x, y, z, color
};

// Parse a MagicaVoxel MATL property dict into our Material struct.
//
// Mapping notes:
// - `_type`: "_diffuse" / "_metal" / "_glass" / "_emit". Anything else
//   (e.g. "_blend", "_media") falls back to Diffuse since we don't
//   model those.
// - `_ior` is stored as the offset above 1.0, so e.g. 0.3 → IOR 1.3.
// - `_alpha` (or `_trans` in some files) carries glass transparency.
// - `_emit` (0..1) and `_flux` (0..4) round-trip directly. Effective
//   brightness is `emit * 10^flux`, applied at upload time.
Material ParseMatlDict(const std::map<std::string, std::string>& d) {
    Material m;
    auto get_float = [&](const char* key, float fallback) {
        auto it = d.find(key);
        if (it == d.end()) return fallback;
        return std::strtof(it->second.c_str(), nullptr);
    };

    auto type_it = d.find("_type");
    if (type_it != d.end()) {
        const std::string& t = type_it->second;
        if      (t == "_metal") m.type = MaterialType::Metal;
        else if (t == "_glass") m.type = MaterialType::Glass;
        else if (t == "_emit")  m.type = MaterialType::Emissive;
        else                    m.type = MaterialType::Diffuse;
    }

    m.roughness = get_float("_rough", m.roughness);
    m.metallic = get_float("_metal", m.metallic);
    m.ior = 1.0f + get_float("_ior", m.ior - 1.0f);

    // Glass transparency: prefer _alpha, fall back to _trans.
    auto alpha_it = d.find("_alpha");
    if (alpha_it == d.end()) alpha_it = d.find("_trans");
    if (alpha_it != d.end()) {
        m.transparency = std::strtof(alpha_it->second.c_str(), nullptr);
    }

    if (m.type == MaterialType::Emissive) {
        m.emission = get_float("_emit", m.emission);
        const float flux = get_float("_flux", 0.0f);
        const int power = 1 + static_cast<int>(flux);
        m.emissionPower = std::clamp(power, 1, 5);
    }
    return m;
}

bool ParseTransformNode(Reader& r, SceneNode* node) {
    node->kind = SceneNode::Kind::Transform;
    if (!r.ReadI32(&node->id)) return false;
    if (!r.ReadDict(&node->attrs)) return false;
    if (!r.ReadI32(&node->child)) return false;
    int32_t reserved = 0, num_frames = 0;
    if (!r.ReadI32(&reserved) || !r.ReadI32(&node->layer_id) ||
        !r.ReadI32(&num_frames)) {
        return false;
    }
    for (int32_t i = 0; i < num_frames; ++i) {
        AttrDict frame;
        if (!r.ReadDict(&frame)) return false;
        if (i == 0) {
            auto it = frame.find("_t");
            if (it != frame.end()) ParseTranslation(it->second, &node->t);
            it = frame.find("_r");
            if (it != frame.end()) {
                node->rot =
                    static_cast<uint8_t>(std::strtol(it->second.c_str(), nullptr, 10));
            }
        }
        node->frames.push_back(std::move(frame));
    }
    if (node->frames.empty()) node->frames.emplace_back();
    return true;
}

bool ParseGroupNode(Reader& r, SceneNode* node) {
    node->kind = SceneNode::Kind::Group;
    if (!r.ReadI32(&node->id)) return false;
    if (!r.ReadDict(&node->attrs)) return false;
    int32_t n = 0;
    if (!r.ReadI32(&n) || n < 0) return false;
    node->children.resize(static_cast<size_t>(n));
    for (int32_t i = 0; i < n; ++i) {
        if (!r.ReadI32(&node->children[static_cast<size_t>(i)])) return false;
    }
    return true;
}

bool ParseShapeNode(Reader& r, SceneNode* node) {
    node->kind = SceneNode::Kind::Shape;
    if (!r.ReadI32(&node->id)) return false;
    if (!r.ReadDict(&node->attrs)) return false;
    int32_t num_models = 0;
    if (!r.ReadI32(&num_models) || num_models < 0) return false;
    for (int32_t i = 0; i < num_models; ++i) {
        int32_t model_id = 0;
        AttrDict model_attrs;
        if (!r.ReadI32(&model_id) || !r.ReadDict(&model_attrs)) return false;
        node->models.emplace_back(model_id, std::move(model_attrs));
    }
    return true;
}

bool ParseLayerChunk(Reader& r, SceneLayer* layer) {
    if (!r.ReadI32(&layer->id)) return false;
    if (!r.ReadDict(&layer->attrs)) return false;
    return true;  // trailing reserved id (-1) skipped with the chunk
}

}  // namespace

// ---------------------------------------------------------------------------
// Load
// ---------------------------------------------------------------------------

bool LoadVoxScene(const std::string& path,
                  Scene* out_scene,
                  Palette* out_palette,
                  std::string* out_error) {
    std::vector<uint8_t> bytes;
    if (!ReadFile(path, &bytes)) {
        SetError(out_error, "could not read file");
        return false;
    }

    Reader r(bytes.data(), bytes.size());

    char header[4];
    uint32_t version = 0;
    if (!r.ReadId(header) || !r.ReadU32(&version)) {
        SetError(out_error, "file too short for header");
        return false;
    }
    if (!ChunkIdEquals(header, "VOX ")) {
        SetError(out_error, "not a .vox file (missing 'VOX ' magic)");
        return false;
    }

    char main_id[4];
    uint32_t main_content = 0, main_children = 0;
    if (!r.ReadId(main_id) || !r.ReadU32(&main_content) || !r.ReadU32(&main_children)) {
        SetError(out_error, "truncated MAIN header");
        return false;
    }
    if (!ChunkIdEquals(main_id, "MAIN")) {
        SetError(out_error, "expected MAIN chunk after header");
        return false;
    }
    if (!r.Skip(main_content)) {
        SetError(out_error, "truncated MAIN content");
        return false;
    }

    Reader children(r.PeekPtr(), main_children);

    std::vector<ParsedModel> models;
    ModelDims pending_size{};
    bool have_pending_size = false;
    Palette palette;
    bool rgba_seen = false;

    Scene scene;
    std::map<int32_t, Material> materials;

    while (!children.Eof()) {
        char id[4];
        uint32_t content_size = 0, child_size = 0;
        if (!children.ReadId(id) || !children.ReadU32(&content_size) ||
            !children.ReadU32(&child_size)) {
            SetError(out_error, "truncated chunk header");
            return false;
        }
        if (children.pos() + content_size + child_size > main_children) {
            SetError(out_error, "chunk extends past MAIN");
            return false;
        }
        const uint8_t* content_ptr = children.PeekPtr();

        if (ChunkIdEquals(id, "SIZE")) {
            if (content_size != 12) {
                SetError(out_error, "SIZE chunk has wrong content size");
                return false;
            }
            Reader cr(content_ptr, content_size);
            ModelDims d{};
            cr.ReadU32(&d.x);
            cr.ReadU32(&d.y);
            cr.ReadU32(&d.z);
            pending_size = d;
            have_pending_size = true;
        } else if (ChunkIdEquals(id, "XYZI")) {
            if (!have_pending_size) {
                SetError(out_error, "XYZI chunk before SIZE");
                return false;
            }
            Reader cr(content_ptr, content_size);
            uint32_t n = 0;
            if (!cr.ReadU32(&n)) {
                SetError(out_error, "truncated XYZI");
                return false;
            }
            if (cr.remaining() < n * 4u) {
                SetError(out_error, "XYZI voxel data truncated");
                return false;
            }
            ParsedModel m;
            m.dims = pending_size;
            m.voxels.assign(cr.PeekPtr(), cr.PeekPtr() + n * 4u);
            models.push_back(std::move(m));
            have_pending_size = false;
        } else if (ChunkIdEquals(id, "RGBA")) {
            if (content_size < 1024) {
                SetError(out_error, "RGBA chunk shorter than 1024 bytes");
                return false;
            }
            for (size_t i = 0; i < 255; ++i) {
                Color c;
                c.r = content_ptr[i * 4 + 0];
                c.g = content_ptr[i * 4 + 1];
                c.b = content_ptr[i * 4 + 2];
                c.a = content_ptr[i * 4 + 3];
                palette.Set(static_cast<uint8_t>(i + 1), c);
            }
            palette.Set(0, Color{0, 0, 0, 0});
            rgba_seen = true;
        } else if (ChunkIdEquals(id, "nTRN")) {
            Reader cr(content_ptr, content_size);
            SceneNode n;
            if (ParseTransformNode(cr, &n)) scene.nodes[n.id] = std::move(n);
        } else if (ChunkIdEquals(id, "nGRP")) {
            Reader cr(content_ptr, content_size);
            SceneNode n;
            if (ParseGroupNode(cr, &n)) scene.nodes[n.id] = std::move(n);
        } else if (ChunkIdEquals(id, "nSHP")) {
            Reader cr(content_ptr, content_size);
            SceneNode n;
            if (ParseShapeNode(cr, &n)) scene.nodes[n.id] = std::move(n);
        } else if (ChunkIdEquals(id, "LAYR")) {
            Reader cr(content_ptr, content_size);
            SceneLayer layer;
            if (ParseLayerChunk(cr, &layer)) scene.layers.push_back(std::move(layer));
        } else if (ChunkIdEquals(id, "MATL")) {
            Reader cr(content_ptr, content_size);
            int32_t mid = 0;
            std::map<std::string, std::string> attrs;
            if (cr.ReadI32(&mid) && cr.ReadDict(&attrs)) {
                materials[mid] = ParseMatlDict(attrs);
            }
        } else if (ChunkIdEquals(id, "PACK") || ChunkIdEquals(id, "rOBJ") ||
                   ChunkIdEquals(id, "rCAM") || ChunkIdEquals(id, "NOTE") ||
                   ChunkIdEquals(id, "IMAP") || ChunkIdEquals(id, "MATT")) {
            // Recognised but not relevant for geometry/palette.
        } else {
            fprintf(stderr,
                    "[vox] unknown chunk '%c%c%c%c' (%u/%u bytes), skipping\n",
                    id[0], id[1], id[2], id[3], content_size, child_size);
        }

        if (!children.Skip(content_size + child_size)) {
            SetError(out_error, "failed to advance past chunk");
            return false;
        }
    }

    if (models.empty()) {
        SetError(out_error, "file has no models (no SIZE/XYZI pair found)");
        return false;
    }

    // Convert SIZE/XYZI pairs into model-local grids.
    for (const ParsedModel& m : models) {
        SceneModel sm;
        sm.dims[0] = static_cast<int32_t>(m.dims.x);
        sm.dims[1] = static_cast<int32_t>(m.dims.y);
        sm.dims[2] = static_cast<int32_t>(m.dims.z);
        const size_t voxel_count = m.voxels.size() / 4;
        for (size_t i = 0; i < voxel_count; ++i) {
            sm.grid.Set(m.voxels[i * 4 + 0], m.voxels[i * 4 + 1],
                        m.voxels[i * 4 + 2], m.voxels[i * 4 + 3]);
        }
        scene.models.push_back(std::move(sm));
    }

    if (!scene.nodes.empty()) {
        scene.root_id =
            scene.nodes.count(0) ? 0 : scene.nodes.begin()->first;
        scene.RebuildObjects();
    }
    if (scene.objects.empty()) {
        // No (or broken) scene graph: synthesize the canonical skeleton
        // around model 0, corner-at-origin — the leaf translation equals
        // the center pivot the flatten subtracts, matching the legacy
        // fallback placement exactly. Extra graphless models stay
        // unreferenced (the legacy loader dropped them too).
        scene.nodes.clear();
        const SceneModel& m0 = scene.models[0];
        const Vec3i32 h{m0.dims[0] / 2, m0.dims[1] / 2, m0.dims[2] / 2};

        SceneNode root;
        root.kind = SceneNode::Kind::Transform;
        root.id = 0;
        root.child = 1;
        root.frames.emplace_back();
        SceneNode group;
        group.kind = SceneNode::Kind::Group;
        group.id = 1;
        group.children.push_back(2);
        SceneNode leaf;
        leaf.kind = SceneNode::Kind::Transform;
        leaf.id = 2;
        leaf.child = 3;
        leaf.frames.emplace_back();
        leaf.t = h;
        SceneNode shape;
        shape.kind = SceneNode::Kind::Shape;
        shape.id = 3;
        shape.models.emplace_back(0, AttrDict{});

        scene.nodes[0] = std::move(root);
        scene.nodes[1] = std::move(group);
        scene.nodes[2] = std::move(leaf);
        scene.nodes[3] = std::move(shape);
        scene.root_id = 0;
        scene.RebuildObjects();
    }

    // Render-side limitation: the per-instance attribute is int16. Refuse
    // scenes that would overflow it. Kept loose (kInt16RenderCap < INT16_MAX)
    // so the renderer never sees a corner case.
    const Bounds3 wb = scene.WorldBounds();
    if (!wb.empty()) {
        const int32_t min_w = std::min({wb.min_x, wb.min_y, wb.min_z});
        const int32_t max_w = std::max({wb.max_x, wb.max_y, wb.max_z});
        if (min_w < -kInt16RenderCap || max_w > kInt16RenderCap) {
            char buf[160];
            std::snprintf(buf, sizeof(buf),
                          "scene exceeds renderer's int16 coordinate range "
                          "(world coords span [%d, %d])",
                          min_w, max_w);
            SetError(out_error, buf);
            return false;
        }
    }

    if (!rgba_seen) palette.ResetToDefault();

    // MATL ids are 1-based and map directly to palette indices.
    for (const auto& [mid, mat] : materials) {
        if (mid >= 1 && mid <= 255) {
            palette.SetMaterial(static_cast<uint8_t>(mid), mat);
        }
    }

    *out_scene = std::move(scene);
    *out_palette = palette;
    (void)version;
    return true;
}

bool LoadVox(const std::string& path,
             VoxelGrid* out_grid,
             Palette* out_palette,
             std::string* out_error) {
    Scene scene;
    Palette palette;
    if (!LoadVoxScene(path, &scene, &palette, out_error)) return false;
    VoxelGrid grid;
    FlattenScene(scene, -1, &grid);
    *out_grid = std::move(grid);
    *out_palette = palette;
    return true;
}

// ---------------------------------------------------------------------------
// Save
// ---------------------------------------------------------------------------

namespace {

void AppendU32(std::vector<uint8_t>* out, uint32_t v) {
    out->push_back(static_cast<uint8_t>(v & 0xff));
    out->push_back(static_cast<uint8_t>((v >> 8) & 0xff));
    out->push_back(static_cast<uint8_t>((v >> 16) & 0xff));
    out->push_back(static_cast<uint8_t>((v >> 24) & 0xff));
}

void AppendId(std::vector<uint8_t>* out, const char tag[4]) {
    out->push_back(static_cast<uint8_t>(tag[0]));
    out->push_back(static_cast<uint8_t>(tag[1]));
    out->push_back(static_cast<uint8_t>(tag[2]));
    out->push_back(static_cast<uint8_t>(tag[3]));
}

// MATL DICT entries: int32 length-prefixed UTF-8 strings. AppendU32 is
// byte-identical to the int32 the reader expects for non-negative
// lengths (we only emit short keys / printable values).
void AppendString(std::vector<uint8_t>* out, const std::string& s) {
    AppendU32(out, static_cast<uint32_t>(s.size()));
    out->insert(out->end(), s.begin(), s.end());
}

bool MaterialIsDefault(const Material& m) {
    return m.type == MaterialType::Diffuse &&
           m.roughness == 1.0f &&
           m.metallic == 0.0f &&
           m.emission == 0.0f &&
           m.emissionPower == 1 &&
           m.transparency == 0.0f &&
           m.ior == 1.5f;
}

// %g formatting with the C-locale-default decimal point. Adequate
// precision for the loader's strtof — exact bit-equality isn't needed,
// just round-trip-stability for the values the editor surfaces.
std::string FormatFloat(float v) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%g", static_cast<double>(v));
    return buf;
}

const char* MatlTypeString(MaterialType t) {
    switch (t) {
        case MaterialType::Metal:    return "_metal";
        case MaterialType::Glass:    return "_glass";
        case MaterialType::Emissive: return "_emit";
        case MaterialType::Diffuse:  return "_diffuse";
    }
    return "_diffuse";
}

void AppendI32(std::vector<uint8_t>* out, int32_t v) {
    AppendU32(out, static_cast<uint32_t>(v));
}

void AppendDict(std::vector<uint8_t>* out, const AttrDict& d) {
    AppendU32(out, static_cast<uint32_t>(d.size()));
    for (const auto& [k, v] : d) {
        AppendString(out, k);
        AppendString(out, v);
    }
}

void AppendChunk(std::vector<uint8_t>* out, const char tag[4],
                 const std::vector<uint8_t>& body) {
    AppendId(out, tag);
    AppendU32(out, static_cast<uint32_t>(body.size()));
    AppendU32(out, 0);
    out->insert(out->end(), body.begin(), body.end());
}

void AppendRgbaChunk(std::vector<uint8_t>* children, const Palette& palette) {
    AppendId(children, "RGBA");
    AppendU32(children, 1024);
    AppendU32(children, 0);
    for (size_t i = 0; i < 255; ++i) {
        const Color c = palette.Get(static_cast<uint8_t>(i + 1));
        children->push_back(c.r);
        children->push_back(c.g);
        children->push_back(c.b);
        children->push_back(c.a);
    }
    children->push_back(0);
    children->push_back(0);
    children->push_back(0);
    children->push_back(0);
}

// MATL chunks — one per non-default palette slot. Skipping defaults
// keeps file size down and is round-trip-safe (a missing MATL on
// load gets the Material struct's defaults, which is what we'd
// write back). Emissive carries _emit + _flux on top of the common
// keys; Glass adds _alpha; everything else gets type / rough /
// metal / ior.
void AppendMatlChunks(std::vector<uint8_t>* children, const Palette& palette) {
    for (int i = 1; i <= 255; ++i) {
        const Material m = palette.GetMaterial(static_cast<uint8_t>(i));
        if (MaterialIsDefault(m)) continue;

        std::vector<std::pair<std::string, std::string>> kv;
        kv.emplace_back("_type", MatlTypeString(m.type));
        kv.emplace_back("_rough", FormatFloat(m.roughness));
        kv.emplace_back("_metal", FormatFloat(m.metallic));
        kv.emplace_back("_ior", FormatFloat(m.ior - 1.0f));
        // Not just Glass: the loader keeps _alpha/_trans for types that
        // fall back to Diffuse (e.g. Magica's _blend), so serialize any
        // non-zero transparency or it's lost on the next load.
        if (m.transparency != 0.0f) {
            kv.emplace_back("_alpha", FormatFloat(m.transparency));
        }
        if (m.type == MaterialType::Emissive) {
            kv.emplace_back("_emit", FormatFloat(m.emission));
            kv.emplace_back(
                "_flux",
                FormatFloat(static_cast<float>(m.emissionPower - 1)));
        }

        std::vector<uint8_t> body;
        AppendU32(&body, static_cast<uint32_t>(i));  // material id
        AppendU32(&body, static_cast<uint32_t>(kv.size()));
        for (const auto& [k, v] : kv) {
            AppendString(&body, k);
            AppendString(&body, v);
        }
        AppendChunk(children, "MATL", body);
    }
}

bool WriteVoxFile(const std::string& path,
                  const std::vector<uint8_t>& children,
                  std::string* out_error) {
    std::vector<uint8_t> file;
    AppendId(&file, "VOX ");
    AppendU32(&file, kVoxVersion);
    AppendId(&file, "MAIN");
    AppendU32(&file, 0);
    AppendU32(&file, static_cast<uint32_t>(children.size()));
    file.insert(file.end(), children.begin(), children.end());

    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) {
        SetError(out_error, "could not open file for writing");
        return false;
    }
    out.write(reinterpret_cast<const char*>(file.data()),
              static_cast<std::streamsize>(file.size()));
    if (!out) {
        SetError(out_error, "write failed");
        return false;
    }
    return true;
}

// Pre-order DFS over the reachable node tree, assigning dense new ids
// (Magica's emission order: parent before child, siblings in group
// order). Instanced subtrees are visited once and shared by id.
void CollectSaveOrder(const Scene& scene, int32_t node_id,
                      std::map<int32_t, int32_t>* node_new,
                      std::vector<int32_t>* emit_order,
                      std::map<int32_t, int32_t>* model_new,
                      std::vector<int32_t>* model_order,
                      int32_t* next_id) {
    if (node_new->count(node_id)) return;
    auto it = scene.nodes.find(node_id);
    if (it == scene.nodes.end()) return;
    (*node_new)[node_id] = (*next_id)++;
    emit_order->push_back(node_id);
    const SceneNode& n = it->second;
    switch (n.kind) {
        case SceneNode::Kind::Transform:
            CollectSaveOrder(scene, n.child, node_new, emit_order, model_new,
                             model_order, next_id);
            break;
        case SceneNode::Kind::Group:
            for (int32_t c : n.children) {
                CollectSaveOrder(scene, c, node_new, emit_order, model_new,
                                 model_order, next_id);
            }
            break;
        case SceneNode::Kind::Shape:
            for (const auto& [mid, attrs] : n.models) {
                if (mid < 0 ||
                    static_cast<size_t>(mid) >= scene.models.size()) {
                    continue;
                }
                if (!model_new->count(mid)) {
                    (*model_new)[mid] =
                        static_cast<int32_t>(model_order->size());
                    model_order->push_back(mid);
                }
            }
            break;
    }
}

}  // namespace

bool SaveVox(const std::string& path,
             const VoxelGrid& grid,
             const Palette& palette,
             std::string* out_error) {
    if (grid.empty()) {
        SetError(out_error, "cannot save an empty grid");
        return false;
    }
    const Bounds3 b = grid.Bounds();
    if (b.size_x() > 256 || b.size_y() > 256 || b.size_z() > 256) {
        char buf[160];
        std::snprintf(buf, sizeof(buf),
                      "scene exceeds .vox single-model limit of 256 per axis "
                      "(bounds %dx%dx%d)",
                      b.size_x(), b.size_y(), b.size_z());
        SetError(out_error, buf);
        return false;
    }

    // Iterate chunks to harvest filled cells, shifting world coords to
    // origin so the saved single-model file starts at (0, 0, 0).
    std::vector<uint8_t> xyzi_voxels;
    xyzi_voxels.reserve(grid.FilledCount() * 4);
    for (const auto& [coord, chunk] : grid.chunks()) {
        if (chunk->filled_count == 0) continue;
        const int32_t base_x = coord.x * static_cast<int32_t>(VoxelGrid::kChunkSize);
        const int32_t base_y = coord.y * static_cast<int32_t>(VoxelGrid::kChunkSize);
        const int32_t base_z = coord.z * static_cast<int32_t>(VoxelGrid::kChunkSize);
        for (uint32_t lz = 0; lz < VoxelGrid::kChunkSize; ++lz) {
            for (uint32_t ly = 0; ly < VoxelGrid::kChunkSize; ++ly) {
                for (uint32_t lx = 0; lx < VoxelGrid::kChunkSize; ++lx) {
                    const size_t li = lx + ly * VoxelGrid::kChunkSize +
                                      lz * VoxelGrid::kChunkSize * VoxelGrid::kChunkSize;
                    const uint8_t v = chunk->cells[li];
                    if (v == 0) continue;
                    const int32_t sx = base_x + static_cast<int32_t>(lx) - b.min_x;
                    const int32_t sy = base_y + static_cast<int32_t>(ly) - b.min_y;
                    const int32_t sz = base_z + static_cast<int32_t>(lz) - b.min_z;
                    xyzi_voxels.push_back(static_cast<uint8_t>(sx));
                    xyzi_voxels.push_back(static_cast<uint8_t>(sy));
                    xyzi_voxels.push_back(static_cast<uint8_t>(sz));
                    xyzi_voxels.push_back(v);
                }
            }
        }
    }
    const uint32_t num_voxels = static_cast<uint32_t>(xyzi_voxels.size() / 4);

    std::vector<uint8_t> children;

    AppendId(&children, "SIZE");
    AppendU32(&children, 12);
    AppendU32(&children, 0);
    AppendU32(&children, static_cast<uint32_t>(b.size_x()));
    AppendU32(&children, static_cast<uint32_t>(b.size_y()));
    AppendU32(&children, static_cast<uint32_t>(b.size_z()));

    AppendId(&children, "XYZI");
    AppendU32(&children, 4 + 4 * num_voxels);
    AppendU32(&children, 0);
    AppendU32(&children, num_voxels);
    children.insert(children.end(), xyzi_voxels.begin(), xyzi_voxels.end());

    AppendRgbaChunk(&children, palette);
    AppendMatlChunks(&children, palette);
    return WriteVoxFile(path, children, out_error);
}

bool SaveVoxScene(const std::string& path,
                  const Scene& scene,
                  const Palette& palette,
                  std::string* out_error) {
    if (scene.nodes.empty() || scene.empty()) {
        SetError(out_error, "cannot save an empty scene");
        return false;
    }

    // A root that isn't an nTRN (never produced by our loader, but the
    // node map is arbitrary) gets a synthesized identity wrapper so the
    // file keeps the canonical nTRN(0) root convention.
    const auto root_it = scene.nodes.find(scene.root_id);
    if (root_it == scene.nodes.end()) {
        SetError(out_error, "scene root node missing");
        return false;
    }
    const bool wrap_root =
        root_it->second.kind != SceneNode::Kind::Transform;

    std::map<int32_t, int32_t> node_new;
    std::vector<int32_t> emit_order;
    std::map<int32_t, int32_t> model_new;
    std::vector<int32_t> model_order;
    int32_t next_id = wrap_root ? 1 : 0;
    CollectSaveOrder(scene, scene.root_id, &node_new, &emit_order,
                     &model_new, &model_order, &next_id);
    if (model_order.empty()) {
        SetError(out_error, "scene references no models");
        return false;
    }

    // Per-model guards: .vox models are uint8-addressed, 256 per axis.
    for (int32_t mid : model_order) {
        const SceneModel& m = scene.models[static_cast<size_t>(mid)];
        const Bounds3 b = m.grid.Bounds();
        if (!b.empty() &&
            (b.min_x < 0 || b.min_y < 0 || b.min_z < 0 || b.max_x > 255 ||
             b.max_y > 255 || b.max_z > 255)) {
            SetError(out_error,
                     "model voxels escape the .vox 256-per-axis local box");
            return false;
        }
        if (m.dims[0] > 256 || m.dims[1] > 256 || m.dims[2] > 256) {
            SetError(out_error, "model SIZE exceeds 256 per axis");
            return false;
        }
    }

    std::vector<uint8_t> children;

    // SIZE + XYZI per referenced model, renumbered in DFS-encounter order.
    for (int32_t mid : model_order) {
        const SceneModel& m = scene.models[static_cast<size_t>(mid)];
        std::vector<uint8_t> size_body;
        AppendI32(&size_body, std::max(m.dims[0], 1));
        AppendI32(&size_body, std::max(m.dims[1], 1));
        AppendI32(&size_body, std::max(m.dims[2], 1));
        AppendChunk(&children, "SIZE", size_body);

        std::vector<uint8_t> xyzi;
        AppendU32(&xyzi, static_cast<uint32_t>(m.grid.FilledCount()));
        // Canonical chunk order (the hash map's iteration order depends on
        // insertion history) so identical scenes save byte-identically.
        std::vector<const VoxelGrid::Chunk*> sorted;
        sorted.reserve(m.grid.chunks().size());
        for (const auto& [coord, chunk] : m.grid.chunks()) {
            if (chunk->filled_count > 0) sorted.push_back(chunk.get());
        }
        std::sort(sorted.begin(), sorted.end(),
                  [](const VoxelGrid::Chunk* a, const VoxelGrid::Chunk* b) {
                      return std::tie(a->coord.z, a->coord.y, a->coord.x) <
                             std::tie(b->coord.z, b->coord.y, b->coord.x);
                  });
        constexpr int32_t cs = static_cast<int32_t>(VoxelGrid::kChunkSize);
        for (const VoxelGrid::Chunk* chunk : sorted) {
            for (int32_t lz = 0; lz < cs; ++lz)
            for (int32_t ly = 0; ly < cs; ++ly)
            for (int32_t lx = 0; lx < cs; ++lx) {
                const uint8_t v =
                    chunk->cells[VoxelGrid::LocalIndex(lx, ly, lz)];
                if (v == 0) continue;
                xyzi.push_back(
                    static_cast<uint8_t>(chunk->coord.x * cs + lx));
                xyzi.push_back(
                    static_cast<uint8_t>(chunk->coord.y * cs + ly));
                xyzi.push_back(
                    static_cast<uint8_t>(chunk->coord.z * cs + lz));
                xyzi.push_back(v);
            }
        }
        AppendChunk(&children, "XYZI", xyzi);
    }

    if (wrap_root) {
        std::vector<uint8_t> body;
        AppendI32(&body, 0);
        AppendDict(&body, AttrDict{});
        AppendI32(&body, node_new.at(scene.root_id));
        AppendI32(&body, -1);  // reserved
        AppendI32(&body, -1);  // layer
        AppendI32(&body, 1);   // frames
        AppendDict(&body, AttrDict{});
        AppendChunk(&children, "nTRN", body);
    }

    for (int32_t old_id : emit_order) {
        const SceneNode& n = scene.nodes.at(old_id);
        std::vector<uint8_t> body;
        AppendI32(&body, node_new.at(old_id));
        AppendDict(&body, n.attrs);
        switch (n.kind) {
            case SceneNode::Kind::Transform: {
                auto child_it = node_new.find(n.child);
                if (child_it == node_new.end()) {
                    SetError(out_error, "transform node has a dangling child");
                    return false;
                }
                AppendI32(&body, child_it->second);
                AppendI32(&body, -1);  // reserved
                AppendI32(&body, n.layer_id);
                // Frame 0 re-encodes the live t/rot (other keys, e.g. _f,
                // ride along); extra animation frames pass through verbatim.
                std::vector<AttrDict> frames = n.frames;
                if (frames.empty()) frames.emplace_back();
                AttrDict& f0 = frames[0];
                if (n.t == Vec3i32{}) {
                    f0.erase("_t");
                } else {
                    char buf[48];
                    std::snprintf(buf, sizeof(buf), "%d %d %d", n.t.x, n.t.y,
                                  n.t.z);
                    f0["_t"] = buf;
                }
                if (RotMat::FromByte(n.rot).IsIdentity()) {
                    f0.erase("_r");
                } else {
                    f0["_r"] = std::to_string(static_cast<int>(n.rot));
                }
                AppendI32(&body, static_cast<int32_t>(frames.size()));
                for (const AttrDict& f : frames) AppendDict(&body, f);
                AppendChunk(&children, "nTRN", body);
                break;
            }
            case SceneNode::Kind::Group: {
                std::vector<int32_t> kids;
                for (int32_t c : n.children) {
                    auto cit = node_new.find(c);
                    if (cit != node_new.end()) kids.push_back(cit->second);
                }
                AppendI32(&body, static_cast<int32_t>(kids.size()));
                for (int32_t k : kids) AppendI32(&body, k);
                AppendChunk(&children, "nGRP", body);
                break;
            }
            case SceneNode::Kind::Shape: {
                std::vector<std::pair<int32_t, const AttrDict*>> ms;
                for (const auto& [mid, attrs] : n.models) {
                    auto mit = model_new.find(mid);
                    if (mit != model_new.end()) {
                        ms.emplace_back(mit->second, &attrs);
                    }
                }
                if (ms.empty()) {
                    SetError(out_error, "shape node references no models");
                    return false;
                }
                AppendI32(&body, static_cast<int32_t>(ms.size()));
                for (const auto& [mid, attrs] : ms) {
                    AppendI32(&body, mid);
                    AppendDict(&body, *attrs);
                }
                AppendChunk(&children, "nSHP", body);
                break;
            }
        }
    }

    for (const SceneLayer& layer : scene.layers) {
        std::vector<uint8_t> body;
        AppendI32(&body, layer.id);
        AppendDict(&body, layer.attrs);
        AppendI32(&body, -1);  // reserved
        AppendChunk(&children, "LAYR", body);
    }

    // Magica emits color/material chunks after the node graph; match it.
    AppendRgbaChunk(&children, palette);
    AppendMatlChunks(&children, palette);
    return WriteVoxFile(path, children, out_error);
}

}  // namespace macvoxel
