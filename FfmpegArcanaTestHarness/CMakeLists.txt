cmake_minimum_required(VERSION 3.20)
project(FfmpegArcanaTestHarness LANGUAGES C CXX Swift)

set(CMAKE_Swift_LANGUAGE_VERSION 5)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS version")

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Debug)
endif()

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

# Path to FfmpegArcana package
set(FFMPEG_ARCANA_ROOT "${CMAKE_SOURCE_DIR}/../FfmpegArcana" CACHE PATH "Path to FfmpegArcana package")

# Path to FFmpeg xcframework
set(FFMPEG_ROOT "${CMAKE_SOURCE_DIR}/../Frameworks" CACHE PATH "Path to FFmpeg frameworks")

# Verify paths
if(NOT EXISTS "${FFMPEG_ARCANA_ROOT}/Package.swift")
    message(FATAL_ERROR "FfmpegArcana not found at: ${FFMPEG_ARCANA_ROOT}")
endif()

# Find FFmpeg framework
set(XCFRAMEWORK_SLICES "macos-arm64" "macos-arm64_x86_64" "macos-x86_64")
set(FFMPEG_FOUND FALSE)

foreach(slice ${XCFRAMEWORK_SLICES})
    set(fw_path "${FFMPEG_ROOT}/FFmpeg.xcframework/${slice}/FFmpeg.framework")
    if(EXISTS "${fw_path}")
        message(STATUS "Found FFmpeg: ${fw_path}")
        set(FFMPEG_FRAMEWORK_PATH "${fw_path}")
        set(FFMPEG_INCLUDE_DIR "${fw_path}/Headers")
        set(FFMPEG_FOUND TRUE)
        break()
    endif()
endforeach()

if(NOT FFMPEG_FOUND)
    message(FATAL_ERROR "FFmpeg.xcframework not found in ${FFMPEG_ROOT}")
endif()

# ------------------------------------------------------------------------------
# Build CFfmpegWrapper from the package (C and C++ sources)
# ------------------------------------------------------------------------------
add_library(CFfmpegWrapper STATIC
    ${FFMPEG_ARCANA_ROOT}/Sources/CFfmpegWrapper/ffmpeg_wrapper.c
    ${FFMPEG_ARCANA_ROOT}/Sources/CFfmpegWrapper/ff_cmd.cpp
    ${FFMPEG_ARCANA_ROOT}/Sources/CFfmpegWrapper/fifo/default_semaphore_impl.cpp
)

target_include_directories(CFfmpegWrapper PUBLIC
    ${FFMPEG_ARCANA_ROOT}/Sources/CFfmpegWrapper/include
    ${FFMPEG_ARCANA_ROOT}/Sources/CFfmpegWrapper
    ${FFMPEG_INCLUDE_DIR}
    ${FFMPEG_INCLUDE_DIR}/arcana
)

target_compile_options(CFfmpegWrapper PUBLIC
    "-F${FFMPEG_FRAMEWORK_PATH}/.."
)

target_link_options(CFfmpegWrapper PUBLIC
    "-F${FFMPEG_FRAMEWORK_PATH}/.."
    "-framework" "FFmpeg"
)

target_link_libraries(CFfmpegWrapper PUBLIC
    "-framework CoreMedia"
    "-framework CoreVideo"
    "-framework VideoToolbox"
    "-framework CoreFoundation"
    "-framework CoreAudio"
    "-framework AudioToolbox"
    "-framework Security"
    "-framework AVFoundation"
    "-lz" "-lbz2" "-liconv" "-lc++"
)

# ------------------------------------------------------------------------------
# Build FfmpegArcana Swift library
# ------------------------------------------------------------------------------
add_library(FfmpegArcana STATIC
    ${FFMPEG_ARCANA_ROOT}/Sources/FfmpegArcana/FfmpegArcana.swift
    ${FFMPEG_ARCANA_ROOT}/Sources/FfmpegArcana/VideoDecoder.swift
    ${FFMPEG_ARCANA_ROOT}/Sources/FfmpegArcana/CmdFifo.swift
)

target_compile_options(FfmpegArcana PRIVATE
    "SHELL:-I ${FFMPEG_ARCANA_ROOT}/Sources/CFfmpegWrapper/include"
    "SHELL:-Xcc -I${FFMPEG_ARCANA_ROOT}/Sources/CFfmpegWrapper/include"
    "SHELL:-Xcc -I${FFMPEG_INCLUDE_DIR}"
    "SHELL:-Xcc -I${FFMPEG_INCLUDE_DIR}/arcana"
)

target_link_libraries(FfmpegArcana PUBLIC CFfmpegWrapper)

# ------------------------------------------------------------------------------
# Test harness executable
# ------------------------------------------------------------------------------
add_executable(fftest main.swift)

target_compile_options(fftest PRIVATE
    "SHELL:-I ${FFMPEG_ARCANA_ROOT}/Sources/CFfmpegWrapper/include"
    "SHELL:-Xcc -I${FFMPEG_ARCANA_ROOT}/Sources/CFfmpegWrapper/include"
    "SHELL:-Xcc -I${FFMPEG_INCLUDE_DIR}"
    "SHELL:-Xcc -I${FFMPEG_INCLUDE_DIR}/arcana"
)

target_link_libraries(fftest PRIVATE FfmpegArcana)

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
message(STATUS "")
message(STATUS "=== Test Harness Configuration ===")
message(STATUS "FfmpegArcana: ${FFMPEG_ARCANA_ROOT}")
message(STATUS "FFmpeg: ${FFMPEG_FRAMEWORK_PATH}")
message(STATUS "Output: ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}")
message(STATUS "")
