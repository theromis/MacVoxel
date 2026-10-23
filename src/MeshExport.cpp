#include "MeshExport.h"

#include "Document.h"
#include "Palette.h"
#include "VoxFile.h"
#include "VoxScene.h"
#include "VoxelGrid.h"

#include <algorithm>
#include <bit>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <map>
#include <new>
#include <string>
#include <utility>
#include <vector>

static_assert(std::endian::native == std::endian::little, "glTF floats are written in host order");

namespace macvoxel {
namespace {

// A few hundred thousand quads is the expected working set. Past this we
// refuse instead of allocating a multi-gigabyte glTF.
constexpr size_t kMaxQuads = 2000000;

// Integer voxel corners must stay exact in float32 (exact up to 2^24).
// The editor world is [-1024, 1024); this is only a safety rail.
constexpr int32_t kCoordLimit = 1 << 20;

constexpr int kArrayBuffer = 34962;
constexpr int kElementArrayBuffer = 34963;

// Face order: -X +X -Y +Y -Z +Z. Corners are CCW when viewed from outside
// the voxel, in grid space (Z-up, X cross Y = Z). A voxel occupies
// [x, x+1] × [y, y+1] × [z, z+1].
constexpr int kDelta[6][3] = {
    {-1, 0, 0}, {1, 0, 0}, {0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1},
};
constexpr int kNormal[6][3] = {
    {-1, 0, 0}, {1, 0, 0}, {0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1},
};
constexpr int kCorner[6][4][3] = {
    {{0, 0, 0}, {0, 0, 1}, {0, 1, 1}, {0, 1, 0}}, {{1, 0, 0}, {1, 1, 0}, {1, 1, 1}, {1, 0, 1}},
    {{0, 0, 0}, {1, 0, 0}, {1, 0, 1}, {0, 0, 1}}, {{0, 1, 0}, {0, 1, 1}, {1, 1, 1}, {1, 1, 0}},
    {{0, 0, 0}, {0, 1, 0}, {1, 1, 0}, {1, 0, 0}}, {{0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}},
};
// u = corner1 - corner0, v = corner3 - corner0. Both are +1 along one axis,
// so a w×h quad extends along the same winding as a unit face.
constexpr int kTangentU[6][3] = {
    {0, 0, 1}, {0, 1, 0}, {1, 0, 0}, {0, 0, 1}, {0, 1, 0}, {1, 0, 0},
};
constexpr int kTangentV[6][3] = {
    {0, 1, 0}, {0, 0, 1}, {0, 0, 1}, {1, 0, 0}, {1, 0, 0}, {0, 1, 0},
};

struct Quad {
    int32_t x = 0;
    int32_t y = 0;
    int32_t z = 0;
    uint8_t face = 0;
    uint8_t palette = 0;
    int32_t w = 1;
    int32_t h = 1;
};

struct Section {
    size_t offset = 0;
    size_t length = 0;
};

struct Vec3 {
    float x = 0;
    float y = 0;
    float z = 0;
};

bool Fail(std::string* error, const std::string& message) {
    if (error != nullptr)
        *error = message;
    return false;
}

// Voxel grid is Z-up (x/y horizontal, floor at z = 0). glTF is Y-up.
// Blender's importer maps glTF (x, y, z) to Blender (x, -z, y), so writing
// (gx, gz, -gy) lands on Blender (gx, gy, gz): voxel +Z is Blender +Z.
// Same rotation as the renderer ("Grid → world is (gx, gz, -gy)").
// det = +1, so grid-space CCW winding stays front-facing.
Vec3 GridToGltf(float gx, float gy, float gz) {
    auto canon = [](float v) { return v == 0.0f ? 0.0f : v; };
    return Vec3{canon(gx), canon(gz), canon(-gy)};
}

bool FaceTablesOk() {
    for (int f = 0; f < 6; ++f) {
        for (int a = 0; a < 3; ++a) {
            if (kDelta[f][a] != kNormal[f][a])
                return false;
        }
        const int* p = kCorner[f][0];
        const int* q = kCorner[f][1];
        const int* r = kCorner[f][2];
        const int e1x = q[0] - p[0];
        const int e1y = q[1] - p[1];
        const int e1z = q[2] - p[2];
        const int e2x = r[0] - p[0];
        const int e2y = r[1] - p[1];
        const int e2z = r[2] - p[2];
        const int nx = e1y * e2z - e1z * e2y;
        const int ny = e1z * e2x - e1x * e2z;
        const int nz = e1x * e2y - e1y * e2x;
        if (nx != kNormal[f][0] || ny != kNormal[f][1] || nz != kNormal[f][2])
            return false;
        for (int c = 0; c < 4; ++c) {
            const int su = (c == 1 || c == 2) ? 1 : 0;
            const int sv = (c == 2 || c == 3) ? 1 : 0;
            for (int a = 0; a < 3; ++a) {
                const int got = kCorner[f][0][a] + kTangentU[f][a] * su + kTangentV[f][a] * sv;
                if (got != kCorner[f][c][a])
                    return false;
            }
        }
    }
    return true;
}

bool NeighborSolid(const VoxelGrid& grid, int32_t x, int32_t y, int32_t z, int face) {
    const int64_t nx = static_cast<int64_t>(x) + kDelta[face][0];
    const int64_t ny = static_cast<int64_t>(y) + kDelta[face][1];
    const int64_t nz = static_cast<int64_t>(z) + kDelta[face][2];
    if (nx < std::numeric_limits<int32_t>::min() || nx > std::numeric_limits<int32_t>::max() ||
        ny < std::numeric_limits<int32_t>::min() || ny > std::numeric_limits<int32_t>::max() ||
        nz < std::numeric_limits<int32_t>::min() || nz > std::numeric_limits<int32_t>::max()) {
        return false;
    }
    return grid.Get(static_cast<int32_t>(nx), static_cast<int32_t>(ny), static_cast<int32_t>(nz)) !=
           0;
}

// Uncompressed PNG (deflate stored blocks). Enough for a 256×1 palette
// and avoids a new dependency. Scanlines are filter None.
uint32_t Crc32(const uint8_t* data, size_t n) {
    uint32_t c = 0xffffffffu;
    for (size_t i = 0; i < n; ++i) {
        c ^= data[i];
        for (int bit = 0; bit < 8; ++bit) {
            const uint32_t mix = (c & 1u) != 0u ? 0xedb88320u : 0u;
            c = (c >> 1) ^ mix;
        }
    }
    return ~c;
}

uint32_t Adler32(const uint8_t* data, size_t n) {
    uint32_t a = 1;
    uint32_t b = 0;
    for (size_t i = 0; i < n; ++i) {
        a = (a + data[i]) % 65521u;
        b = (b + a) % 65521u;
    }
    return (b << 16) | a;
}

void AppendBE32(std::vector<uint8_t>* out, uint32_t v) {
    out->push_back(static_cast<uint8_t>((v >> 24) & 0xffu));
    out->push_back(static_cast<uint8_t>((v >> 16) & 0xffu));
    out->push_back(static_cast<uint8_t>((v >> 8) & 0xffu));
    out->push_back(static_cast<uint8_t>(v & 0xffu));
}

void AppendLE32(std::vector<uint8_t>* out, uint32_t v) {
    out->push_back(static_cast<uint8_t>(v & 0xffu));
    out->push_back(static_cast<uint8_t>((v >> 8) & 0xffu));
    out->push_back(static_cast<uint8_t>((v >> 16) & 0xffu));
    out->push_back(static_cast<uint8_t>((v >> 24) & 0xffu));
}

void AppendFloat(std::vector<uint8_t>* out, float v) {
    static_assert(sizeof(float) == 4, "float must be 32-bit");
    uint32_t u = 0;
    std::memcpy(&u, &v, 4);
    AppendLE32(out, u);
}

void PngChunk(std::vector<uint8_t>* png, const char* type, const uint8_t* data, size_t n) {
    AppendBE32(png, static_cast<uint32_t>(n));
    const size_t start = png->size();
    png->insert(png->end(), type, type + 4);
    if (n != 0)
        png->insert(png->end(), data, data + n);
    AppendBE32(png, Crc32(png->data() + start, 4 + n));
}

std::vector<uint8_t> EncodePngRgba(const uint8_t* rgba, uint32_t width, uint32_t height) {
    std::vector<uint8_t> raw;
    const size_t stride = 1u + static_cast<size_t>(width) * 4u;
    raw.reserve(static_cast<size_t>(height) * stride);
    for (uint32_t y = 0; y < height; ++y) {
        raw.push_back(0);
        const uint8_t* row = rgba + static_cast<size_t>(y) * width * 4u;
        raw.insert(raw.end(), row, row + static_cast<size_t>(width) * 4u);
    }

    std::vector<uint8_t> zlib;
    zlib.reserve(raw.size() + 16);
    zlib.push_back(0x78);
    zlib.push_back(0x01);
    size_t off = 0;
    while (off < raw.size()) {
        const size_t take = std::min(raw.size() - off, static_cast<size_t>(65535));
        const bool last = off + take == raw.size();
        zlib.push_back(last ? 0x01 : 0x00);
        const auto len = static_cast<uint16_t>(take);
        zlib.push_back(static_cast<uint8_t>(len & 0xffu));
        zlib.push_back(static_cast<uint8_t>((len >> 8) & 0xffu));
        const auto nlen = static_cast<uint16_t>(~len);
        zlib.push_back(static_cast<uint8_t>(nlen & 0xffu));
        zlib.push_back(static_cast<uint8_t>((nlen >> 8) & 0xffu));
        zlib.insert(zlib.end(), raw.begin() + static_cast<std::ptrdiff_t>(off),
                    raw.begin() + static_cast<std::ptrdiff_t>(off + take));
        off += take;
    }
    AppendBE32(&zlib, Adler32(raw.data(), raw.size()));

    uint8_t ihdr[13];
    ihdr[0] = static_cast<uint8_t>((width >> 24) & 0xffu);
    ihdr[1] = static_cast<uint8_t>((width >> 16) & 0xffu);
    ihdr[2] = static_cast<uint8_t>((width >> 8) & 0xffu);
    ihdr[3] = static_cast<uint8_t>(width & 0xffu);
    ihdr[4] = static_cast<uint8_t>((height >> 24) & 0xffu);
    ihdr[5] = static_cast<uint8_t>((height >> 16) & 0xffu);
    ihdr[6] = static_cast<uint8_t>((height >> 8) & 0xffu);
    ihdr[7] = static_cast<uint8_t>(height & 0xffu);
    ihdr[8] = 8;
    ihdr[9] = 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;

    std::vector<uint8_t> png;
    const uint8_t sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
    png.insert(png.end(), sig, sig + 8);
    PngChunk(&png, "IHDR", ihdr, sizeof(ihdr));
    const uint8_t srgb = 0;
    PngChunk(&png, "sRGB", &srgb, 1);
    PngChunk(&png, "IDAT", zlib.data(), zlib.size());
    PngChunk(&png, "IEND", nullptr, 0);
    return png;
}

void AppendJsonFloat(std::string* json, float v) {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.9g", static_cast<double>(v));
    json->append(buf);
}

void AppendBufferView(std::string* json, bool* first, size_t offset, size_t length, int target) {
    if (!*first)
        json->push_back(',');
    *first = false;
    json->append("{\"buffer\":0,\"byteOffset\":");
    json->append(std::to_string(offset));
    json->append(",\"byteLength\":");
    json->append(std::to_string(length));
    if (target != 0) {
        json->append(",\"target\":");
        json->append(std::to_string(target));
    }
    json->push_back('}');
}

std::string BuildJson(MeshColorMode mode, bool blend, size_t buffer_bytes, const Section& pos,
                      const Section& nrm, const Section& color, const Section& indices,
                      const Section& image, size_t vertex_count, size_t index_count, Vec3 pmin,
                      Vec3 pmax) {
    const bool vertex_colors = mode == MeshColorMode::VertexColors;
    std::string j;
    j.reserve(1536);
    j += "{\"asset\":{\"version\":\"2.0\",\"generator\":\"MacVoxel\"},";
    j += "\"scene\":0,\"scenes\":[{\"nodes\":[0]}],";
    j += "\"nodes\":[{\"name\":\"voxels\",\"mesh\":0}],";
    j += "\"meshes\":[{\"name\":\"voxels\",\"primitives\":[{";
    j += "\"attributes\":{\"POSITION\":0,\"NORMAL\":1,";
    j += vertex_colors ? "\"COLOR_0\":2" : "\"TEXCOORD_0\":2";
    j += "},\"indices\":3,\"material\":0,\"mode\":4}]}],";
    j += "\"materials\":[{\"name\":\"";
    j += vertex_colors ? "voxel-vertex-color" : "voxel-palette";
    j += "\",\"pbrMetallicRoughness\":{\"baseColorFactor\":[1,1,1,1],";
    if (!vertex_colors)
        j += "\"baseColorTexture\":{\"index\":0},";
    j += "\"metallicFactor\":0,\"roughnessFactor\":1},\"alphaMode\":\"";
    j += blend ? "BLEND" : "OPAQUE";
    j += "\"}]";
    if (!vertex_colors) {
        j += ",\"textures\":[{\"sampler\":0,\"source\":0}]";
        j += ",\"samplers\":[{\"magFilter\":9728,\"minFilter\":9728,"
             "\"wrapS\":33071,\"wrapT\":33071}]";
        j += ",\"images\":[{\"bufferView\":4,\"mimeType\":\"image/png\"}]";
    }
    j += ",\"buffers\":[{\"byteLength\":";
    j += std::to_string(buffer_bytes);
    j += "}],\"bufferViews\":[";
    bool first = true;
    AppendBufferView(&j, &first, pos.offset, pos.length, kArrayBuffer);
    AppendBufferView(&j, &first, nrm.offset, nrm.length, kArrayBuffer);
    AppendBufferView(&j, &first, color.offset, color.length, kArrayBuffer);
    AppendBufferView(&j, &first, indices.offset, indices.length, kElementArrayBuffer);
    if (!vertex_colors)
        AppendBufferView(&j, &first, image.offset, image.length, 0);
    j += "],\"accessors\":[";
    j += "{\"bufferView\":0,\"componentType\":5126,\"count\":";
    j += std::to_string(vertex_count);
    j += ",\"type\":\"VEC3\",\"min\":[";
    AppendJsonFloat(&j, pmin.x);
    j += ',';
    AppendJsonFloat(&j, pmin.y);
    j += ',';
    AppendJsonFloat(&j, pmin.z);
    j += "],\"max\":[";
    AppendJsonFloat(&j, pmax.x);
    j += ',';
    AppendJsonFloat(&j, pmax.y);
    j += ',';
    AppendJsonFloat(&j, pmax.z);
    j += "]},";
    j += "{\"bufferView\":1,\"componentType\":5126,\"count\":";
    j += std::to_string(vertex_count);
    j += ",\"type\":\"VEC3\"},";
    j += "{\"bufferView\":2,\"componentType\":";
    if (vertex_colors) {
        j += "5126,\"count\":";
        j += std::to_string(vertex_count);
        j += ",\"type\":\"VEC4\"},";
    } else {
        j += "5126,\"count\":";
        j += std::to_string(vertex_count);
        j += ",\"type\":\"VEC2\"},";
    }
    j += "{\"bufferView\":3,\"componentType\":5125,\"count\":";
    j += std::to_string(index_count);
    j += ",\"type\":\"SCALAR\"}]}";
    return j;
}

void Consider(Vec3* pmin, Vec3* pmax, Vec3 p) {
    if (p.x < pmin->x)
        pmin->x = p.x;
    if (p.y < pmin->y)
        pmin->y = p.y;
    if (p.z < pmin->z)
        pmin->z = p.z;
    if (p.x > pmax->x)
        pmax->x = p.x;
    if (p.y > pmax->y)
        pmax->y = p.y;
    if (p.z > pmax->z)
        pmax->z = p.z;
}

bool CollectQuads(const VoxelGrid& grid, std::vector<Quad>* quads, std::string* error) {
    constexpr int32_t cs = static_cast<int32_t>(VoxelGrid::kChunkSize);
    if (grid.FilledCount() < kMaxQuads)
        quads->reserve(std::min(grid.FilledCount() * 3, kMaxQuads));
    for (const auto& entry : grid.chunks()) {
        const VoxelGrid::Chunk& chunk = *entry.second;
        if (chunk.filled_count == 0)
            continue;
        const int64_t origin_x = static_cast<int64_t>(chunk.coord.x) * cs;
        const int64_t origin_y = static_cast<int64_t>(chunk.coord.y) * cs;
        const int64_t origin_z = static_cast<int64_t>(chunk.coord.z) * cs;
        for (int32_t lz = 0; lz < cs; ++lz) {
            for (int32_t ly = 0; ly < cs; ++ly) {
                for (int32_t lx = 0; lx < cs; ++lx) {
                    const uint8_t value = chunk.cells[VoxelGrid::LocalIndex(lx, ly, lz)];
                    if (value == 0)
                        continue;
                    const int64_t x64 = origin_x + lx;
                    const int64_t y64 = origin_y + ly;
                    const int64_t z64 = origin_z + lz;
                    if (x64 < -kCoordLimit || x64 > kCoordLimit || y64 < -kCoordLimit ||
                        y64 > kCoordLimit || z64 < -kCoordLimit || z64 > kCoordLimit) {
                        return Fail(error, "voxel coordinates are too large to export");
                    }
                    const auto x = static_cast<int32_t>(x64);
                    const auto y = static_cast<int32_t>(y64);
                    const auto z = static_cast<int32_t>(z64);
                    for (int face = 0; face < 6; ++face) {
                        if (NeighborSolid(grid, x, y, z, face))
                            continue;
                        if (quads->size() >= kMaxQuads) {
                            return Fail(error, "mesh exceeds " + std::to_string(kMaxQuads) +
                                                   " exposed quads");
                        }
                        quads->push_back(Quad{x, y, z, static_cast<uint8_t>(face), value});
                    }
                }
            }
        }
    }
    if (quads->empty())
        return Fail(error, "document has no exposed faces");
    return true;
}

int AxisOf(const int step[3]) {
    if (step[0] != 0)
        return 0;
    if (step[1] != 0)
        return 1;
    return 2;
}

int32_t AxisCoord(const Quad& quad, int axis) {
    if (axis == 0)
        return quad.x;
    if (axis == 1)
        return quad.y;
    return quad.z;
}

void SetAxis(int32_t* x, int32_t* y, int32_t* z, int axis, int32_t value) {
    if (axis == 0)
        *x = value;
    else if (axis == 1)
        *y = value;
    else
        *z = value;
}

// Greedy rectangles over coplanar unit faces of one palette slot.
// Scan order is (v, u), so an L splits the same way every time.
bool MergeQuads(std::vector<Quad>* quads, std::string* error) {
    // face -> plane -> (v, u) -> palette. std::map keeps the scan stable.
    std::map<uint8_t, std::map<int32_t, std::map<std::pair<int32_t, int32_t>, uint8_t>>> slices;
    for (const Quad& quad : *quads) {
        const int u_axis = AxisOf(kTangentU[quad.face]);
        const int v_axis = AxisOf(kTangentV[quad.face]);
        const int plane_axis = quad.face / 2;
        const int32_t u = AxisCoord(quad, u_axis);
        const int32_t v = AxisCoord(quad, v_axis);
        slices[quad.face][AxisCoord(quad, plane_axis)][{v, u}] = quad.palette;
    }
    const size_t unit_count = quads->size();
    std::vector<Quad> merged;
    merged.reserve(unit_count);
    int64_t covered = 0;
    for (auto& [face, planes] : slices) {
        const int u_axis = AxisOf(kTangentU[face]);
        const int v_axis = AxisOf(kTangentV[face]);
        const int plane_axis = face / 2;
        for (auto& [plane, mask] : planes) {
            std::vector<std::pair<int32_t, int32_t>> order;
            order.reserve(mask.size());
            for (const auto& entry : mask)
                order.push_back(entry.first);
            for (const auto& cell : order) {
                const auto it = mask.find(cell);
                if (it == mask.end())
                    continue;
                const int32_t v = cell.first;
                const int32_t u = cell.second;
                const uint8_t palette = it->second;
                int32_t w = 1;
                while (true) {
                    const auto next = mask.find({v, u + w});
                    if (next == mask.end() || next->second != palette)
                        break;
                    ++w;
                }
                int32_t h = 1;
                while (true) {
                    bool row = true;
                    for (int32_t i = 0; i < w; ++i) {
                        const auto next = mask.find({v + h, u + i});
                        if (next == mask.end() || next->second != palette) {
                            row = false;
                            break;
                        }
                    }
                    if (!row)
                        break;
                    ++h;
                }
                for (int32_t j = 0; j < h; ++j) {
                    for (int32_t i = 0; i < w; ++i)
                        mask.erase({v + j, u + i});
                }
                int32_t x = 0, y = 0, z = 0;
                SetAxis(&x, &y, &z, plane_axis, plane);
                SetAxis(&x, &y, &z, u_axis, u);
                SetAxis(&x, &y, &z, v_axis, v);
                merged.push_back(Quad{x, y, z, face, palette, w, h});
                covered += static_cast<int64_t>(w) * static_cast<int64_t>(h);
            }
        }
    }
    if (covered != static_cast<int64_t>(unit_count))
        return Fail(error, "internal mesh merge error");
    *quads = std::move(merged);
    return true;
}

// Palette slots are sRGB 8-bit. The PNG stores those bytes unchanged:
// glTF baseColorTexture is sRGB, and Blender imports it with an sRGB
// colorspace, so the swatch matches the palette.
// COLOR_0 is linear in the spec. Blender 5 copies it into a byte color
// attribute with an sRGB encode, then the viewport shows that byte.
// Writing the raw sRGB byte there (as if it were linear) lightens the
// swatch — byte 10 displayed as byte 56. Store the IEC 61966-2-1 linear
// value instead, so vertex-color mode matches the texture. Alpha is
// coverage, not gamma-encoded.
float SrgbByteToLinear(uint8_t channel) {
    const double encoded = static_cast<double>(channel) / 255.0;
    if (encoded <= 0.04045)
        return static_cast<float>(encoded / 12.92);
    return static_cast<float>(std::pow((encoded + 0.055) / 1.055, 2.4));
}
std::vector<uint8_t> BuildGlb(const std::vector<Quad>& quads, const Palette& palette,
                              MeshColorMode mode, MeshExportStats* stats, std::string* error) {
    const bool vertex_colors = mode == MeshColorMode::VertexColors;
    const size_t vertex_count = quads.size() * 4;
    const size_t index_count = quads.size() * 6;
    bool blend = false;
    std::vector<uint8_t> bin;
    const size_t pos_bytes = vertex_count * 12;
    const size_t nrm_bytes = vertex_count * 12;
    const size_t color_bytes = vertex_colors ? vertex_count * 16 : vertex_count * 8;
    const size_t index_bytes = index_count * 4;
    bin.reserve(pos_bytes + nrm_bytes + color_bytes + index_bytes + 2048);

    Section pos;
    pos.offset = bin.size();
    const float inf = std::numeric_limits<float>::infinity();
    Vec3 pmin{inf, inf, inf};
    Vec3 pmax{-inf, -inf, -inf};
    for (const Quad& quad : quads) {
        const Color color = palette.Get(quad.palette);
        if (color.a != 255)
            blend = true;
        for (int c = 0; c < 4; ++c) {
            const int su = (c == 1 || c == 2) ? quad.w : 0;
            const int sv = (c == 2 || c == 3) ? quad.h : 0;
            const float gx = static_cast<float>(quad.x + kCorner[quad.face][0][0] +
                                                kTangentU[quad.face][0] * su +
                                                kTangentV[quad.face][0] * sv);
            const float gy = static_cast<float>(quad.y + kCorner[quad.face][0][1] +
                                                kTangentU[quad.face][1] * su +
                                                kTangentV[quad.face][1] * sv);
            const float gz = static_cast<float>(quad.z + kCorner[quad.face][0][2] +
                                                kTangentU[quad.face][2] * su +
                                                kTangentV[quad.face][2] * sv);
            const Vec3 p = GridToGltf(gx, gy, gz);
            Consider(&pmin, &pmax, p);
            AppendFloat(&bin, p.x);
            AppendFloat(&bin, p.y);
            AppendFloat(&bin, p.z);
        }
    }
    pos.length = bin.size() - pos.offset;

    Section nrm;
    nrm.offset = bin.size();
    for (const Quad& quad : quads) {
        const Vec3 n = GridToGltf(static_cast<float>(kNormal[quad.face][0]),
                                  static_cast<float>(kNormal[quad.face][1]),
                                  static_cast<float>(kNormal[quad.face][2]));
        for (int c = 0; c < 4; ++c) {
            AppendFloat(&bin, n.x);
            AppendFloat(&bin, n.y);
            AppendFloat(&bin, n.z);
        }
    }
    nrm.length = bin.size() - nrm.offset;

    Section color;
    color.offset = bin.size();
    if (vertex_colors) {
        for (const Quad& quad : quads) {
            const Color c = palette.Get(quad.palette);
            const float r = SrgbByteToLinear(c.r);
            const float g = SrgbByteToLinear(c.g);
            const float b = SrgbByteToLinear(c.b);
            const float a = static_cast<float>(c.a) / 255.0f;
            for (int v = 0; v < 4; ++v) {
                AppendFloat(&bin, r);
                AppendFloat(&bin, g);
                AppendFloat(&bin, b);
                AppendFloat(&bin, a);
            }
        }
    } else {
        for (const Quad& quad : quads) {
            const float u = (static_cast<float>(quad.palette) + 0.5f) / 256.0f;
            for (int v = 0; v < 4; ++v) {
                AppendFloat(&bin, u);
                AppendFloat(&bin, 0.5f);
            }
        }
    }
    color.length = bin.size() - color.offset;

    Section indices;
    indices.offset = bin.size();
    for (size_t q = 0; q < quads.size(); ++q) {
        const auto base = static_cast<uint32_t>(q * 4);
        AppendLE32(&bin, base);
        AppendLE32(&bin, base + 1);
        AppendLE32(&bin, base + 2);
        AppendLE32(&bin, base);
        AppendLE32(&bin, base + 2);
        AppendLE32(&bin, base + 3);
    }
    indices.length = bin.size() - indices.offset;

    Section image;
    if (!vertex_colors) {
        std::vector<uint8_t> pixels(256 * 4);
        for (int i = 0; i < 256; ++i) {
            const Color c = palette.Get(static_cast<uint8_t>(i));
            pixels[static_cast<size_t>(i) * 4 + 0] = c.r;
            pixels[static_cast<size_t>(i) * 4 + 1] = c.g;
            pixels[static_cast<size_t>(i) * 4 + 2] = c.b;
            pixels[static_cast<size_t>(i) * 4 + 3] = c.a;
        }
        const std::vector<uint8_t> png = EncodePngRgba(pixels.data(), 256, 1);
        image.offset = bin.size();
        bin.insert(bin.end(), png.begin(), png.end());
        image.length = png.size();
    }
    while (bin.size() % 4 != 0)
        bin.push_back(0);

    if (bin.size() > static_cast<size_t>(std::numeric_limits<uint32_t>::max())) {
        Fail(error, "mesh is too large");
        return {};
    }

    std::string json = BuildJson(mode, blend, bin.size(), pos, nrm, color, indices, image,
                                 vertex_count, index_count, pmin, pmax);
    while (json.size() % 4 != 0)
        json.push_back(' ');
    if (json.size() > static_cast<size_t>(std::numeric_limits<uint32_t>::max())) {
        Fail(error, "mesh is too large");
        return {};
    }

    const auto json_len = static_cast<uint32_t>(json.size());
    const auto bin_len = static_cast<uint32_t>(bin.size());
    const uint64_t total64 = 12ull + 8ull + json_len + 8ull + bin_len;
    if (total64 > std::numeric_limits<uint32_t>::max()) {
        Fail(error, "mesh is too large");
        return {};
    }
    const auto total = static_cast<uint32_t>(total64);

    std::vector<uint8_t> glb;
    glb.reserve(total);
    AppendLE32(&glb, 0x46546c67u);
    AppendLE32(&glb, 2u);
    AppendLE32(&glb, total);
    AppendLE32(&glb, json_len);
    AppendLE32(&glb, 0x4e4f534au);
    glb.insert(glb.end(), json.begin(), json.end());
    AppendLE32(&glb, bin_len);
    AppendLE32(&glb, 0x004e4942u);
    glb.insert(glb.end(), bin.begin(), bin.end());

    if (stats != nullptr) {
        stats->quads = static_cast<uint32_t>(quads.size());
        stats->vertices = static_cast<uint32_t>(vertex_count);
        stats->triangles = static_cast<uint32_t>(quads.size() * 2);
    }
    return glb;
}

bool WriteFile(const std::string& path, const std::vector<uint8_t>& bytes, std::string* error) {
    FILE* file = std::fopen(path.c_str(), "wb");
    if (file == nullptr) {
        return Fail(error, "could not open " + path + " for writing: " + std::strerror(errno));
    }
    const size_t wrote = std::fwrite(bytes.data(), 1, bytes.size(), file);
    const int closed = std::fclose(file);
    if (wrote != bytes.size() || closed != 0) {
        std::remove(path.c_str());
        return Fail(error, "could not write " + path);
    }
    return true;
}

void PrintUsage() {
    std::fprintf(stderr, "usage: MacVoxel export --input <file.vox> --output <file.glb>\n"
                         "                       [--vertex-colors] [--merge]\n");
}

}  // namespace

bool ExportSceneGlb(Document& doc, const std::string& path, MeshColorMode mode,
                    MeshExportStats* stats, std::string* error, bool merge) {
    if (path.empty())
        return Fail(error, "path is empty");
    if (!FaceTablesOk())
        return Fail(error, "internal mesh winding error");
    try {
        doc.SyncActiveModel();
        if (doc.scene.empty())
            return Fail(error, "document has no voxels");
        VoxelGrid flat;
        FlattenScene(doc.scene, -1, &flat);
        if (flat.empty())
            return Fail(error, "document has no voxels");
        std::vector<Quad> quads;
        if (!CollectQuads(flat, &quads, error))
            return false;
        if (merge && !MergeQuads(&quads, error))
            return false;
        const std::vector<uint8_t> glb = BuildGlb(quads, doc.palette, mode, stats, error);
        if (glb.empty())
            return false;
        return WriteFile(path, glb, error);
    } catch (const std::bad_alloc&) {
        return Fail(error, "not enough memory to export the mesh");
    }
}

int RunCliExport(int argc, const char* argv[]) {
    const char* input = nullptr;
    const char* output = nullptr;
    bool vertex_colors = false;
    bool merge = false;
    for (int i = 1; i < argc; ++i) {
        const auto eq = [&](const char* tag) { return std::strcmp(argv[i], tag) == 0; };
        if (eq("--input")) {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "missing value for --input\n");
                return 2;
            }
            input = argv[++i];
        } else if (eq("--output")) {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "missing value for --output\n");
                return 2;
            }
            output = argv[++i];
        } else if (eq("--vertex-colors")) {
            vertex_colors = true;
        } else if (eq("--merge")) {
            merge = true;
        } else if (eq("-h") || eq("--help")) {
            PrintUsage();
            return 2;
        } else {
            std::fprintf(stderr, "unknown arg: %s\n", argv[i]);
            return 2;
        }
    }
    if (input == nullptr || output == nullptr) {
        PrintUsage();
        return 2;
    }

    Document doc;
    std::string err;
    if (!LoadVoxScene(input, &doc.scene, &doc.palette, &err)) {
        std::fprintf(stderr, "load failed: %s\n", err.c_str());
        return 1;
    }
    doc.active_object = 0;
    doc.path = input;

    const MeshColorMode mode = vertex_colors ? MeshColorMode::VertexColors : MeshColorMode::Texture;
    MeshExportStats stats;
    std::fprintf(stderr, "exporting %s → %s (%s)\n", input, output,
                 vertex_colors ? "vertex colors" : "texture");
    if (!ExportSceneGlb(doc, output, mode, &stats, &err, merge)) {
        std::fprintf(stderr, "export failed: %s\n", err.c_str());
        return 1;
    }
    std::fprintf(stderr, "wrote %s (%u triangles, %s)\n", output,
                 static_cast<unsigned>(stats.triangles),
                 vertex_colors ? "vertex colors" : "texture");
    return 0;
}

}  // namespace macvoxel
