cmake_minimum_required(VERSION 3.24)

# macOS settings must be set before project()
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum macOS deployment target")

project(MacVoxel
    VERSION 0.1.0
    DESCRIPTION "Native macOS voxel editor"
    LANGUAGES C CXX OBJC OBJCXX)

if(NOT APPLE)
    message(FATAL_ERROR "MacVoxel is macOS-only.")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Same standard for Obj-C++ so .mm files compile with C++20
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

# Export compile_commands.json for clangd
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# ---------------------------------------------------------------------------
# ImGui submodule
# ---------------------------------------------------------------------------
set(IMGUI_DIR "${CMAKE_SOURCE_DIR}/third_party/imgui")
if(NOT EXISTS "${IMGUI_DIR}/imgui.h")
    message(FATAL_ERROR
        "Dear ImGui submodule not found at ${IMGUI_DIR}. "
        "Run: git submodule update --init --recursive")
endif()

set(IMGUI_SOURCES
    "${IMGUI_DIR}/imgui.cpp"
    "${IMGUI_DIR}/imgui_draw.cpp"
    "${IMGUI_DIR}/imgui_tables.cpp"
    "${IMGUI_DIR}/imgui_widgets.cpp"
    "${IMGUI_DIR}/imgui_demo.cpp"
    "${IMGUI_DIR}/backends/imgui_impl_metal.mm"
    "${IMGUI_DIR}/backends/imgui_impl_osx.mm"
)

# ---------------------------------------------------------------------------
# Application target
# ---------------------------------------------------------------------------
set(APP_NAME "MacVoxel")

set(APP_SOURCES
    src/main.mm
    src/AppDelegate.mm
    src/VoxelView.mm
    src/Camera.cpp
    src/RaycastRenderer.mm
    src/PathTraceRenderer.mm
    src/RenderState.cpp
    src/VoxelGrid.cpp
    src/Palette.cpp
    src/VoxFile.cpp
    src/Raycast.cpp
    src/ToolState.cpp
    src/EditHistory.cpp
    src/Selection.cpp
    src/Clipboard.cpp
    src/ui/ModelPanel.cpp
    src/ui/ToolPanel.cpp
    src/ui/PalettePanel.cpp
    src/ui/Fonts.cpp
    src/ui/Theme.cpp
)

# Source files referenced in CMakeLists must exist for configure to succeed.
# Step 2 only ships main.mm; touch placeholders so later steps can fill them in.
foreach(_src IN ITEMS src/AppDelegate.mm src/VoxelView.mm src/Camera.cpp
                       src/ui/ModelPanel.cpp)
    if(NOT EXISTS "${CMAKE_SOURCE_DIR}/${_src}")
        file(WRITE "${CMAKE_SOURCE_DIR}/${_src}" "// placeholder - filled in by a later step\n")
    endif()
endforeach()

add_executable(${APP_NAME} MACOSX_BUNDLE
    ${APP_SOURCES}
    ${IMGUI_SOURCES}
)

set_target_properties(${APP_NAME} PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST          "${CMAKE_SOURCE_DIR}/resources/Info.plist.in"
    MACOSX_BUNDLE_BUNDLE_NAME         "${APP_NAME}"
    MACOSX_BUNDLE_EXECUTABLE_NAME     "${APP_NAME}"
    MACOSX_BUNDLE_GUI_IDENTIFIER      "dev.paulstarr.MacVoxel"
    MACOSX_BUNDLE_BUNDLE_VERSION      "${PROJECT_VERSION}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
)

target_include_directories(${APP_NAME} PRIVATE
    src
    "${IMGUI_DIR}"
    "${IMGUI_DIR}/backends"
)

# Project sources: warnings as errors. Third-party (ImGui) compiled cleanly.
target_compile_options(${APP_NAME} PRIVATE
    $<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wall -Wextra -Wpedantic -Werror>
)

# Relax warnings for ImGui sources only.
set_source_files_properties(${IMGUI_SOURCES} PROPERTIES
    COMPILE_OPTIONS "-Wno-everything"
)

# Frameworks
find_library(COCOA_LIBRARY     Cocoa     REQUIRED)
find_library(METAL_LIBRARY     Metal     REQUIRED)
find_library(METALKIT_LIBRARY  MetalKit  REQUIRED)
find_library(QUARTZCORE_LIBRARY QuartzCore REQUIRED)
find_library(GAMECONTROLLER_LIBRARY GameController REQUIRED)
find_library(UTI_LIBRARY UniformTypeIdentifiers REQUIRED)

target_link_libraries(${APP_NAME} PRIVATE
    ${COCOA_LIBRARY}
    ${METAL_LIBRARY}
    ${METALKIT_LIBRARY}
    ${QUARTZCORE_LIBRARY}
    ${GAMECONTROLLER_LIBRARY}
    ${UTI_LIBRARY}
)

# ARC for Obj-C++. ImGui's backends are written ARC-compatible upstream.
target_compile_options(${APP_NAME} PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
)
