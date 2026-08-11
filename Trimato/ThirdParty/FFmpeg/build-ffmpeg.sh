#!/bin/zsh
set -euo pipefail

FFMPEG_VERSION="8.1.2"
SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h:h}"
SOURCE_ARCHIVE="${SCRIPT_DIRECTORY}/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SOURCE_DIRECTORY="${SCRIPT_DIRECTORY}/ffmpeg-${FFMPEG_VERSION}"
BUILD_ROOT="${SCRIPT_DIRECTORY}/build-lgpl"
OUTPUT_DIRECTORY="${PROJECT_DIRECTORY}/Trimato/Resources/Tools"
DEPLOYMENT_TARGET="13.0"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"

if [[ ! -f "${SOURCE_ARCHIVE}" ]]; then
    curl -L "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" -o "${SOURCE_ARCHIVE}"
fi

if [[ ! -d "${SOURCE_DIRECTORY}" ]]; then
    tar -xf "${SOURCE_ARCHIVE}" -C "${SCRIPT_DIRECTORY}"
fi

mkdir -p "${BUILD_ROOT}" "${OUTPUT_DIRECTORY}"

build_architecture() {
    local architecture="$1"
    local architecture_build="${BUILD_ROOT}/${architecture}"
    local architecture_install="${architecture_build}/install"
    mkdir -p "${architecture_build}" "${architecture_install}"

    pushd "${architecture_build}" >/dev/null
    "${SOURCE_DIRECTORY}/configure" \
        --prefix="${architecture_install}" \
        --arch="${architecture}" \
        --cc="$(xcrun --find clang)" \
        --host-cc="$(xcrun --find clang)" \
        --host-cflags="-isysroot ${MACOS_SDK}" \
        --host-ldflags="-isysroot ${MACOS_SDK}" \
        --sysroot="${MACOS_SDK}" \
        --extra-cflags="-arch ${architecture} -isysroot ${MACOS_SDK} -mmacosx-version-min=${DEPLOYMENT_TARGET}" \
        --extra-ldflags="-arch ${architecture} -isysroot ${MACOS_SDK} -mmacosx-version-min=${DEPLOYMENT_TARGET}" \
        --target-os=darwin \
        --disable-autodetect \
        --disable-x86asm \
        --disable-shared \
        --enable-static \
        --disable-debug \
        --disable-doc \
        --disable-ffplay \
        --disable-gpl \
        --disable-nonfree \
        --disable-network \
        --disable-protocols \
        --enable-protocol=file \
        --enable-protocol=pipe \
        --enable-protocol=fd \
        --disable-demuxer=hls \
        --disable-muxer=hls \
        --enable-audiotoolbox \
        --enable-videotoolbox
    make -j"$(sysctl -n hw.logicalcpu)" ffmpeg ffprobe
    cp ffmpeg ffprobe "${architecture_install}/"
    popd >/dev/null
}

build_architecture arm64
build_architecture x86_64

lipo -create \
    "${BUILD_ROOT}/arm64/install/ffmpeg" \
    "${BUILD_ROOT}/x86_64/install/ffmpeg" \
    -output "${OUTPUT_DIRECTORY}/ffmpeg"
lipo -create \
    "${BUILD_ROOT}/arm64/install/ffprobe" \
    "${BUILD_ROOT}/x86_64/install/ffprobe" \
    -output "${OUTPUT_DIRECTORY}/ffprobe"
chmod 755 "${OUTPUT_DIRECTORY}/ffmpeg" "${OUTPUT_DIRECTORY}/ffprobe"

"${OUTPUT_DIRECTORY}/ffmpeg" -hide_banner -version
"${OUTPUT_DIRECTORY}/ffprobe" -hide_banner -version
lipo -archs "${OUTPUT_DIRECTORY}/ffmpeg"
lipo -archs "${OUTPUT_DIRECTORY}/ffprobe"
