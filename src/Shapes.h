#pragma once

#include <cstdint>
#include <vector>

namespace macvoxel {

class VoxelGrid;

namespace shapes {

struct Vec3i {
    int32_t x;
    int32_t y;
    int32_t z;
};

// Standard 3D Bresenham (Amanatides-style integer DDA): emits every cell
// the segment passes through, inclusive of both endpoints, with no diagonal
// gaps. Output is dm+1 cells where dm = max(|dx|, |dy|, |dz|).
void Bresenham3D(int x0, int y0, int z0, int x1, int y1, int z1,
                 std::vector<Vec3i>& out);

// Project a 3D cell into the in-plane (u, v) coordinates of a face axis.
// face_axis is the *normal* of the plane (0 = X, 1 = Y, 2 = Z), so the
// in-plane axes are the other two.
void ProjectInPlane(int face_axis, int x, int y, int z, int* u, int* v);

// Inverse of ProjectInPlane: write (i, j) offsets back into the (dx, dy, dz)
// triple corresponding to the same face axis.
void OffsetInPlane(int face_axis, int i, int j, int* dx, int* dy, int* dz);

// Straight-line cell enumeration between two grid cells.
void EnumerateLine(Vec3i a, Vec3i b, std::vector<Vec3i>& out);

// Disc / ring of cells in the plane perpendicular to face_axis. anchor is
// the disc center; endpoint sets the radius (Euclidean distance in plane).
// `even` shifts the center to the lattice corner so even diameters are
// achievable. `fill` selects between filled disc and 4-neighbor outline.
void EnumerateCirclePlanar(Vec3i anchor, Vec3i endpoint, int face_axis,
                           bool fill, bool even, std::vector<Vec3i>& out);

// Square / frame of cells, same conventions as EnumerateCirclePlanar but
// using a Chebyshev (max-norm) predicate so the cursor offset acts as the
// edge midpoint of a square always centered on the anchor.
void EnumerateSquarePlanar(Vec3i anchor, Vec3i endpoint, int face_axis,
                           bool fill, bool even, std::vector<Vec3i>& out);

// Axis-aligned box of cells whose opposite corners are corner_a and
// corner_b (each pair of coordinates is taken componentwise as min/max,
// inclusive). fill = filled volume; otherwise the hollow 1-cell-thick
// shell of the bounding box.
void EnumerateBox(Vec3i corner_a, Vec3i corner_b, bool fill,
                  std::vector<Vec3i>& out);

// Flood-fill in the plane perpendicular to `axis` through `seed`. Returns
// every cell that (a) is non-empty and matches `match_color` (or any
// non-empty cell when match_color == 0) and (b) has its face on the
// (axis, sign) side exposed (the cell at offset +sign along axis is empty).
// Uses 4- or 8-connectivity in the in-plane axes per `eight_conn`.
void FloodCoplanarFace(const VoxelGrid& grid, Vec3i seed, int axis, int sign,
                       uint8_t match_color, bool eight_conn,
                       std::vector<Vec3i>& out);

}  // namespace shapes
}  // namespace macvoxel
