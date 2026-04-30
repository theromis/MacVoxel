#pragma once

#include <array>
#include <cstdint>

namespace macvoxel {

struct Color {
    uint8_t r = 0;
    uint8_t g = 0;
    uint8_t b = 0;
    uint8_t a = 0;

    friend bool operator==(const Color& a, const Color& b) {
        return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a;
    }
};

// 256-entry RGBA palette. Index 0 is the "empty" slot (transparent by
// default); indices 1..255 are visible colors. Default-constructed Palette
// holds the MagicaVoxel built-in palette so a freshly loaded .vox file with
// no RGBA chunk still renders sensibly.
class Palette {
public:
    static constexpr size_t kSize = 256;

    Palette();

    Color Get(uint8_t index) const { return colors_[index]; }
    void Set(uint8_t index, Color c) { colors_[index] = c; }

    const Color* data() const { return colors_.data(); }
    Color* data() { return colors_.data(); }

    // Replace all 256 entries with the MagicaVoxel default palette.
    void ResetToDefault();

private:
    std::array<Color, kSize> colors_{};
};

}  // namespace macvoxel
