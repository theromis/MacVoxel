#pragma once

// Icons from resources/SF-Symbols-Export.ttf, merged into the body font
// at PUA codepoints U+F000–U+F0FF. Defined as macros so they participate
// in string-literal concatenation: `ImGui::Button(ICON_PENCIL "  Draw")`.
//
// Numbered variants (paintbrush1, align3, etc.) are export-time variants
// of the same symbol family. Defined for symmetry but not used until we
// have a specific reason (e.g. axis-tagged rotate icons for a future
// transform gizmo).

#define ICON_SQUARE         "\xEF\x80\x80"  // F000
#define ICON_SCOPE          "\xEF\x80\x81"  // F001
#define ICON_ROTATE         "\xEF\x80\x82"  // F002
#define ICON_ROTATE1        "\xEF\x80\x83"  // F003
#define ICON_ROTATE2        "\xEF\x80\x84"  // F004
#define ICON_ROTATE3        "\xEF\x80\x85"  // F005
#define ICON_PENCIL         "\xEF\x80\x86"  // F006
#define ICON_PENCIL1        "\xEF\x80\x87"  // F007
#define ICON_PAINT_PALETTE  "\xEF\x80\x88"  // F008
#define ICON_PAINT_PALETTE1 "\xEF\x80\x89"  // F009
#define ICON_PAINT_BRUSH    "\xEF\x80\x8A"  // F00A
#define ICON_PAINT_BRUSH1   "\xEF\x80\x8B"  // F00B
#define ICON_PAINT_BRUSH2   "\xEF\x80\x8C"  // F00C
#define ICON_PAINT_BRUSH3   "\xEF\x80\x8D"  // F00D
#define ICON_PAINT          "\xEF\x80\x8E"  // F00E
#define ICON_GEARSHAPE      "\xEF\x80\x8F"  // F00F
#define ICON_GEARSHAPE1     "\xEF\x80\x90"  // F010
#define ICON_EYEDROPPER     "\xEF\x80\x91"  // F011
#define ICON_ERASER         "\xEF\x80\x92"  // F012
#define ICON_ERASER1        "\xEF\x80\x93"  // F013
#define ICON_DISTRIBUTE     "\xEF\x80\x94"  // F014
#define ICON_DISTRIBUTE1    "\xEF\x80\x95"  // F015
#define ICON_DISTRIBUTE2    "\xEF\x80\x96"  // F016
#define ICON_DISTRIBUTE3    "\xEF\x80\x97"  // F017
#define ICON_DISTRIBUTE4    "\xEF\x80\x98"  // F018
#define ICON_DISTRIBUTE5    "\xEF\x80\x99"  // F019
#define ICON_DISTRIBUTE6    "\xEF\x80\x9A"  // F01A
#define ICON_DISTRIBUTE7    "\xEF\x80\x9B"  // F01B
#define ICON_DISTRIBUTE8    "\xEF\x80\x9C"  // F01C
#define ICON_DISTRIBUTE9    "\xEF\x80\x9D"  // F01D
#define ICON_DISTRIBUTE10   "\xEF\x80\x9E"  // F01E
#define ICON_DISTRIBUTE11   "\xEF\x80\x9F"  // F01F
#define ICON_DISTRIBUTE12   "\xEF\x80\xA0"  // F020
#define ICON_DISTRIBUTE13   "\xEF\x80\xA1"  // F021
#define ICON_DISTRIBUTE14   "\xEF\x80\xA2"  // F022
#define ICON_DISTRIBUTE15   "\xEF\x80\xA3"  // F023
#define ICON_CUBE           "\xEF\x80\xA4"  // F024
#define ICON_CUBE1          "\xEF\x80\xA5"  // F025
#define ICON_CUBE2          "\xEF\x80\xA6"  // F026
#define ICON_CROP           "\xEF\x80\xA7"  // F027
#define ICON_CAMERA         "\xEF\x80\xA8"  // F028
#define ICON_CAMERA1        "\xEF\x80\xA9"  // F029
#define ICON_ARROW          "\xEF\x80\xAA"  // F02A
#define ICON_ARROW1         "\xEF\x80\xAB"  // F02B
#define ICON_ALIGN          "\xEF\x80\xAC"  // F02C
#define ICON_ALIGN1         "\xEF\x80\xAD"  // F02D
#define ICON_ALIGN2         "\xEF\x80\xAE"  // F02E
#define ICON_ALIGN3         "\xEF\x80\xAF"  // F02F
#define ICON_ALIGN4         "\xEF\x80\xB0"  // F030
#define ICON_ALIGN5         "\xEF\x80\xB1"  // F031
#define ICON_ALIGN6         "\xEF\x80\xB2"  // F032
#define ICON_ALIGN7         "\xEF\x80\xB3"  // F033
#define ICON_ALIGN8         "\xEF\x80\xB4"  // F034
#define ICON_ALIGN9         "\xEF\x80\xB5"  // F035
#define ICON_ALIGN10        "\xEF\x80\xB6"  // F036
#define ICON_ALIGN11        "\xEF\x80\xB7"  // F037
