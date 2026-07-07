#include "VoxRoundTrip.h"

#include "Material.h"
#include "Palette.h"
#include "VoxFile.h"
#include "VoxScene.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <tuple>
#include <vector>

namespace macvoxel {
namespace {

int g_failures = 0;

void Fail(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void Fail(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    std::fprintf(stderr, "voxrt: FAIL: ");
    std::vfprintf(stderr, fmt, ap);
    std::fprintf(stderr, "\n");
    va_end(ap);
    ++g_failures;
}

bool CheckRotationCodec() {
    // Exhaustive property check: every canonical byte (bit 7 is outside
    // the codec) whose decode is a valid signed permutation must
    // re-encode to itself.
    int checked = 0;
    for (int b = 0; b < 128; ++b) {
        const uint8_t byte = static_cast<uint8_t>(b);
        const int c0 = byte & 0x3;
        const int c1 = (byte >> 2) & 0x3;
        const int c2 = 3 - c0 - c1;
        if (c0 == c1 || c0 > 2 || c1 > 2 || c2 < 0 || c2 > 2) continue;
        const RotMat m = RotMat::FromByte(byte);
        if (m.ToByte() != byte) {
            Fail("rotation codec: byte %d decodes/encodes to %d", b,
                 static_cast<int>(m.ToByte()));
            return false;
        }
        ++checked;
    }
    std::printf("voxrt: rotation codec ok (%d valid bytes)\n", checked);
    return true;
}

// World-space voxel multiset of one object, sorted for comparison.
std::vector<std::tuple<int32_t, int32_t, int32_t, uint8_t>> WorldCells(
    const Scene& scene, const SceneObject& o) {
    std::vector<std::tuple<int32_t, int32_t, int32_t, uint8_t>> out;
    if (o.model_id < 0 ||
        static_cast<size_t>(o.model_id) >= scene.models.size()) {
        return out;
    }
    const SceneModel& model = scene.models[static_cast<size_t>(o.model_id)];
    const Vec3i32 h{model.dims[0] / 2, model.dims[1] / 2, model.dims[2] / 2};
    constexpr int32_t cs = static_cast<int32_t>(VoxelGrid::kChunkSize);
    for (const auto& [coord, chunk] : model.grid.chunks()) {
        if (chunk->filled_count == 0) continue;
        for (int32_t lz = 0; lz < cs; ++lz)
        for (int32_t ly = 0; ly < cs; ++ly)
        for (int32_t lx = 0; lx < cs; ++lx) {
            const uint8_t v = chunk->cells[VoxelGrid::LocalIndex(lx, ly, lz)];
            if (v == 0) continue;
            const Vec3i32 w =
                o.world_r *
                    (Vec3i32{coord.x * cs + lx, coord.y * cs + ly,
                             coord.z * cs + lz} -
                     h) +
                o.world_t;
            out.emplace_back(w.x, w.y, w.z, v);
        }
    }
    std::sort(out.begin(), out.end());
    return out;
}

bool RotEq(const RotMat& a, const RotMat& b) {
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) {
            if (a.m[i][j] != b.m[i][j]) return false;
        }
    return true;
}

bool MatEq(const Material& a, const Material& b) {
    return a.type == b.type && a.roughness == b.roughness &&
           a.metallic == b.metallic && a.ior == b.ior &&
           a.transparency == b.transparency && a.emission == b.emission &&
           a.emissionPower == b.emissionPower;
}

void CompareScenes(const Scene& a, const Scene& b) {
    if (a.objects.size() != b.objects.size()) {
        Fail("object count: %zu -> %zu", a.objects.size(), b.objects.size());
        return;
    }
    for (size_t i = 0; i < a.objects.size(); ++i) {
        const SceneObject& oa = a.objects[i];
        const SceneObject& ob = b.objects[i];
        if (oa.name != ob.name) {
            Fail("object %zu name: '%s' -> '%s'", i, oa.name.c_str(),
                 ob.name.c_str());
        }
        if (oa.hidden != ob.hidden) {
            Fail("object %zu hidden flag changed", i);
        }
        if (!(oa.world_t == ob.world_t)) {
            Fail("object %zu world_t: (%d,%d,%d) -> (%d,%d,%d)", i,
                 oa.world_t.x, oa.world_t.y, oa.world_t.z, ob.world_t.x,
                 ob.world_t.y, ob.world_t.z);
        }
        if (!RotEq(oa.world_r, ob.world_r)) {
            Fail("object %zu world rotation changed", i);
        }
        if (WorldCells(a, oa) != WorldCells(b, ob)) {
            Fail("object %zu world voxels differ", i);
        }
    }
    if (a.layers.size() != b.layers.size()) {
        Fail("layer count: %zu -> %zu", a.layers.size(), b.layers.size());
    } else {
        for (size_t i = 0; i < a.layers.size(); ++i) {
            if (a.layers[i].id != b.layers[i].id ||
                a.layers[i].attrs != b.layers[i].attrs) {
                Fail("layer %zu differs", i);
            }
        }
    }
}

void ComparePalettes(const Palette& a, const Palette& b) {
    for (int i = 1; i <= 255; ++i) {
        const uint8_t idx = static_cast<uint8_t>(i);
        if (!(a.Get(idx) == b.Get(idx))) {
            Fail("palette slot %d color differs", i);
            return;
        }
    }
    for (int i = 1; i <= 255; ++i) {
        const uint8_t idx = static_cast<uint8_t>(i);
        if (!MatEq(a.GetMaterial(idx), b.GetMaterial(idx))) {
            Fail("material slot %d differs", i);
            return;
        }
    }
}

bool ReadAll(const std::string& path, std::vector<uint8_t>* out) {
    std::ifstream in(path, std::ios::binary | std::ios::ate);
    if (!in) return false;
    const std::streamsize sz = in.tellg();
    in.seekg(0, std::ios::beg);
    out->resize(static_cast<size_t>(sz));
    return sz == 0 ||
           static_cast<bool>(
               in.read(reinterpret_cast<char*>(out->data()), sz));
}

// -------------------------------------------------------------------------
// --dump: raw chunk walk (independent of the loader, for A/B inspection)
// -------------------------------------------------------------------------

struct DumpReader {
    const uint8_t* p;
    size_t n, pos = 0;
    bool U32(uint32_t* v) {
        if (pos + 4 > n) return false;
        std::memcpy(v, p + pos, 4);
        pos += 4;
        return true;
    }
    bool I32(int32_t* v) { return U32(reinterpret_cast<uint32_t*>(v)); }
    bool Str(std::string* s) {
        int32_t len = 0;
        if (!I32(&len) || len < 0 || pos + static_cast<size_t>(len) > n)
            return false;
        s->assign(reinterpret_cast<const char*>(p + pos),
                  static_cast<size_t>(len));
        pos += static_cast<size_t>(len);
        return true;
    }
    bool Dict(std::string* out) {
        int32_t cnt = 0;
        if (!I32(&cnt) || cnt < 0) return false;
        out->clear();
        for (int32_t i = 0; i < cnt; ++i) {
            std::string k, v;
            if (!Str(&k) || !Str(&v)) return false;
            *out += " " + k + "=" + v;
        }
        return true;
    }
};

void DumpNodePayload(const char id[4], const uint8_t* p, uint32_t n) {
    DumpReader r{p, n};
    int32_t nid = 0;
    std::string attrs;
    if (!r.I32(&nid) || !r.Dict(&attrs)) return;
    if (std::memcmp(id, "nTRN", 4) == 0) {
        int32_t child = 0, res = 0, layer = 0, frames = 0;
        r.I32(&child);
        r.I32(&res);
        r.I32(&layer);
        r.I32(&frames);
        std::printf("    id=%d child=%d layer=%d frames=%d attrs{%s}\n", nid,
                    child, layer, frames, attrs.c_str());
        for (int32_t i = 0; i < frames; ++i) {
            std::string f;
            if (!r.Dict(&f)) break;
            std::printf("      frame %d {%s}\n", i, f.c_str());
        }
    } else if (std::memcmp(id, "nGRP", 4) == 0) {
        int32_t cnt = 0;
        r.I32(&cnt);
        std::printf("    id=%d attrs{%s} children[", nid, attrs.c_str());
        for (int32_t i = 0; i < cnt; ++i) {
            int32_t c = 0;
            r.I32(&c);
            std::printf(i ? " %d" : "%d", c);
        }
        std::printf("]\n");
    } else if (std::memcmp(id, "nSHP", 4) == 0) {
        int32_t cnt = 0;
        r.I32(&cnt);
        std::printf("    id=%d attrs{%s} models[", nid, attrs.c_str());
        for (int32_t i = 0; i < cnt; ++i) {
            int32_t mid = 0;
            std::string ma;
            if (!r.I32(&mid) || !r.Dict(&ma)) break;
            std::printf(i ? " %d{%s}" : "%d{%s}", mid, ma.c_str());
        }
        std::printf("]\n");
    } else if (std::memcmp(id, "LAYR", 4) == 0) {
        std::printf("    id=%d attrs{%s}\n", nid, attrs.c_str());
    }
}

int DumpFile(const std::string& path) {
    std::vector<uint8_t> bytes;
    if (!ReadAll(path, &bytes) || bytes.size() < 20) {
        std::fprintf(stderr, "voxrt: cannot read %s\n", path.c_str());
        return 1;
    }
    std::printf("%s (%zu bytes)\n", path.c_str(), bytes.size());
    uint32_t main_children = 0;
    std::memcpy(&main_children, bytes.data() + 16, 4);
    size_t pos = 20;
    const size_t end = std::min(bytes.size(), 20 + size_t{main_children});
    while (pos + 12 <= end) {
        char id[4];
        uint32_t content = 0, child = 0;
        std::memcpy(id, bytes.data() + pos, 4);
        std::memcpy(&content, bytes.data() + pos + 4, 4);
        std::memcpy(&child, bytes.data() + pos + 8, 4);
        std::printf("  %c%c%c%c content=%u child=%u\n", id[0], id[1], id[2],
                    id[3], content, child);
        if (pos + 12 + content <= end) {
            DumpNodePayload(id, bytes.data() + pos + 12, content);
        }
        pos += 12 + size_t{content} + size_t{child};
    }
    return 0;
}

}  // namespace

int RunVoxRoundTrip(int argc, const char* argv[]) {
    std::string input, output;
    bool dump = false;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--input") == 0 && i + 1 < argc) {
            input = argv[++i];
        } else if (std::strcmp(argv[i], "--output") == 0 && i + 1 < argc) {
            output = argv[++i];
        } else if (std::strcmp(argv[i], "--dump") == 0) {
            dump = true;
        } else {
            std::fprintf(stderr,
                         "usage: MacVoxel voxrt --input A.vox "
                         "[--output B.vox] [--dump]\n");
            return 2;
        }
    }
    if (input.empty()) {
        std::fprintf(stderr, "voxrt: --input is required\n");
        return 2;
    }
    if (dump) return DumpFile(input);

    if (!CheckRotationCodec()) return 1;

    if (output.empty()) {
        output = (std::filesystem::temp_directory_path() /
                  "macvoxel-voxrt.vox")
                     .string();
    }
    const std::string fixpoint = output + ".2";

    Scene a;
    Palette pa;
    std::string err;
    if (!LoadVoxScene(input, &a, &pa, &err)) {
        std::fprintf(stderr, "voxrt: load %s failed: %s\n", input.c_str(),
                     err.c_str());
        return 1;
    }
    std::printf("voxrt: %s: %zu objects, %zu models, %zu layers\n",
                input.c_str(), a.objects.size(), a.models.size(),
                a.layers.size());

    if (!SaveVoxScene(output, a, pa, &err)) {
        std::fprintf(stderr, "voxrt: save %s failed: %s\n", output.c_str(),
                     err.c_str());
        return 1;
    }

    Scene b;
    Palette pb;
    if (!LoadVoxScene(output, &b, &pb, &err)) {
        std::fprintf(stderr, "voxrt: reload %s failed: %s\n", output.c_str(),
                     err.c_str());
        return 1;
    }

    CompareScenes(a, b);
    ComparePalettes(pa, pb);

    // Save-fixpoint: a second save of the reloaded scene must be
    // byte-identical (the writer normalizes exactly once).
    if (!SaveVoxScene(fixpoint, b, pb, &err)) {
        std::fprintf(stderr, "voxrt: fixpoint save failed: %s\n", err.c_str());
        return 1;
    }
    std::vector<uint8_t> f1, f2;
    if (!ReadAll(output, &f1) || !ReadAll(fixpoint, &f2) || f1 != f2) {
        Fail("save fixpoint: second save differs from first");
    }
    std::filesystem::remove(fixpoint);

    if (g_failures == 0) {
        std::printf("voxrt: OK (%s)\n", input.c_str());
        return 0;
    }
    std::fprintf(stderr, "voxrt: %d failure(s); round-trip file kept at %s\n",
                 g_failures, output.c_str());
    return 1;
}

}  // namespace macvoxel
