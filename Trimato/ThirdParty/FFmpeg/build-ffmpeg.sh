#!/bin/zsh
set -euo pipefail

FFMPEG_VERSION="8.1.2"
SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h:h}"
SOURCE_ARCHIVE="${SCRIPT_DIRECTORY}/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SOURCE_DIRECTORY="${SCRIPT_DIRECTORY}/ffmpeg-${FFMPEG_VERSION}"
BUILD_ROOT="${SCRIPT_DIRECTORY}/build-lgpl"
OUTPUT_DIRECTORY="${PROJECT_DIRECTORY}/Trimato/Resources/Tools"
SYMBOL_DIRECTORY="${SCRIPT_DIRECTORY}/Symbols"
DEPLOYMENT_TARGET="13.0"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"

if [[ ! -f "${SOURCE_ARCHIVE}" ]]; then
    curl -L "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" -o "${SOURCE_ARCHIVE}"
fi

if [[ ! -d "${SOURCE_DIRECTORY}" ]]; then
    tar -xf "${SOURCE_ARCHIVE}" -C "${SCRIPT_DIRECTORY}"
fi

mkdir -p "${BUILD_ROOT}" "${OUTPUT_DIRECTORY}" "${SYMBOL_DIRECTORY}"

build_architecture() {
    local architecture="$1"
    local architecture_build="${BUILD_ROOT}/${architecture}"
    local architecture_install="${architecture_build}/install"
    local -a assembly_options=()
    local -a cross_options=()
    if [[ "$(uname -m)" != "${architecture}" ]]; then
        cross_options=(--enable-cross-compile)
    fi
    if [[ "${architecture}" == "x86_64" ]]; then
        local assembler="${NASM:-nasm}"
        if ! command -v "${assembler}" >/dev/null; then
            print -u2 "NASM is required to build the optimized Intel FFmpeg tools. Set NASM to its executable path."
            exit 1
        fi
        assembly_options=("--x86asmexe=${assembler}")
    fi
    mkdir -p "${architecture_build}" "${architecture_install}"

    pushd "${architecture_build}" >/dev/null
    "${SOURCE_DIRECTORY}/configure" \
        --prefix="/opt/trimato-ffmpeg/${architecture}" \
        --arch="${architecture}" \
        --cc="$(xcrun --find clang)" \
        --host-cc="$(xcrun --find clang)" \
        --host-cflags="-isysroot ${MACOS_SDK}" \
        --host-ldflags="-isysroot ${MACOS_SDK}" \
        --sysroot="${MACOS_SDK}" \
        --extra-cflags="-arch ${architecture} -isysroot ${MACOS_SDK} -mmacosx-version-min=${DEPLOYMENT_TARGET}" \
        --extra-ldflags="-arch ${architecture} -isysroot ${MACOS_SDK} -mmacosx-version-min=${DEPLOYMENT_TARGET}" \
        --target-os=darwin \
        "${cross_options[@]}" \
        --disable-autodetect \
        "${assembly_options[@]}" \
        --disable-shared \
        --enable-static \
        --enable-debug=1 \
        --disable-stripping \
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

build_architectures=(arm64 x86_64)
if [[ -n "${FFMPEG_BUILD_ARCHITECTURES:-}" ]]; then
    build_architectures=(${=FFMPEG_BUILD_ARCHITECTURES})
fi
for architecture in "${build_architectures[@]}"; do
    build_architecture "${architecture}"
done

lipo -create \
    "${BUILD_ROOT}/arm64/install/ffmpeg" \
    "${BUILD_ROOT}/x86_64/install/ffmpeg" \
    -output "${OUTPUT_DIRECTORY}/ffmpeg"
lipo -create \
    "${BUILD_ROOT}/arm64/install/ffprobe" \
    "${BUILD_ROOT}/x86_64/install/ffprobe" \
    -output "${OUTPUT_DIRECTORY}/ffprobe"
chmod 755 "${OUTPUT_DIRECTORY}/ffmpeg" "${OUTPUT_DIRECTORY}/ffprobe"

for tool_name in ffmpeg ffprobe; do
    tool_path="${OUTPUT_DIRECTORY}/${tool_name}"
    symbol_path="${SYMBOL_DIRECTORY}/${tool_name}.dSYM"
    rm -rf "${symbol_path}"
    xcrun dsymutil "${tool_path}" -o "${symbol_path}"

    binary_uuids="$(xcrun dwarfdump --uuid "${tool_path}" | sed -E 's/^UUID: ([^ ]+) \(([^)]+)\).*/\2 \1/' | sort)"
    symbol_uuids="$(xcrun dwarfdump --uuid "${symbol_path}" | sed -E 's/^UUID: ([^ ]+) \(([^)]+)\).*/\2 \1/' | sort)"
    if [[ "${binary_uuids}" != "${symbol_uuids}" ]]; then
        print -u2 "The ${tool_name} dSYM UUIDs do not match the executable."
        print -u2 "Executable UUIDs:\n${binary_uuids}"
        print -u2 "dSYM UUIDs:\n${symbol_uuids}"
        exit 1
    fi
done

# Record the configuration from both actual builds rather than maintaining release flags by hand.
python3 - "${SCRIPT_DIRECTORY}" "${DEPLOYMENT_TARGET}" <<'PYCONFIG'
import json
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
lines = ["FFmpeg version: 8.1.2", "Architectures: arm64 x86_64", f"Minimum macOS: {sys.argv[2]}", "License: LGPL version 2.1 or later", ""]
for architecture in ("arm64", "x86_64"):
    header = (root / "build-lgpl" / architecture / "config.h").read_text()
    value = re.search(r'^#define FFMPEG_CONFIGURATION (".*")$', header, re.MULTILINE)
    if value is None:
        raise SystemExit(f"Missing {architecture} configuration")
    lines += [f"Complete {architecture} configuration:", json.loads(value[1]), ""]
(root / "build-configuration.txt").write_text("\n".join(lines))
PYCONFIG

"${OUTPUT_DIRECTORY}/ffmpeg" -hide_banner -version
"${OUTPUT_DIRECTORY}/ffprobe" -hide_banner -version
lipo -archs "${OUTPUT_DIRECTORY}/ffmpeg"
lipo -archs "${OUTPUT_DIRECTORY}/ffprobe"
xcrun dwarfdump --uuid "${SYMBOL_DIRECTORY}/ffmpeg.dSYM"
xcrun dwarfdump --uuid "${SYMBOL_DIRECTORY}/ffprobe.dSYM"
