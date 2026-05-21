#import "EditEngine.h"

#import "BrushEngine.h"
#import "EditVolume.h"
#import "GeneratorEngine.h"
#import "Generators.h"
#import "MutatorEngine.h"
#import "ShapeEngine.h"
#import "VolumeTexture.h"

namespace macvoxel {

namespace {

// Concrete impl. Holds ARC-strong refs to the four engine objects
// MetalScene already owns + a non-owning EditVolume reference for the
// world→texture-local bbox translation used by Readback / ClearPreviewBbox.
class EditEngineImpl final : public EditEngine {
public:
    EditEngineImpl(BrushEngine* brush, ShapeEngine* shape,
                   GeneratorEngine* generator, MutatorEngine* mutator,
                   VolumeTexture* texture,
                   const EditVolume& vol)
        : brush_(brush),
          shape_(shape),
          generator_(generator),
          mutator_(mutator),
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
        // ShapeEngine and BrushEngine share the dedicated brush command
        // queue (see MetalScene init), so waiting on either drains both;
        // wait on shape first defensively since the most recent dispatch
        // might be a preview / commit kernel from a shape gesture.
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
    }

private:
    BrushEngine* brush_;          // ARC-strong
    ShapeEngine* shape_;          // ARC-strong
    GeneratorEngine* generator_;  // ARC-strong
    MutatorEngine* mutator_;      // ARC-strong
    VolumeTexture* texture_;      // ARC-strong
    const EditVolume* vol_;       // non-owning, must outlive *this
};

}  // namespace

std::unique_ptr<EditEngine> MakeEditEngine(BrushEngine* brush,
                                           ShapeEngine* shape,
                                           GeneratorEngine* generator,
                                           MutatorEngine* mutator,
                                           VolumeTexture* texture,
                                           const EditVolume& vol) {
    return std::make_unique<EditEngineImpl>(brush, shape, generator,
                                            mutator, texture, vol);
}

}  // namespace macvoxel
