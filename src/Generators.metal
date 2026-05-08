// MSL source for every generator kernel. Kept as a single library so all
// kernels share the same Uniforms layout — adding a new kind is one kernel
// function plus one entry in `KernelNameForKind` in GeneratorEngine.mm.
//
// Output protocol (all kernels):
//   buffer(0) = Uniforms (bounds + params, packed below)
//   buffer(1) = atomic_uint counter (zeroed by the host before dispatch)
//   buffer(2) = device PackedCell* output of capacity ≥ bounds volume
// A thread that decides its cell is filled does:
//   slot = atomic_fetch_add_explicit(counter, 1, relaxed);
//   output[slot] = packed cell
// Threads dispatched outside the bounds (when the dispatch is rounded up
// to a multiple of the threadgroup size) early-return.

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    int3 lo;          // bounds min (x0, y0, z0)
    int3 dims;        // bounds size (x1 - x0 + 1, ...)
    uint palette_idx; // unused on GPU side; kept for parity with CPU Params
    uint pad0;
    uint pad1;
    uint pad2;
};

struct PackedCell { int x, y, z; };

// Common: convert thread-position-in-grid to a cell coordinate inside
// the bounds, returning false if the thread is past the dispatch tail.
static bool resolve_cell(uint3 gid, constant Uniforms& u, thread int3& cell) {
    if (any(int3(gid) >= u.dims)) return false;
    cell = int3(gid) + u.lo;
    return true;
}

static void emit(int3 cell,
                 device atomic_uint* counter,
                 device PackedCell* out) {
    uint slot = atomic_fetch_add_explicit(counter, 1u, memory_order_relaxed);
    out[slot] = PackedCell{cell.x, cell.y, cell.z};
}

// Ellipsoid that exactly fits the bounding box: for box width W, the
// ellipsoid's half-extent on that axis is W/2. The center sits at the
// box's geometric center (between cells when W is even, on a cell when
// odd). A cell is filled when the squared sum of its normalized offsets
// from the center is ≤ 1.
kernel void generate_ellipsoid(
    constant Uniforms& u                  [[buffer(0)]],
    device atomic_uint* counter           [[buffer(1)]],
    device PackedCell* out                [[buffer(2)]],
    uint3 gid                             [[thread_position_in_grid]])
{
    int3 cell;
    if (!resolve_cell(gid, u, cell)) return;

    float3 center = float3(2 * u.lo + u.dims) * 0.5;  // (lo + (lo + dims)) / 2
    float3 half_ext = float3(u.dims) * 0.5;
    float3 norm = (float3(cell) + 0.5 - center) / half_ext;
    if (dot(norm, norm) <= 1.0) {
        emit(cell, counter, out);
    }
}
