#!/usr/bin/env bash
#
# build-apple.sh
#
# Build ffmpeg-arcana + deps as static libs for Apple platforms (arm64-only):
#   iOS / tvOS / macOS / Mac-Catalyst + simulators (arm64 simulators)
# Produces a single XCFramework with slices per platform.
#
# Copyright (c) 2025
#

set -euo pipefail

# -----------------------------------------------------------------------------
# Versions & global config
# -----------------------------------------------------------------------------
MIN_IOS_VERSION="14.0"
MIN_TVOS_VERSION="14.0"
MIN_MACOS_VERSION="14.0"

FDK_AAC_VERSION="v2.0.3"
OPUS_VERSION="v1.5.2"
OPENSSL_VERSION="openssl-3.3.0"
SRT_VERSION="v1.5.4"
RIST_VERSION="v0.2.10"
MBEDTLS_VERSION="v3.6.0"
CJSON_VERSION="v1.7.17"
FFMPEG_ARCANA_PATCH_VERSION="8.0"
FFMPEG_VERSION="8.0"
FRAMEWORK_NAME="FFmpeg"

# -----------------------------------------------------------------------------
# Platform matrix (arm64 only)
# -----------------------------------------------------------------------------
PLATFORMS=(
  ios_device
  macos
  # ios_sim
  # tvos_device
  # tvos_sim
)

# -----------------------------------------------------------------------------
# CLI / usage
# -----------------------------------------------------------------------------
usage() {
  echo "Usage: $0 [options] <install_prefix>"
  echo "Options:"
  echo "  -s <path>  Use a local directory for ffmpeg-arcana source instead of cloning."
  echo "  -h         Show this help."
  exit 0
}

FFMPEG_ARCANA_LOCAL_SRC=""
while getopts "hs:" opt; do
  case ${opt} in
    h) usage ;;
    s) FFMPEG_ARCANA_LOCAL_SRC=$OPTARG ;;
    *) usage ;;
  esac
done
shift $((OPTIND -1))

if [ -z "${1:-}" ]; then
  echo "Error: You must specify an install prefix directory." >&2
  usage
fi

resolve_path() {
  case "$1" in
    /*) printf "%s\n" "$1" ;;
    ~*) printf "%s\n" "${1/#\~/$HOME}" ;;
    *)  printf "%s\n" "$(pwd -P)/$1" ;;
  esac
}

INSTALL_PREFIX="$(resolve_path "$1")"

# -----------------------------------------------------------------------------
# Tool checks & layout
# -----------------------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo >&2 "$1 is required."; exit 1; }; }
for t in git cmake nasm meson ninja autoconf automake libtool xcrun sed; do need "$t"; done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="$SCRIPT_DIR/build_apple"
SRC_ROOT="$SCRIPT_DIR/src_apple"

mkdir -p "$BUILD_ROOT" "$SRC_ROOT" "$INSTALL_PREFIX"

# -----------------------------------------------------------------------------
# ffmpeg-arcana source
# -----------------------------------------------------------------------------
if [ -n "${FFMPEG_ARCANA_LOCAL_SRC:-}" ]; then
  FFMPEG_ARCANA_SRC_DIR="$(resolve_path "$FFMPEG_ARCANA_LOCAL_SRC")"
  [ -d "$FFMPEG_ARCANA_SRC_DIR" ] || { echo "Invalid arcana dir: $FFMPEG_ARCANA_SRC_DIR"; exit 1; }
else
  FFMPEG_ARCANA_SRC_DIR="$SRC_ROOT/ffmpeg-arcana"
  if [ ! -d "$FFMPEG_ARCANA_SRC_DIR/.git" ]; then
    git clone https://github.com/richinsley/ffmpeg-arcana.git "$FFMPEG_ARCANA_SRC_DIR"
  else
    (cd "$FFMPEG_ARCANA_SRC_DIR" && git pull --ff-only)
  fi
fi

# -----------------------------------------------------------------------------
# Platform & Toolchain Helpers
# -----------------------------------------------------------------------------
platform_info() {
  local p="$1"
  case "$p" in
    ios_device)  echo "iphoneos arm64 -miphoneos-version-min $MIN_IOS_VERSION arm64-apple-ios iphoneos ios-arm64 ios64-cross 0" ;;
    ios_sim)     echo "iphonesimulator arm64 -mios-simulator-version-min $MIN_IOS_VERSION arm64-apple-ios-simulator iphonesimulator ios-arm64-simulator iossimulator-arm64-xcrun 1" ;;
    tvos_device) echo "appletvos arm64 -mtvos-version-min $MIN_TVOS_VERSION arm64-apple-tvos appletvos tvos-arm64 ios64-cross 0" ;;
    tvos_sim)    echo "appletvsimulator arm64 -mtvos-simulator-version-min $MIN_TVOS_VERSION arm64-apple-tvos-simulator appletvsimulator tvos-arm64-simulator iossimulator-arm64-xcrun 1" ;;
    macos)       echo "macosx arm64 -mmacosx-version-min $MIN_MACOS_VERSION arm64-apple-macosx macosx macos-arm64 darwin64-arm64-cc 0" ;;
    maccatalyst) echo "macosx arm64 -miphoneos-version-min $MIN_IOS_VERSION arm64-apple-ios-macabi macosx maccatalyst-arm64 iossimulator-arm64-xcrun 1" ;;
    *) echo "Unknown platform: $p" >&2; exit 1;;
  esac
}

setup_env_for_platform() {
  local plat="$1"
  local SDK ARCH MINFLAG MINVER TARGETTRIPLE
  read -r SDK ARCH MINFLAG MINVER TARGETTRIPLE _ _ _ NEEDTARGET < <(platform_info "$plat")
  export SDKPATH; SDKPATH="$(xcrun --sdk "$SDK" --show-sdk-path)"

  export CC="$(xcrun --sdk "$SDK" --find clang)"
  export CXX="$CC++"
  export HOST="aarch64-apple-darwin"

  # Remove '-fembed-bitcode' as it's deprecated in Xcode 14+
  local BASE_FLAGS="-arch $ARCH -isysroot $SDKPATH $MINFLAG=$MINVER"
  [ "${NEEDTARGET:-0}" = "1" ] && BASE_FLAGS="$BASE_FLAGS -target $TARGETTRIPLE"
  [[ "$TARGETTRIPLE" == *"-macabi" ]] && BASE_FLAGS="$BASE_FLAGS -mios-version-min=${MINVER}"

  export CFLAGS="$BASE_FLAGS"
  export CXXFLAGS="$BASE_FLAGS -std=c++11"
  export LDFLAGS="$BASE_FLAGS"
  export PKG_CONFIG_SYSROOT_DIR="$SDKPATH"
}
unset_env() { unset CC CXX CFLAGS CXXFLAGS LDFLAGS HOST SDKPATH PKG_CONFIG_SYSROOT_DIR CGO_CFLAGS CGO_LDFLAGS; }

# -----------------------------------------------------------------------------
# Fetch helpers (one-time)
# -----------------------------------------------------------------------------
fetch_git_once() {
  local url="$1" dir="$2" ref="$3"
  if [ ! -d "$dir/.git" ]; then git clone "$url" "$dir"; fi
  (cd "$dir" && git fetch --tags && git checkout "$ref")
}

fetch_git_once https://github.com/mstorsjo/fdk-aac.git  "$SRC_ROOT/fdk-aac"  "$FDK_AAC_VERSION"
fetch_git_once https://github.com/xiph/opus.git         "$SRC_ROOT/opus"     "$OPUS_VERSION"
fetch_git_once https://github.com/openssl/openssl.git   "$SRC_ROOT/openssl"  "$OPENSSL_VERSION"
fetch_git_once https://github.com/Haivision/srt.git     "$SRC_ROOT/srt"      "$SRT_VERSION"
fetch_git_once https://github.com/Mbed-TLS/mbedtls.git  "$SRC_ROOT/mbedtls"  "$MBEDTLS_VERSION"
( cd "$SRC_ROOT/mbedtls" && git submodule update --init --recursive )
fetch_git_once https://github.com/DaveGamble/cJSON.git   "$SRC_ROOT/cjson"    "$CJSON_VERSION"
fetch_git_once https://code.videolan.org/rist/librist.git "$SRC_ROOT/librist" "$RIST_VERSION"

# -----------------------------------------------------------------------------
# Build functions (Assume environment is already set)
# -----------------------------------------------------------------------------
_NCPU="$(sysctl -n hw.ncpu)"

build_autotools() {
  local prefix="$1" srcdir="$2"; shift 2
  echo "--- Building $(basename "$srcdir") (autotools) ---"
  pushd "$srcdir" >/dev/null
  [[ ! -f configure ]] && ./autogen.sh >/dev/null
  ./configure --host="$HOST" --prefix="$prefix" "$@"
  make -j"$_NCPU" && make install && make clean
  popd >/dev/null
}

build_cmake() {
  local plat="$1" prefix="$2" srcdir="$3"; shift 3
  echo "--- Building $(basename "$srcdir") (cmake) ---"
  local BDIR="$BUILD_ROOT/$(basename "$srcdir")/$plat"
  rm -rf "$BDIR"; mkdir -p "$BDIR"

  local CMAKE_TOOLCHAIN="$BDIR/toolchain.cmake"
  local SYSNAME="Darwin"
  local SDK; read -r SDK _ < <(platform_info "$plat")
  case "$SDK" in iphoneos|iphonesimulator) SYSNAME="iOS" ;; appletvos|appletvsimulator) SYSNAME="tvOS" ;; esac
  [[ "$plat" == "maccatalyst" ]] && SYSNAME="iOS"

  cat > "$CMAKE_TOOLCHAIN" <<EOF
set(CMAKE_SYSTEM_NAME ${SYSNAME})
set(CMAKE_OSX_SYSROOT "${SDKPATH}")
set(CMAKE_C_COMPILER "${CC}")
set(CMAKE_CXX_COMPILER "${CXX}")
set(CMAKE_C_FLAGS "${CFLAGS}")
set(CMAKE_CXX_FLAGS "${CXXFLAGS}")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
EOF

  pushd "$BDIR" >/dev/null
  cmake "$srcdir" -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN" -DCMAKE_INSTALL_PREFIX="$prefix" "$@"
  cmake --build . --target install --config Release
  popd >/dev/null
}

build_meson() {
  local plat="$1" prefix="$2" srcdir="$3"; shift 3
  echo "--- Building $(basename "$srcdir") (meson) ---"
  local BDIR="$BUILD_ROOT/$(basename "$srcdir")/$plat"
  rm -rf "$BDIR"; mkdir -p "$BDIR"

  local MESON_CROSS_FILE="$BDIR/cross.txt"
  cat > "$MESON_CROSS_FILE" <<EOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '$(xcrun --find ar)'
strip = '$(xcrun --find strip)'
pkg-config = 'pkg-config'
[properties]
needs_exe_wrapper = true
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = '$HOST'
endian = 'little'
[built-in options]
c_args = '${CFLAGS}'
cpp_args = '${CXXFLAGS}'
c_link_args = '${LDFLAGS}'
cpp_link_args = '${LDFLAGS}'
EOF

  meson setup "$BDIR" "$srcdir" --cross-file="$MESON_CROSS_FILE" --prefix="$prefix" "$@"
  ninja -C "$BDIR" install
}

build_openssl() {
  local plat="$1" prefix="$2"
  echo "--- Building openssl ---"
  local OPENSSL_TGT; read -r _ _ _ _ _ _ _ OPENSSL_TGT _ < <(platform_info "$plat")
  pushd "$SRC_ROOT/openssl" >/dev/null
  make clean >/dev/null 2>&1 || true
  ./Configure "$OPENSSL_TGT" no-shared no-tests no-apps --prefix="$prefix"
  make -j"$_NCPU" >/dev/null && make install_sw >/dev/null && make clean >/dev/null
  popd >/dev/null
}

apply_catalyst_videotoolbox_patch() {
  mkdir -p /tmp/arcanapatches

  echo "Creating Catalyst VideoToolbox patch..."
  
  # Create patch
  cat > /tmp/arcanapatches/catalyst_vt.patch <<'EOF'
diff --git a/libavcodec/videotoolbox.c b/libavcodec/videotoolbox.c
index ccba249140..89f75a6ac3 100644
--- a/libavcodec/videotoolbox.c
+++ b/libavcodec/videotoolbox.c
@@ -817,10 +817,24 @@ static CFDictionaryRef videotoolbox_buffer_attributes_create(int width,
     CFDictionarySetValue(buffer_attributes, kCVPixelBufferIOSurfacePropertiesKey, io_surface_properties);
     CFDictionarySetValue(buffer_attributes, kCVPixelBufferWidthKey, w);
     CFDictionarySetValue(buffer_attributes, kCVPixelBufferHeightKey, h);
-#if TARGET_OS_IPHONE
-    CFDictionarySetValue(buffer_attributes, kCVPixelBufferOpenGLESCompatibilityKey, kCFBooleanTrue);
+#if TARGET_OS_MACCATALYST
+    // Use Metal for Catalyst
+    CFDictionarySetValue(buffer_attributes,
+                         kCVPixelBufferMetalCompatibilityKey,
+                         kCFBooleanTrue);
+#elif TARGET_ABI_USES_IOS_VALUES
+    CFDictionarySetValue(buffer_attributes, 
+                         kCVPixelBufferMetalCompatibilityKey, 
+                         kCFBooleanTrue);
+#elif TARGET_OS_OSX
+    // For modern macOS, prefer Metal over deprecated OpenGL
+    CFDictionarySetValue(buffer_attributes,
+                         kCVPixelBufferMetalCompatibilityKey,
+                         kCFBooleanTrue);
 #else
-    CFDictionarySetValue(buffer_attributes, kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey, kCFBooleanTrue);
+    CFDictionarySetValue(buffer_attributes, 
+                         kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey, 
+                         kCFBooleanTrue);
 #endif
 
     CFRelease(io_surface_properties);

EOF
}

build_ffmpeg_arcana() {
    local plat="$1" prefix="$2"
    echo "--- Building ffmpeg-arcana for $plat ---"
    
    local SDK ARCH
    read -r SDK ARCH _ < <(platform_info "$plat")

    # Start with the global CFLAGS we've already set up.
    local FFMPEG_CFLAGS="$CFLAGS"
    local FFMPEG_LDFLAGS="$LDFLAGS"

    # Find all subdirectories in our dependency include folder (e.g., include/opus, include/srt)
    # and automatically generate "-I" flags for each one.
    if [ -d "${prefix}/include" ]; then
        local SUBDIR_INCLUDES
        SUBDIR_INCLUDES=$(find "${prefix}/include" -maxdepth 1 -mindepth 1 -type d | sed 's/^/-I/')
        FFMPEG_CFLAGS="$FFMPEG_CFLAGS $(echo "$SUBDIR_INCLUDES" | tr '\n' ' ')"
    fi
    
    # Since SRT is a C++ library, all platforms need to link against the C++ standard library.
    FFMPEG_LDFLAGS="$FFMPEG_LDFLAGS -lc++"

    local BDIR="$BUILD_ROOT/ffmpeg-arcana/$plat"
    rm -rf "$BDIR"; mkdir -p "$BDIR"; pushd "$BDIR" >/dev/null

    echo "Final CFLAGS for FFmpeg: $FFMPEG_CFLAGS"

    cmake "$FFMPEG_ARCANA_SRC_DIR" \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DARCANA_PATCH_VERSION="$FFMPEG_ARCANA_PATCH_VERSION" \
        -DFFMPEG_VERSION="$FFMPEG_VERSION" \
        -DFFOPT_enable-cross-compile=true \
        -DFFOPT_target-os=darwin \
        -DFFOPT_cc="$CC" \
        -DFFOPT_arch="$ARCH" \
        -DFFOPT_extra-cflags="$FFMPEG_CFLAGS" \
        -DFFOPT_extra-ldflags="$FFMPEG_LDFLAGS" \
        -DFFOPT_enable-static=true \
        -DFFOPT_disable-shared=true \
        -DFFOPT_disable-programs=true \
        -DFFOPT_disable-doc=true \
        -DFFOPT_enable-pic=true \
        -DFFOPT_enable-gpl=true \
        -DFFOPT_enable-nonfree=true \
        -DFFOPT_enable-pthreads=true \
        -DFFOPT_enable-libfdk-aac=true \
        -DFFOPT_enable-libopus=true \
        -DFFOPT_enable-librist=true \
        -DFFOPT_enable-libsrt=true \
        -DFFOPT_enable-openssl=true \
        -DFFOPT_disable-opengl=true \
        -DFFOPT_disable-coreimage=true \
        -DFFMPEG_PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
        -DADDITIONAL_PATCHES=/tmp/arcanapatches \
        -DFFOPT_pkg-config-flags=--static

    cmake --build . --target install --config Release
    popd >/dev/null
}

# create patches
apply_catalyst_videotoolbox_patch

# -----------------------------------------------------------------------------
# Build loop
# -----------------------------------------------------------------------------
for P in "${PLATFORMS[@]}"; do
  echo -e "\n\n==== Configuring build for $P ===="
  ARCH_PREFIX="$INSTALL_PREFIX/$P"
  mkdir -p "$ARCH_PREFIX"
  export PKG_CONFIG_PATH="$ARCH_PREFIX/lib/pkgconfig"

  # Set the environment variables ONCE for this entire platform build
  setup_env_for_platform "$P"

  # Add our custom dependency paths to the compiler and linker flags
  export CFLAGS="$CFLAGS -I$ARCH_PREFIX/include"
  export LDFLAGS="$LDFLAGS -L$ARCH_PREFIX/lib"

  # For cgo builds (pion webrtc), set these as well (mirror CFLAGS/LDFLAGS)
  export CGO_CFLAGS="$CFLAGS"
  export CGO_LDFLAGS="$LDFLAGS"

  # Build all dependencies using the configured environment
  build_openssl "$P" "$ARCH_PREFIX"
  build_autotools "$ARCH_PREFIX" "$SRC_ROOT/fdk-aac" --enable-static --disable-shared
  build_autotools "$ARCH_PREFIX" "$SRC_ROOT/opus" --enable-static --disable-shared --disable-doc --disable-extra-programs
  build_cmake "$P" "$ARCH_PREFIX" "$SRC_ROOT/srt" -DCMAKE_BUILD_TYPE=Release -DENABLE_SHARED=OFF -DENABLE_APPS=OFF -DOPENSSL_USE_STATIC_LIBS=TRUE -DOPENSSL_ROOT_DIR="$ARCH_PREFIX" -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  build_cmake "$P" "$ARCH_PREFIX" "$SRC_ROOT/mbedtls" -DUSE_SHARED_MBEDTLS_LIBRARY=OFF -DUSE_STATIC_MBEDTLS_LIBRARY=ON -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF
  build_cmake "$P" "$ARCH_PREFIX" "$SRC_ROOT/cjson" -DBUILD_SHARED_LIBS=OFF -DENABLE_CJSON_TEST=OFF -DENABLE_CJSON_UTILS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  build_meson "$P" "$ARCH_PREFIX" "$SRC_ROOT/librist" --default-library=static --buildtype=release -Dtest=false -Dbuilt_tools=false
  build_ffmpeg_arcana "$P" "$ARCH_PREFIX"

  # Unset the environment variables now that we're done with this platform
  unset_env
done

# -----------------------------------------------------------------------------
# XCFramework
# -----------------------------------------------------------------------------
create_xcframework() {
  local FWROOT="$INSTALL_PREFIX/frameworks"
  local OUT="$INSTALL_PREFIX/$FRAMEWORK_NAME.xcframework"
  rm -rf "$FWROOT" "$OUT"; mkdir -p "$FWROOT"
  local ARGS=()

  echo -e "\n\n==== Creating $FRAMEWORK_NAME.xcframework ===="

  for P in "${PLATFORMS[@]}"; do
    local MINVER; read -r _ _ _ MINVER _ < <(platform_info "$P")
    
    local SLICE
    case "$P" in
      ios_device) SLICE="ios-arm64" ;;
      ios_sim) SLICE="ios-arm64-simulator" ;;
      tvos_device) SLICE="tvos-arm64" ;;
      tvos_sim) SLICE="tvos-arm64-simulator" ;;
      macos) SLICE="macos-arm64" ;;
      maccatalyst) SLICE="ios-arm64-maccatalyst" ;;
    esac

    local PREFIX="$INSTALL_PREFIX/$P"
    local FWPATH="$FWROOT/$SLICE/$FRAMEWORK_NAME.framework"

    # --- Create the Info.plist content first, as it's needed in both cases ---
    local PLAT_PLIST_SDK="MacOSX"
    case "$P" in *ios*) PLAT_PLIST_SDK="iPhoneOS" ;; *tvos*) PLAT_PLIST_SDK="AppleTVOS" ;; esac
    [[ "$P" == "ios_sim" ]] && PLAT_PLIST_SDK="iPhoneSimulator"
    [[ "$P" == "tvos_sim" ]] && PLAT_PLIST_SDK="AppleTVSimulator"

    local PLIST_CONTENT
    PLIST_CONTENT=$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$FRAMEWORK_NAME</string>
  <key>CFBundleIdentifier</key><string>org.ffmpeg.$FRAMEWORK_NAME</string>
  <key>CFBundleName</key><string>$FRAMEWORK_NAME</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$PLAT_PLIST_SDK</string></array>
  <key>MinimumOSVersion</key><string>$MINVER</string>
</dict></plist>
EOF
)

    # --- Create the umbrella header and module map content ---
    local UMBRELLA_HEADER_CONTENT
    UMBRELLA_HEADER_CONTENT=$(cat <<EOF
#import <Foundation/Foundation.h>
#import <libavcodec/avcodec.h>
#import <libavformat/avformat.h>
#import <libavutil/avutil.h>
#import <libswscale/swscale.h>
#import <libswresample/swresample.h>
#import <libavfilter/avfilter.h>
EOF
)

    local MODULE_MAP_CONTENT
    MODULE_MAP_CONTENT=$(cat <<EOF
framework module $FRAMEWORK_NAME {
  umbrella header "$FRAMEWORK_NAME.h"
  export *
  module * { export * }
}
EOF
)
    # --- Platform-dependent structure generation ---
    if [[ "$P" == "macos" ]]; then
      # --- MACOS (NON-SHALLOW) ---
      echo "  -> Assembling non-shallow slice for macOS: $SLICE"
      mkdir -p "$FWPATH/Versions/A/Headers" "$FWPATH/Versions/A/Modules" "$FWPATH/Versions/A/Resources"
      
      echo "  -> Combining $(ls -1 "$PREFIX"/lib/*.a | wc -l | tr -d ' ') static libraries..."
      libtool -static -o "$FWPATH/Versions/A/$FRAMEWORK_NAME" "$PREFIX"/lib/*.a
      cp -R "$PREFIX/include/"* "$FWPATH/Versions/A/Headers/" 2>/dev/null || true
      
      echo "$PLIST_CONTENT" > "$FWPATH/Versions/A/Resources/Info.plist"
      echo "$UMBRELLA_HEADER_CONTENT" > "$FWPATH/Versions/A/Headers/$FRAMEWORK_NAME.h"
      echo "$MODULE_MAP_CONTENT" > "$FWPATH/Versions/A/Modules/module.modulemap"

      (
        cd "$FWPATH"
        ln -s A Versions/Current
        ln -s Versions/Current/Headers Headers
        ln -s Versions/Current/Modules Modules
        ln -s Versions/Current/Resources Resources
        ln -s Versions/Current/"$FRAMEWORK_NAME" "$FRAMEWORK_NAME"
      )
    else
      # --- IOS / TVOS / CATALYST (SHALLOW) ---
      echo "  -> Assembling shallow slice for $P: $SLICE"
      mkdir -p "$FWPATH/Headers" "$FWPATH/Modules"

      echo "  -> Combining $(ls -1 "$PREFIX"/lib/*.a | wc -l | tr -d ' ') static libraries..."
      libtool -static -o "$FWPATH/$FRAMEWORK_NAME" "$PREFIX"/lib/*.a
      cp -R "$PREFIX/include/"* "$FWPATH/Headers/" 2>/dev/null || true

      echo "$PLIST_CONTENT" > "$FWPATH/Info.plist"
      echo "$UMBRELLA_HEADER_CONTENT" > "$FWPATH/Headers/$FRAMEWORK_NAME.h"
      echo "$MODULE_MAP_CONTENT" > "$FWPATH/Modules/module.modulemap"
    fi

    ARGS+=(-framework "$FWPATH")
  done

  xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT"
  echo "✅ XCFramework created at: $OUT"
}

create_xcframework
echo "🚀 Build complete!"