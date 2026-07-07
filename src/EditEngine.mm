#import "EditEngine.h"

#import "BrushEngine.h"
#import "EditVolume.h"
#import "GeneratorEngine.h"
#import "Generators.h"
#import "LiftEngine.h"
#import "MutatorEngine.h"
#import "ShapeEngine.h"
#import "VolumeTexture.h"
#import "VoxelGrid.h"
#import "VoxelVolume.h"

#import <Metal/Metal.h>

#include <algorithm>
#include <vector>

namespace macvoxel {

namespace {

class EditEngineImpl final : public EditEngine {
public:
    EditEngineImpl(BrushEngine* brush, ShapeEngine* shape,
                   GeneratorEngine* generator, MutatorEngine* mutator,
                   LiftEngine* lift,
                   VolumeTexture* texture,
                   const EditVolume& vol,
                   const Bounds3& edit_bounds)
        : brush_(brush),
          shape_(shape),
          generator_(generator),
          mutator_(mutator),
          lift_(lift),
          texture_(texture),
          vol_(&vol),
          edit_(&edit_bounds) {}

    // The volume-writing dispatches below all clamp to the LOGICAL
    // edit region (the active object's dims box): the physical volume
    // is its 16-aligned cover, and the pad cells must never take a
    // write or the object's AABB would grow on the next model sync.

    void BrushStamp(const BrushParams& params) override {
        BrushParams p = params;
        const EditVolume w = Writable();
        p.vol_x0 = w.x0; p.vol_y0 = w.y0; p.vol_z0 = w.z0;
        p.vol_x1 = w.x1; p.vol_y1 = w.y1; p.vol_z1 = w.z1;
        p.tex_origin_x = vol_->x0;
        p.tex_origin_y = vol_->y0;
        p.tex_origin_z = vol_->z0;
        [brush_ dispatch:p target:texture_];
    }

    void ShapePreview(const ShapeParams& params) override {
        [shape_ dispatchPreview:ClampShapeParams(params) target:texture_];
    }

    void ShapeLineProjectPreview(const ShapeParams& params,
                                 const int32_t* cells_xyz,
                                 std::size_t cell_count) override {
        [shape_ dispatchLineProjectPreview:ClampShapeParams(params)
                                      cells:cells_xyz
                                 cellCount:static_cast<NSUInteger>(cell_count)
                                     target:texture_];
    }

    void StampCells(const CellPalette* cells,
                    std::size_t cell_count) override {
        [shape_ dispatchStampCells:cells
                          cellCount:static_cast<NSUInteger>(cell_count)
                             target:texture_];
    }

    void ClearPreviewBbox(const Bbox3& world_bbox) override {
        [shape_ clearPreviewBbox:(world_bbox.x0 - vol_->x0)
                              y0:(world_bbox.y0 - vol_->y0)
                              z0:(world_bbox.z0 - vol_->z0)
                              x1:(world_bbox.x1 - vol_->x0)
                              y1:(world_bbox.y1 - vol_->y0)
                              z1:(world_bbox.z1 - vol_->z0)
                          target:texture_];
    }

    void Generate(generators::Kind kind,
                  const generators::Bounds3i& bounds,
                  const generators::Bounds3i& last_bounds,
                  const generators::Params& params) override {
        const EditVolume w = Writable();
        generators::Bounds3i clip{};
        clip.x0 = w.x0; clip.y0 = w.y0; clip.z0 = w.z0;
        clip.x1 = w.x1; clip.y1 = w.y1; clip.z1 = w.z1;
        [generator_ dispatchInto:texture_
                            kind:kind
                          bounds:bounds
                      lastBounds:last_bounds
                            clip:clip
                          params:params];
    }

    void DispatchMutator(const MutatorDispatchParams& params) override {
        MutatorDispatchParams p = params;
        const EditVolume w = Writable();
        p.aoe_x0 = std::max(p.aoe_x0, w.x0);
        p.aoe_y0 = std::max(p.aoe_y0, w.y0);
        p.aoe_z0 = std::max(p.aoe_z0, w.z0);
        p.aoe_x1 = std::min(p.aoe_x1, w.x1);
        p.aoe_y1 = std::min(p.aoe_y1, w.y1);
        p.aoe_z1 = std::min(p.aoe_z1, w.z1);
        if (p.aoe_x0 > p.aoe_x1 || p.aoe_y0 > p.aoe_y1 ||
            p.aoe_z0 > p.aoe_z1) {
            return;
        }
        [mutator_ dispatchInto:texture_ params:p];
    }

    void CommitGeneric(const CommitGenericParams& params) override {
        [shape_ dispatchCommitGeneric:params target:texture_];
    }

    void Readback(const Bbox3& world_bbox,
                  std::vector<uint8_t>* out_bytes) override {
        [generator_ waitForPendingWork];
        [shape_ waitForPendingWork];
        [brush_ waitForPendingWork];
        Bbox3 local{};
        local.x0 = world_bbox.x0 - vol_->x0;
        local.y0 = world_bbox.y0 - vol_->y0;
        local.z0 = world_bbox.z0 - vol_->z0;
        local.x1 = world_bbox.x1 - vol_->x0;
        local.y1 = world_bbox.y1 - vol_->y0;
        local.z1 = world_bbox.z1 - vol_->z0;
        [brush_ readTextureRegion:out_bytes target:texture_ bbox:local];
    }

    void WaitForPendingWork() override {
        [generator_ waitForPendingWork];
        [shape_ waitForPendingWork];
        [brush_ waitForPendingWork];
        [mutator_ waitForPendingWork];
        [lift_ waitForPendingWork];
    }

    void RefreshDocOracle(VoxelVolume& shadow) override {
        [texture_ refreshOracleFromVolume:shadow];
    }

    // ---------------- Lift pipeline ----------------

    void LiftBox(const Bounds3& bbox) override {
        DrainOtherEngines();
        [lift_ dispatchLiftBox:texture_ worldBbox:bbox];
    }

    void LiftCells(const int32_t* cells_xyz,
                    std::size_t cell_count) override {
        if (cell_count == 0) return;
        DrainOtherEngines();
        [lift_ dispatchLiftCells:texture_
                            cells:cells_xyz
                        cellCount:static_cast<NSUInteger>(cell_count)];
    }

    void TranslateLift(const Bounds3& old_bbox,
                        const Bounds3& new_bbox,
                        const int32_t offset[3]) override {
        [lift_ waitForPendingWork];
        int32_t off_copy[3] = {offset[0], offset[1], offset[2]};
        [lift_ dispatchLiftTranslate:texture_
                        oldWorldBbox:old_bbox
                        newWorldBbox:new_bbox
                              offset:off_copy];
    }

    void TransformLift(const LiftTransformParams& params,
                        const Bounds3& old_bbox) override {
        // dispatchLiftTransform snapshots first, then dispatches over
        // union(old, dst). The kernel back-maps inside dst and zeroes
        // outside dst (clearing the old lift position in the same
        // pass) — no separate clear needed, and the snapshot captures
        // the original lift before any zeroing happens.
        [lift_ dispatchLiftTransform:texture_ params:params oldBbox:old_bbox];
    }

    void ReadbackLift(const Bounds3& bbox,
                       std::vector<uint8_t>* out_lift_bytes) override {
        if (out_lift_bytes == nullptr) return;
        [lift_ waitForPendingWork];
        Bbox3 local{};
        local.x0 = std::max(bbox.min_x, vol_->x0) - vol_->x0;
        local.y0 = std::max(bbox.min_y, vol_->y0) - vol_->y0;
        local.z0 = std::max(bbox.min_z, vol_->z0) - vol_->z0;
        local.x1 = std::min(bbox.max_x, vol_->x1) - vol_->x0;
        local.y1 = std::min(bbox.max_y, vol_->y1) - vol_->y0;
        local.z1 = std::min(bbox.max_z, vol_->z1) - vol_->z0;
        if (local.x0 > local.x1 || local.y0 > local.y1 || local.z0 > local.z1) {
            out_lift_bytes->clear();
            return;
        }
        ReadTexBbox(texture_.liftTexture, local, out_lift_bytes);
    }

    void CommitLift(const Bounds3& bbox,
                     std::vector<uint8_t>* out_lift_bytes) override {
        [lift_ waitForPendingWork];

        // Read back tex_lift bytes over bbox so caller can build the
        // diff against shadow.
        Bbox3 local{};
        local.x0 = std::max(bbox.min_x, vol_->x0) - vol_->x0;
        local.y0 = std::max(bbox.min_y, vol_->y0) - vol_->y0;
        local.z0 = std::max(bbox.min_z, vol_->z0) - vol_->z0;
        local.x1 = std::min(bbox.max_x, vol_->x1) - vol_->x0;
        local.y1 = std::min(bbox.max_y, vol_->y1) - vol_->y0;
        local.z1 = std::min(bbox.max_z, vol_->z1) - vol_->z0;
        if (local.x0 > local.x1 || local.y0 > local.y1 || local.z0 > local.z1) {
            if (out_lift_bytes) out_lift_bytes->clear();
            return;
        }
        if (out_lift_bytes) {
            ReadTexBbox(texture_.liftTexture, local, out_lift_bytes);
        }
        [lift_ dispatchLiftCommit:texture_ worldBbox:bbox];
    }

    void ClearLift(const Bounds3& bbox) override {
        [lift_ dispatchLiftClear:texture_ worldBbox:bbox];
    }

    static void ReadTexBbox(id<MTLTexture> tex, const Bbox3& local,
                             std::vector<uint8_t>* out) {
        const NSUInteger w = (NSUInteger)(local.x1 - local.x0 + 1);
        const NSUInteger h = (NSUInteger)(local.y1 - local.y0 + 1);
        const NSUInteger d = (NSUInteger)(local.z1 - local.z0 + 1);
        out->assign(w * h * d, 0);
        MTLRegion region = MTLRegionMake3D(
            (NSUInteger)local.x0, (NSUInteger)local.y0, (NSUInteger)local.z0,
            w, h, d);
        [tex getBytes:out->data()
          bytesPerRow:w
        bytesPerImage:w * h
           fromRegion:region
          mipmapLevel:0
                slice:0];
    }

private:
    // Logical writable region (world, inclusive); falls back to the
    // physical volume until the first rebake establishes edit_bounds.
    EditVolume Writable() const {
        if (edit_->empty()) return *vol_;
        EditVolume w = *vol_;
        w.x0 = edit_->min_x; w.x1 = edit_->max_x;
        w.y0 = edit_->min_y; w.y1 = edit_->max_y;
        w.z0 = edit_->min_z; w.z1 = edit_->max_z;
        return w;
    }

    ShapeParams ClampShapeParams(const ShapeParams& params) const {
        ShapeParams p = params;
        const EditVolume w = Writable();
        p.vol_min_x = std::max(p.vol_min_x, w.x0);
        p.vol_min_y = std::max(p.vol_min_y, w.y0);
        p.vol_min_z = std::max(p.vol_min_z, w.z0);
        p.vol_max_x = std::min(p.vol_max_x, w.x1);
        p.vol_max_y = std::min(p.vol_max_y, w.y1);
        p.vol_max_z = std::min(p.vol_max_z, w.z1);
        return p;
    }

    void DrainOtherEngines() {
        // Lift kernels read/write tex_a alongside tex_lift. Drain any
        // pending brush / shape / mutator / generator work first so
        // tex_a is in its expected pre-lift state.
        [brush_ waitForPendingWork];
        [shape_ waitForPendingWork];
        [mutator_ waitForPendingWork];
        [generator_ waitForPendingWork];
    }

    BrushEngine* brush_;
    ShapeEngine* shape_;
    GeneratorEngine* generator_;
    MutatorEngine* mutator_;
    LiftEngine* lift_;
    VolumeTexture* texture_;
    const EditVolume* vol_;
    const Bounds3* edit_;
};

}  // namespace

std::unique_ptr<EditEngine> MakeEditEngine(BrushEngine* brush,
                                           ShapeEngine* shape,
                                           GeneratorEngine* generator,
                                           MutatorEngine* mutator,
                                           LiftEngine* lift,
                                           VolumeTexture* texture,
                                           const EditVolume& vol,
                                           const Bounds3& edit_bounds) {
    return std::make_unique<EditEngineImpl>(brush, shape, generator,
                                            mutator, lift,
                                            texture, vol, edit_bounds);
}

}  // namespace macvoxel
