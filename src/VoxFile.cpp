#include "VoxFile.h"

#include "Palette.h"
#include "VoxelGrid.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace macvoxel {
namespace {

constexpr uint32_t kVoxVersion = 150;

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
    bool ReadId(char id[4]) { return Read(id, 4); }
    bool Skip(size_t n) {
        if (n > remaining()) return false;
        pos_ += n;
        return true;
    }
    const uint8_t* PeekPtr() const { return buf_ + pos_; }

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
    // MAIN has no content of its own; everything is in its children.
    if (!r.Skip(main_content)) {
        SetError(out_error, "truncated MAIN content");
        return false;
    }

    Reader children(r.PeekPtr(), main_children);

    Dims dims{};
    bool size_seen = false;
    bool xyzi_seen = false;
    int model_index = 0;

    VoxelGrid grid;
    Palette palette;  // default-initialized to MagicaVoxel default
    bool rgba_seen = false;

    while (!children.Eof()) {
        char id[4];
        uint32_t content_size = 0, child_size = 0;
        if (!children.ReadId(id) || !children.ReadU32(&content_size) ||
            !children.ReadU32(&child_size)) {
            SetError(out_error, "truncated chunk header");
            return false;
        }
        const size_t after = children.pos() + content_size + child_size;
        if (after > main_children) {
            SetError(out_error, "chunk extends past MAIN");
            return false;
        }
        const uint8_t* content_ptr = children.PeekPtr();

        if (ChunkIdEquals(id, "PACK")) {
            // Optional model count. We honor only the first model regardless.
            (void)content_ptr;
        } else if (ChunkIdEquals(id, "SIZE")) {
            if (model_index == 0) {
                if (content_size != 12) {
                    SetError(out_error, "SIZE chunk has wrong content size");
                    return false;
                }
                Reader cr(content_ptr, content_size);
                cr.ReadU32(&dims.x);
                cr.ReadU32(&dims.y);
                cr.ReadU32(&dims.z);
                size_seen = true;
            }
        } else if (ChunkIdEquals(id, "XYZI")) {
            if (model_index == 0) {
                if (!size_seen) {
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
                grid.Resize(dims);
                const uint8_t* vox = cr.PeekPtr();
                for (uint32_t i = 0; i < n; ++i) {
                    const uint8_t vx = vox[i * 4 + 0];
                    const uint8_t vy = vox[i * 4 + 1];
                    const uint8_t vz = vox[i * 4 + 2];
                    const uint8_t ci = vox[i * 4 + 3];
                    grid.Set(vx, vy, vz, ci);
                }
                xyzi_seen = true;
                ++model_index;  // committed model 0; further SIZE/XYZI ignored
            }
        } else if (ChunkIdEquals(id, "RGBA")) {
            if (content_size < 1024) {
                SetError(out_error, "RGBA chunk shorter than 1024 bytes");
                return false;
            }
            // Per spec: file rgba[0..254] map to palette[1..255]; the last
            // entry is unused.
            for (size_t i = 0; i < 255; ++i) {
                Color c;
                c.r = content_ptr[i * 4 + 0];
                c.g = content_ptr[i * 4 + 1];
                c.b = content_ptr[i * 4 + 2];
                c.a = content_ptr[i * 4 + 3];
                palette.Set(static_cast<uint8_t>(i + 1), c);
            }
            // Index 0 stays as the empty/transparent slot.
            palette.Set(0, Color{0, 0, 0, 0});
            rgba_seen = true;
        } else if (ChunkIdEquals(id, "nTRN") || ChunkIdEquals(id, "nGRP") ||
                   ChunkIdEquals(id, "nSHP") || ChunkIdEquals(id, "MATL") ||
                   ChunkIdEquals(id, "LAYR") || ChunkIdEquals(id, "rOBJ") ||
                   ChunkIdEquals(id, "rCAM") || ChunkIdEquals(id, "NOTE") ||
                   ChunkIdEquals(id, "IMAP") || ChunkIdEquals(id, "MATT")) {
            // Recognised but ignored in Phase 2 — single-model loader.
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

    if (!size_seen || !xyzi_seen) {
        SetError(out_error, "file has no model (missing SIZE or XYZI)");
        return false;
    }

    if (!rgba_seen) {
        palette.ResetToDefault();
    }

    *out_grid = std::move(grid);
    *out_palette = palette;
    (void)version;  // accepted regardless; format is stable across 150/200
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

    // Collect filled voxels first so we know XYZI's content size.
    std::vector<uint8_t> xyzi_voxels;
    xyzi_voxels.reserve(grid.size());
    const Dims d = grid.dims();
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
    if (d.x > 256 || d.y > 256 || d.z > 256) {
        SetError(out_error, "dimensions exceed .vox limit of 256 per axis");
        return false;
    }
    const uint32_t num_voxels = static_cast<uint32_t>(xyzi_voxels.size() / 4);

    // Build children buffer.
    std::vector<uint8_t> children;

    // SIZE chunk.
    AppendId(&children, "SIZE");
    AppendU32(&children, 12);
    AppendU32(&children, 0);
    AppendU32(&children, d.x);
    AppendU32(&children, d.y);
    AppendU32(&children, d.z);

    // XYZI chunk.
    AppendId(&children, "XYZI");
    AppendU32(&children, 4 + 4 * num_voxels);
    AppendU32(&children, 0);
    AppendU32(&children, num_voxels);
    children.insert(children.end(), xyzi_voxels.begin(), xyzi_voxels.end());

    // RGBA chunk: 256 RGBA quads. Per spec, palette[i+1] is written at
    // offset i, and the last 4 bytes are filler.
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
    // Filler entry (spec says unused).
    children.push_back(0);
    children.push_back(0);
    children.push_back(0);
    children.push_back(0);

    // Compose full file.
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
