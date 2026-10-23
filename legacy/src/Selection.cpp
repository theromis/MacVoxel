#include "Selection.h"

#include "CellKey.h"

#include <algorithm>

namespace macvoxel {

namespace {
inline int64_t Key(int32_t x, int32_t y, int32_t z) {
    return PackCellKey(x, y, z);
}
}  // namespace

Selection::Selection(const Selection& other)
    : bounds_(other.bounds_),
      voxels_(other.voxels_),
      active_(other.active_),
      lift_active_(other.lift_active_),
      pre_lift_originals_(other.pre_lift_originals_) {
    // Skip the membership cache; it'll be rebuilt on next Contains().
}

Selection::Selection(Selection&& other) noexcept
    : bounds_(other.bounds_),
      voxels_(std::move(other.voxels_)),
      active_(other.active_),
      lift_active_(other.lift_active_),
      pre_lift_originals_(std::move(other.pre_lift_originals_)),
      membership_(std::move(other.membership_)) {
    other.bounds_ = Bounds3{};
    other.active_ = false;
    other.lift_active_ = false;
}

Selection& Selection::operator=(const Selection& other) {
    if (this == &other) return *this;
    bounds_ = other.bounds_;
    voxels_ = other.voxels_;
    active_ = other.active_;
    lift_active_ = other.lift_active_;
    pre_lift_originals_ = other.pre_lift_originals_;
    membership_.reset();
    ++version_;
    return *this;
}

Selection& Selection::operator=(Selection&& other) noexcept {
    if (this == &other) return *this;
    bounds_ = other.bounds_;
    voxels_ = std::move(other.voxels_);
    active_ = other.active_;
    lift_active_ = other.lift_active_;
    pre_lift_originals_ = std::move(other.pre_lift_originals_);
    membership_ = std::move(other.membership_);
    other.bounds_ = Bounds3{};
    other.active_ = false;
    other.lift_active_ = false;
    ++version_;
    return *this;
}

bool Selection::Contains(int32_t x, int32_t y, int32_t z) const {
    if (!membership_.has_value()) {
        membership_.emplace();
        membership_->reserve(voxels_.size() * 2);
        for (const auto& v : voxels_) {
            membership_->insert(Key(v[0], v[1], v[2]));
        }
    }
    return membership_->count(Key(x, y, z)) != 0;
}

void Selection::SetVoxels(std::vector<std::array<int32_t, 3>> voxels) {
    voxels_ = std::move(voxels);
    RecomputeBounds();
    active_ = !voxels_.empty() || lift_active_;
    membership_.reset();
    ++version_;
}

void Selection::SetBox(const Bounds3& box) {
    bounds_ = box;
    voxels_.clear();
    active_ = !box.empty() || lift_active_;
    membership_.reset();
    ++version_;
}

void Selection::AddVoxel(int32_t x, int32_t y, int32_t z) {
    if (voxels_.empty()) {
        bounds_.min_x = bounds_.max_x = x;
        bounds_.min_y = bounds_.max_y = y;
        bounds_.min_z = bounds_.max_z = z;
    } else {
        bounds_.min_x = std::min(bounds_.min_x, x);
        bounds_.min_y = std::min(bounds_.min_y, y);
        bounds_.min_z = std::min(bounds_.min_z, z);
        bounds_.max_x = std::max(bounds_.max_x, x);
        bounds_.max_y = std::max(bounds_.max_y, y);
        bounds_.max_z = std::max(bounds_.max_z, z);
    }
    voxels_.push_back({x, y, z});
    active_ = true;
    membership_.reset();
    ++version_;
}

void Selection::Clear() {
    bounds_ = Bounds3{};
    voxels_.clear();
    active_ = false;
    lift_active_ = false;
    pre_lift_originals_.clear();
    membership_.reset();
    ++version_;
}

void Selection::SetLift(const Bounds3& lift_bounds,
                         std::vector<CellChange> pre_lift_originals) {
    bounds_ = lift_bounds;
    voxels_.clear();
    pre_lift_originals_ = std::move(pre_lift_originals);
    lift_active_ = true;
    active_ = true;
    membership_.reset();
    ++version_;
}

void Selection::UpdateLiftBounds(const Bounds3& lift_bounds) {
    bounds_ = lift_bounds;
    membership_.reset();
    ++version_;
}

void Selection::ClearLift() {
    lift_active_ = false;
    pre_lift_originals_.clear();
    if (voxels_.empty()) {
        bounds_ = Bounds3{};
        active_ = false;
    }
    membership_.reset();
    ++version_;
}

void Selection::RecomputeBounds() {
    if (voxels_.empty()) {
        bounds_ = Bounds3{};
        return;
    }
    int32_t bxmin = voxels_[0][0], bxmax = voxels_[0][0];
    int32_t bymin = voxels_[0][1], bymax = voxels_[0][1];
    int32_t bzmin = voxels_[0][2], bzmax = voxels_[0][2];
    for (size_t i = 1; i < voxels_.size(); ++i) {
        const auto& v = voxels_[i];
        bxmin = std::min(bxmin, v[0]); bxmax = std::max(bxmax, v[0]);
        bymin = std::min(bymin, v[1]); bymax = std::max(bymax, v[1]);
        bzmin = std::min(bzmin, v[2]); bzmax = std::max(bzmax, v[2]);
    }
    bounds_.min_x = bxmin; bounds_.max_x = bxmax;
    bounds_.min_y = bymin; bounds_.max_y = bymax;
    bounds_.min_z = bzmin; bounds_.max_z = bzmax;
}

}  // namespace macvoxel
