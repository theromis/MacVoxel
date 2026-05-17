cmake_minimum_required(VERSION 3.24)

# macOS settings must be set before project()
# 14.0 (Sonoma) is the floor: SwiftUI shell uses @Observable + the
# Observation framework, both of which are 14+.
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS deployment target")

project(MacVoxel
    VERSION 0.1.0
    DESCRIPTION "Native macOS voxel editor"
    LANGUAGES C CXX OBJC OBJCXX Swift)

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
# Application target
# ---------------------------------------------------------------------------
set(APP_NAME "MacVoxel")

set(APP_SOURCES
    src/main.mm
    src/Camera.cpp
    src/CliRender.mm
    src/RaycastRenderer.mm
    src/PathTraceRenderer.mm
    src/SceneOverlayRenderer.mm
    src/VoxelGrid.cpp
    src/VoxelVolume.cpp
    src/VolumeTexture.mm
    src/BrushEngine.mm
    src/ShapeEngine.mm
    src/Palette.cpp
    src/VoxFile.cpp
    src/Raycast.cpp
    src/Shapes.cpp
    src/GeneratorEngine.mm
    src/EditEngine.mm
    src/EditHistory.cpp
    src/Selection.cpp
    src/SelectionOps.cpp
    src/SelectionOverlay.cpp
    src/FloatingBufferOps.cpp
    src/EditorContext.cpp
    src/ViewContext.cpp
    src/BoxSelectController.cpp
    src/BrushTool.cpp
    src/FaceController.cpp
    src/FloodSelectController.cpp
    src/GeneratorController.cpp
    src/MarqueeController.cpp
    src/MetalScene.mm
    src/MoveSelectController.cpp
    src/OverlayDraw.cpp
    src/ShapeController.cpp
    src/XformHandleController.cpp
    # SwiftUI shell — Obj-C++ bridge over EditorContext. Swift code in
    # APP_SWIFT_SOURCES below.
    src/swift/EditorContextBridge.mm
)

# SwiftUI shell. Bridging header (MacVoxel-Bridging-Header.h) exposes
# the Obj-C interface of EditorContextBridge to Swift; pure C++ types
# never cross the Swift boundary.
set(APP_SWIFT_SOURCES
    src/swift/MainEntry.swift
    src/swift/MacVoxelApp.swift
    src/swift/MacVoxelCommands.swift
    src/swift/ContentView.swift
    src/swift/MetalSceneView.swift
    src/swift/EditorState.swift
    src/swift/panels/GeneratorPanel.swift
    src/swift/panels/LightPanel.swift
    src/swift/panels/ModelPanel.swift
    src/swift/panels/PalettePanel.swift
    src/swift/panels/RenderPanel.swift
    src/swift/panels/SelectionPanel.swift
    src/swift/panels/ToolPanel.swift
)

set(APP_RESOURCES
    resources/SF-Symbols-Export.ttf
    resources/default.vox
    src/BrushKernel.metal
    src/Generators.metal
    src/ShapeKernel.metal
    src/Overlay.metal
    src/PathTrace.metal
)
set_source_files_properties(${APP_RESOURCES}
    PROPERTIES MACOSX_PACKAGE_LOCATION Resources)

add_executable(${APP_NAME} MACOSX_BUNDLE
    ${APP_SOURCES}
    ${APP_SWIFT_SOURCES}
    ${APP_RESOURCES}
)

set_target_properties(${APP_NAME} PROPERTIES
    Swift_LANGUAGE_VERSION 5
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

target_include_directories(${APP_NAME} PRIVATE src)

# Warnings as errors for project sources.
target_compile_options(${APP_NAME} PRIVATE
    $<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wall -Wextra -Wpedantic -Werror>
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

# ARC for Obj-C++.
target_compile_options(${APP_NAME} PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
)

# Swift sees the Obj-C side of the app via a bridging header. Pure C++
# types never reach Swift — Obj-C++ wrappers (EditorContextBridge.mm)
# do the translation.
target_compile_options(${APP_NAME} PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:-import-objc-header>"
    "$<$<COMPILE_LANGUAGE:Swift>:${CMAKE_SOURCE_DIR}/src/swift/MacVoxel-Bridging-Header.h>"
)
