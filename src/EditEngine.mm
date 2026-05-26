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
                   const EditVolume& vol)
        : brush_(brush),
          shape_(shape),
          generator_(generator),
          mutator_(mutator),
          lift_(lift),
          texture_(texture),
          vol_(&vol) {}

    void BrushStamp(const BrushParams& params) override {
        [brush_ dispatch:params target:texture_];
    }

    void ShapePreview(const ShapeParams& params) override {
        [shape_ dispatchPreview:params target:texture_];
    }

    void ShapeLineProjectPreview(const ShapeParams& params,
                                 const int32_t* cells_xyz,
                                 std::size_t cell_count) override {
        [shape_ dispatchLineProjectPreview:params
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
        [generator_ dispatchInto:texture_
                            kind:kind
                          bounds:bounds
                      lastBounds:last_bounds
                          params:params];
    }

    void DispatchMutator(const MutatorDispatchParams& params) override {
        [mutator_ dispatchInto:texture_ params:params];
    }

    void CommitGeneric(const CommitGenericParams& params) override {
        [shape_ dispatchCommitGeneric:params target:texture_];
    }

    void Readback(const Bbox3& world_bbox,
                  std::vector<uint8_t>* out_bytes) override {
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
        [shape_ waitForPendingWork];
        [brush_ waitForPendingWork];
        [mutator_ waitForPendingWork];
        [lift_ waitForPendingWork];
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
    void DrainOtherEngines() {
        // Lift kernels read/write tex_a alongside tex_lift. Drain any
        // pending brush / shape / mutator / generator work first so
        // tex_a is in its expected pre-lift state.
        [brush_ waitForPendingWork];
        [shape_ waitForPendingWork];
        [mutator_ waitForPendingWork];
    }

    BrushEngine* brush_;
    ShapeEngine* shape_;
    GeneratorEngine* generator_;
    MutatorEngine* mutator_;
    LiftEngine* lift_;
    VolumeTexture* texture_;
    const EditVolume* vol_;
};

}  // namespace

std::unique_ptr<EditEngine> MakeEditEngine(BrushEngine* brush,
                                           ShapeEngine* shape,
                                           GeneratorEngine* generator,
                                           MutatorEngine* mutator,
                                           LiftEngine* lift,
                                           VolumeTexture* texture,
                                           const EditVolume& vol) {
    return std::make_unique<EditEngineImpl>(brush, shape, generator,
                                            mutator, lift,
                                            texture, vol);
}

}  // namespace macvoxel
