#include "VoxFile.h"

#include "Palette.h"
#include "VoxelGrid.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <vector>

namespace macvoxel {
namespace {

constexpr uint32_t kVoxVersion = 150;
constexpr uint32_t kMergedAxisCap = 1024;  // refuse pathological scenes

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

    // .vox STRING: int32 byte_count, then bytes.
    bool ReadString(std::string* out) {
        int32_t n = 0;
        if (!ReadI32(&n) || n < 0) return false;
        if (static_cast<size_t>(n) > remaining()) return false;
        out->assign(reinterpret_cast<const char*>(buf_ + pos_), static_cast<size_t>(n));
        pos_ += static_cast<size_t>(n);
        return true;
    }

    // .vox DICT: int32 num_pairs, then pairs of (STRING key, STRING value).
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

// ---------------------------------------------------------------------------
// Rotation byte decoding
//
// Bits 0-1 : column index of the nonzero in row 0
// Bits 2-3 : column index of the nonzero in row 1
// Row 2's column is the remaining one (it's a permutation matrix with signs).
// Bits 4,5,6 : signs of rows 0, 1, 2 (1 = negative)
// ---------------------------------------------------------------------------

struct Mat3i {
    int m[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};  // identity
};

constexpr Mat3i kIdentity{};

Mat3i DecodeRotation(uint8_t rot) {
    const int c0 = rot & 0x3;
    const int c1 = (rot >> 2) & 0x3;
    const int c2 = 3 - c0 - c1;
    if (c0 == c1 || c2 < 0 || c2 > 2) {
        return kIdentity;  // malformed; fall back
    }
    const int s0 = (rot & (1 << 4)) ? -1 : 1;
    const int s1 = (rot & (1 << 5)) ? -1 : 1;
    const int s2 = (rot & (1 << 6)) ? -1 : 1;
    Mat3i out{};
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) out.m[i][j] = 0;
    out.m[0][c0] = s0;
    out.m[1][c1] = s1;
    out.m[2][c2] = s2;
    return out;
}

Mat3i Mul(const Mat3i& a, const Mat3i& b) {
    Mat3i out{};
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            int v = 0;
            for (int k = 0; k < 3; ++k) v += a.m[i][k] * b.m[k][j];
            out.m[i][j] = v;
        }
    }
    return out;
}

struct Vec3i { int x = 0, y = 0, z = 0; };

Vec3i Apply(const Mat3i& m, Vec3i v) {
    Vec3i out;
    out.x = m.m[0][0] * v.x + m.m[0][1] * v.y + m.m[0][2] * v.z;
    out.y = m.m[1][0] * v.x + m.m[1][1] * v.y + m.m[1][2] * v.z;
    out.z = m.m[2][0] * v.x + m.m[2][1] * v.y + m.m[2][2] * v.z;
    return out;
}

bool ParseTranslation(const std::string& s, Vec3i* out) {
    return std::sscanf(s.c_str(), "%d %d %d", &out->x, &out->y, &out->z) == 3;
}

// ---------------------------------------------------------------------------
// Intermediate parse structures
// ---------------------------------------------------------------------------

struct ParsedModel {
    Dims dims{};
    std::vector<uint8_t> voxels;  // 4 bytes per voxel: x, y, z, color
};

enum class NodeKind { Transform, Group, Shape };

struct ParsedNode {
    NodeKind kind = NodeKind::Transform;
    int32_t id = -1;
    // Transform:
    int32_t child = -1;
    Vec3i translation{};
    uint8_t rotation = 4;  // identity
    // Group:
    std::vector<int32_t> children;
    // Shape:
    std::vector<int32_t> model_ids;
};

struct PlacedShape {
    int32_t model_id = 0;
    Vec3i translation{};
    Mat3i rotation = kIdentity;
};

bool ParseTransformNode(Reader& r, ParsedNode* node) {
    node->kind = NodeKind::Transform;
    if (!r.ReadI32(&node->id)) return false;
    std::map<std::string, std::string> attrs;
    if (!r.ReadDict(&attrs)) return false;
    if (!r.ReadI32(&node->child)) return false;
    int32_t reserved = 0, layer = 0, num_frames = 0;
    if (!r.ReadI32(&reserved) || !r.ReadI32(&layer) || !r.ReadI32(&num_frames)) return false;
    for (int32_t i = 0; i < num_frames; ++i) {
        std::map<std::string, std::string> frame;
        if (!r.ReadDict(&frame)) return false;
        if (i == 0) {
            auto it = frame.find("_t");
            if (it != frame.end()) ParseTranslation(it->second, &node->translation);
            it = frame.find("_r");
            if (it != frame.end()) {
                node->rotation = static_cast<uint8_t>(std::strtol(it->second.c_str(),
                                                                  nullptr, 10));
            }
        }
    }
    return true;
}

bool ParseGroupNode(Reader& r, ParsedNode* node) {
    node->kind = NodeKind::Group;
    if (!r.ReadI32(&node->id)) return false;
    std::map<std::string, std::string> attrs;
    if (!r.ReadDict(&attrs)) return false;
    int32_t n = 0;
    if (!r.ReadI32(&n) || n < 0) return false;
    node->children.resize(static_cast<size_t>(n));
    for (int32_t i = 0; i < n; ++i) {
        if (!r.ReadI32(&node->children[static_cast<size_t>(i)])) return false;
    }
    return true;
}

bool ParseShapeNode(Reader& r, ParsedNode* node) {
    node->kind = NodeKind::Shape;
    if (!r.ReadI32(&node->id)) return false;
    std::map<std::string, std::string> attrs;
    if (!r.ReadDict(&attrs)) return false;
    int32_t num_models = 0;
    if (!r.ReadI32(&num_models) || num_models < 0) return false;
    for (int32_t i = 0; i < num_models; ++i) {
        int32_t model_id = 0;
        std::map<std::string, std::string> model_attrs;
        if (!r.ReadI32(&model_id) || !r.ReadDict(&model_attrs)) return false;
        node->model_ids.push_back(model_id);
    }
    return true;
}

// ---------------------------------------------------------------------------
// Scene graph walk
// ---------------------------------------------------------------------------

void WalkNode(const std::map<int32_t, ParsedNode>& nodes,
              int32_t node_id,
              const Vec3i& accum_t,
              const Mat3i& accum_r,
              std::vector<PlacedShape>* out) {
    auto it = nodes.find(node_id);
    if (it == nodes.end()) return;
    const ParsedNode& n = it->second;
    switch (n.kind) {
        case NodeKind::Transform: {
            // Apply parent rotation to this node's translation, then add.
            const Vec3i rt = Apply(accum_r, n.translation);
            Vec3i t = accum_t;
            t.x += rt.x;
            t.y += rt.y;
            t.z += rt.z;
            const Mat3i r = Mul(accum_r, DecodeRotation(n.rotation));
            WalkNode(nodes, n.child, t, r, out);
            break;
        }
        case NodeKind::Group: {
            for (int32_t c : n.children) WalkNode(nodes, c, accum_t, accum_r, out);
            break;
        }
        case NodeKind::Shape: {
            for (int32_t mid : n.model_ids) {
                PlacedShape ps;
                ps.model_id = mid;
                ps.translation = accum_t;
                ps.rotation = accum_r;
                out->push_back(ps);
            }
            break;
        }
    }
}

}  // namespace

// ---------------------------------------------------------------------------
// Load
// ---------------------------------------------------------------------------

bool LoadVox(const std::string& path,
             VoxelGrid* out_grid,
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
    Dims pending_size{};
    bool have_pending_size = false;
    Palette palette;
    bool rgba_seen = false;

    std::map<int32_t, ParsedNode> nodes;

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
            Dims d{};
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
            ParsedNode n;
            if (ParseTransformNode(cr, &n)) nodes[n.id] = std::move(n);
        } else if (ChunkIdEquals(id, "nGRP")) {
            Reader cr(content_ptr, content_size);
            ParsedNode n;
            if (ParseGroupNode(cr, &n)) nodes[n.id] = std::move(n);
        } else if (ChunkIdEquals(id, "nSHP")) {
            Reader cr(content_ptr, content_size);
            ParsedNode n;
            if (ParseShapeNode(cr, &n)) nodes[n.id] = std::move(n);
        } else if (ChunkIdEquals(id, "PACK") || ChunkIdEquals(id, "MATL") ||
                   ChunkIdEquals(id, "LAYR") || ChunkIdEquals(id, "rOBJ") ||
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

    // ----- Determine placements -----
    std::vector<PlacedShape> placements;
    if (!nodes.empty()) {
        // Walk from node 0 (the convention). Some files don't place node 0
        // first by ID — fall back to lowest-numbered node otherwise.
        int32_t root = nodes.count(0) ? 0 : nodes.begin()->first;
        WalkNode(nodes, root, Vec3i{}, kIdentity, &placements);
    }
    if (placements.empty()) {
        // No scene graph (or empty walk): place model 0 corner-at-origin.
        PlacedShape ps;
        ps.model_id = 0;
        // For corner-at-origin, translation cancels the model-center pivot
        // applied during rasterization below.
        const Dims d0 = models[0].dims;
        ps.translation = Vec3i{static_cast<int>(d0.x / 2),
                               static_cast<int>(d0.y / 2),
                               static_cast<int>(d0.z / 2)};
        placements.push_back(ps);
    }

    // ----- Compute union AABB in world voxel coords -----
    int min_x = INT_MAX, min_y = INT_MAX, min_z = INT_MAX;
    int max_x = INT_MIN, max_y = INT_MIN, max_z = INT_MIN;
    for (const PlacedShape& ps : placements) {
        if (ps.model_id < 0 || static_cast<size_t>(ps.model_id) >= models.size()) continue;
        const Dims md = models[static_cast<size_t>(ps.model_id)].dims;
        // Local model corners (centered): -dims/2 .. -dims/2 + dims
        const int hx = static_cast<int>(md.x) / 2;
        const int hy = static_cast<int>(md.y) / 2;
        const int hz = static_cast<int>(md.z) / 2;
        // Eight corners of the local AABB (centered).
        const int corners[8][3] = {
            {-hx, -hy, -hz},
            {static_cast<int>(md.x) - hx, -hy, -hz},
            {-hx, static_cast<int>(md.y) - hy, -hz},
            {static_cast<int>(md.x) - hx, static_cast<int>(md.y) - hy, -hz},
            {-hx, -hy, static_cast<int>(md.z) - hz},
            {static_cast<int>(md.x) - hx, -hy, static_cast<int>(md.z) - hz},
            {-hx, static_cast<int>(md.y) - hy, static_cast<int>(md.z) - hz},
            {static_cast<int>(md.x) - hx, static_cast<int>(md.y) - hy,
             static_cast<int>(md.z) - hz},
        };
        for (auto& c : corners) {
            const Vec3i rotated = Apply(ps.rotation, Vec3i{c[0], c[1], c[2]});
            const int wx = rotated.x + ps.translation.x;
            const int wy = rotated.y + ps.translation.y;
            const int wz = rotated.z + ps.translation.z;
            min_x = std::min(min_x, wx);
            min_y = std::min(min_y, wy);
            min_z = std::min(min_z, wz);
            max_x = std::max(max_x, wx);
            max_y = std::max(max_y, wy);
            max_z = std::max(max_z, wz);
        }
    }

    if (min_x == INT_MAX) {
        SetError(out_error, "no shape placements produced any geometry");
        return false;
    }

    const int64_t span_x = static_cast<int64_t>(max_x) - min_x;
    const int64_t span_y = static_cast<int64_t>(max_y) - min_y;
    const int64_t span_z = static_cast<int64_t>(max_z) - min_z;
    if (span_x > kMergedAxisCap || span_y > kMergedAxisCap || span_z > kMergedAxisCap) {
        char buf[160];
        std::snprintf(buf, sizeof(buf),
                      "merged scene exceeds %u^3 cell cap (would be %lldx%lldx%lld)",
                      kMergedAxisCap, (long long)span_x, (long long)span_y, (long long)span_z);
        SetError(out_error, buf);
        return false;
    }

    Dims merged_dims;
    merged_dims.x = static_cast<uint32_t>(span_x);
    merged_dims.y = static_cast<uint32_t>(span_y);
    merged_dims.z = static_cast<uint32_t>(span_z);
    if (merged_dims.x == 0 || merged_dims.y == 0 || merged_dims.z == 0) {
        SetError(out_error, "merged scene is zero-volume");
        return false;
    }

    VoxelGrid grid(merged_dims);

    // ----- Rasterize all placements -----
    for (const PlacedShape& ps : placements) {
        if (ps.model_id < 0 || static_cast<size_t>(ps.model_id) >= models.size()) continue;
        const ParsedModel& m = models[static_cast<size_t>(ps.model_id)];
        const int hx = static_cast<int>(m.dims.x) / 2;
        const int hy = static_cast<int>(m.dims.y) / 2;
        const int hz = static_cast<int>(m.dims.z) / 2;
        const size_t voxel_count = m.voxels.size() / 4;
        for (size_t i = 0; i < voxel_count; ++i) {
            const int lx = static_cast<int>(m.voxels[i * 4 + 0]) - hx;
            const int ly = static_cast<int>(m.voxels[i * 4 + 1]) - hy;
            const int lz = static_cast<int>(m.voxels[i * 4 + 2]) - hz;
            const uint8_t ci = m.voxels[i * 4 + 3];

            const Vec3i rotated = Apply(ps.rotation, Vec3i{lx, ly, lz});
            const int wx = rotated.x + ps.translation.x - min_x;
            const int wy = rotated.y + ps.translation.y - min_y;
            const int wz = rotated.z + ps.translation.z - min_z;
            if (wx < 0 || wy < 0 || wz < 0) continue;
            grid.Set(static_cast<uint32_t>(wx),
                     static_cast<uint32_t>(wy),
                     static_cast<uint32_t>(wz), ci);
        }
    }

    if (!rgba_seen) {
        palette.ResetToDefault();
    }

    *out_grid = std::move(grid);
    *out_palette = palette;
    (void)version;
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

}  // namespace

bool SaveVox(const std::string& path,
             const VoxelGrid& grid,
             const Palette& palette,
             std::string* out_error) {
    if (grid.dims().empty()) {
        SetError(out_error, "cannot save an empty grid");
        return false;
    }

    const Dims d = grid.dims();
    if (d.x > 256 || d.y > 256 || d.z > 256) {
        SetError(out_error, "dimensions exceed .vox single-model limit of 256 per axis");
        return false;
    }

    std::vector<uint8_t> xyzi_voxels;
    xyzi_voxels.reserve(grid.size());
    for (uint32_t z = 0; z < d.z; ++z) {
        for (uint32_t y = 0; y < d.y; ++y) {
            for (uint32_t x = 0; x < d.x; ++x) {
                const uint8_t v = grid.Get(x, y, z);
                if (v != 0) {
                    xyzi_voxels.push_back(static_cast<uint8_t>(x));
                    xyzi_voxels.push_back(static_cast<uint8_t>(y));
                    xyzi_voxels.push_back(static_cast<uint8_t>(z));
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
    AppendU32(&children, d.x);
    AppendU32(&children, d.y);
    AppendU32(&children, d.z);

    AppendId(&children, "XYZI");
    AppendU32(&children, 4 + 4 * num_voxels);
    AppendU32(&children, 0);
    AppendU32(&children, num_voxels);
    children.insert(children.end(), xyzi_voxels.begin(), xyzi_voxels.end());

    AppendId(&children, "RGBA");
    AppendU32(&children, 1024);
    AppendU32(&children, 0);
    for (size_t i = 0; i < 255; ++i) {
        const Color c = palette.Get(static_cast<uint8_t>(i + 1));
        children.push_back(c.r);
        children.push_back(c.g);
        children.push_back(c.b);
        children.push_back(c.a);
    }
    children.push_back(0);
    children.push_back(0);
    children.push_back(0);
    children.push_back(0);

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

}  // namespace macvoxel
