#!/bin/zsh
set -euo pipefail
products="${1:?Provide Debug build products}"
check_root="${0:A:h}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/trimato-clip-color-check.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export LLVM_PROFILE_FILE="$scratch/check.profraw"
binary_directory="$products/Trimato.app/Contents/MacOS"
mkdir -p "$scratch/Check.app/Contents/MacOS" "$scratch/Check.app/Contents/Resources"
for tool in ffmpeg ffprobe; do
    ln -s "$check_root/../Trimato/Trimato/Resources/Tools/$tool" "$scratch/Check.app/Contents/Resources/$tool"
done
# The fixture generator needs libx265; no source recordings are modified.
fixture_encoder="${TRIMATO_FIXTURE_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
for color in hlg pq sdr; do
    primaries=bt2020
    transfer=arib-std-b67
    matrix=bt2020nc
    color_numbers="colorprim=9:transfer=18:colormatrix=9"
    if [[ "$color" == pq ]]; then transfer=smpte2084; color_numbers="colorprim=9:transfer=16:colormatrix=9"; fi
    if [[ "$color" == sdr ]]; then primaries=bt709; transfer=bt709; matrix=bt709; color_numbers="colorprim=1:transfer=1:colormatrix=1"; fi
    "$fixture_encoder" -v error -f lavfi -i 'testsrc2=size=320x180:rate=30:duration=1.2' \
        -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=1.2' \
        -c:v libx265 -preset ultrafast -x265-params "log-level=error:pools=1:$color_numbers" -pix_fmt yuv420p10le \
        -color_primaries "$primaries" -color_trc "$transfer" -colorspace "$matrix" \
        -tag:v hvc1 -c:a aac -shortest "$scratch/$color.mov"
done
xcrun swiftc -parse-as-library -module-cache-path "$scratch/ModuleCache" -I "$products" \
    "$check_root/ClipColorExportCheck.swift" "$binary_directory/Trimato.debug.dylib" \
    -Xlinker -rpath -Xlinker "$binary_directory" -o "$scratch/Check.app/Contents/MacOS/check"
"$scratch/Check.app/Contents/MacOS/check" "$scratch" "${@:2}"
