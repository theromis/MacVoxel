#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace macvoxel {

struct BrushParams;
struct ShapeParams;
struct CellPalette;
struct CommitGenericParams;
struct Bbox3;
struct EditVolume;

namespace generators {
struct Bounds3i;
struct Params;
enum class Kind : uint32_t;
}  // namespace generators

struct MutatorDispatchParams;

// Pure-C++ façade over BrushEngine + ShapeEngine + GeneratorEngine.
//
// Replaces the per-tool `std::function` closures the controllers used
// to take (`StampFn`, `PreviewFn`, `StampCellsFn`, `GenerateFn`,
// `ReadBackFn`, `ClearBboxFn`, …) with a single object every Tool calls
// into. World↔texture-local translation for the bbox-shaped methods
// (Readback / ClearPreviewBbox) happens in the concrete impl; tools
// always speak world cell coords.
//
// Construction is gated behind `MakeEditEngine`, declared at the bottom
// of this header in the `#ifdef __OBJC__` block — it's the only thing
// that needs to see the Obj-C engine types.
class EditEngine {
public:
    virtual ~EditEngine() = default;

    // Brush kernel dispatch — async, writes into the doc texture
    // directly (Phase 0 wiring; Phase 2.4 will move this to tex_t +
    // commit_generic).
    virtual void BrushStamp(const BrushParams& params) = 0;

    // Shape preview kernel dispatch — async, writes into tex_t.
    virtual void ShapePreview(const ShapeParams& params) = 0;

    // Line tool's project-mode preview: same shape preview write, but
    // with a CPU-enumerated cell list (one per oversampled screen step).
    // `cells_xyz` is packed [x,y,z, x,y,z, …] in world cell coords;
    // `cell_count` is the entry count (not the int count).
    virtual void ShapeLineProjectPreview(const ShapeParams& params,
                                         const int32_t* cells_xyz,
                                         std::size_t cell_count) = 0;

    // Per-cell preview-surface splat used by the Face tool. palette != 0
    // stamps tex_t (Add / Paint); palette == 0 stamps preview_rem
    // (Remove). Commit happens via CommitGeneric over the union bbox.
    virtual void StampCells(const CellPalette* cells,
                            std::size_t cell_count) = 0;

    // Zero a tex_t region (in world cell coords). Tools clear their
    // preview on cancel / abort.
    virtual void ClearPreviewBbox(const Bbox3& world_bbox) = 0;

    // Generator kernel dispatch — async, writes into tex_t over the
    // union of `bounds` and `last_bounds` (so cells the previous
    // dispatch wrote that this one doesn't cover get zeroed).
    virtual void Generate(generators::Kind kind,
                          const generators::Bounds3i& bounds,
                          const generators::Bounds3i& last_bounds,
                          const generators::Params& params) = 0;

    // Mutator kernel dispatch — async, reads tex_a / tex_t / preview_rem
    // live-composited and writes a delta into tex_t. Commit happens via
    // CommitGeneric over the AOE union bbox afterwards (bm=Add for the
    // tex_t half, bm=Erase for the preview_rem half — Foliage v1 uses
    // only the Add half).
    virtual void DispatchMutator(const MutatorDispatchParams& params) = 0;

    // Unified commit — the Magica `shader_0018.glsl` pipeline.
    // Phase 2.2 wired Shape + Generator onto this; Face and Brush
    // migrations are deferred behind a `preview_rem` mask refactor
    // (see plan note on Phase 2.3 / 2.4 visual regression).
    virtual void CommitGeneric(const CommitGenericParams& params) = 0;

    // Wait for every previously-enqueued kernel to drain, then blit the
    // (world-cell) bbox out of the doc texture into `out_bytes`.
    // x-fastest layout matching VoxelVolume::data.
    virtual void Readback(const Bbox3& world_bbox,
                          std::vector<uint8_t>* out_bytes) = 0;

    // Standalone barrier in case a tool needs the GPU drained without
    // an immediate readback (Cancel paths).
    virtual void WaitForPendingWork() = 0;
};

}  // namespace macvoxel

#ifdef __OBJC__

@class BrushEngine;
@class ShapeEngine;
@class GeneratorEngine;
@class MutatorEngine;
@class VolumeTexture;

namespace macvoxel {

// MetalScene constructs one of these in init, passing the engines and
// the doc's VolumeTexture it already owns. The returned object holds
// strong (ARC) refs to all five; tools keep a non-owning pointer/ref.
// `vol` is observed by reference and must outlive the EditEngine.
std::unique_ptr<EditEngine> MakeEditEngine(BrushEngine* brush,
                                           ShapeEngine* shape,
                                           GeneratorEngine* generator,
                                           MutatorEngine* mutator,
                                           VolumeTexture* texture,
                                           const EditVolume& vol);

}  // namespace macvoxel

#endif  // __OBJC__
