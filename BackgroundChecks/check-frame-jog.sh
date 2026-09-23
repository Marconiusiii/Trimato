#!/bin/zsh
set -euo pipefail
products="${1:?Provide Debug products directory}"
check_root="${0:A:h}"
scratch="$(mktemp -d /tmp/trimato-frame-jog.XXXXXX)"
export LLVM_PROFILE_FILE="$scratch/check.profraw"
binary_directory="$products/Trimato.app/Contents/MacOS"
# Give Bundle.main the same media tools before Xcode signs them to inherit the app sandbox.
# This directory is never opened as an application and the check creates no NSApp.
mkdir -p "$scratch/Check.app/Contents/MacOS" "$scratch/Check.app/Contents/Resources"
ln -s "$check_root/../Trimato/Trimato/Resources/Tools/ffmpeg" "$scratch/Check.app/Contents/Resources/ffmpeg"
ln -s "$check_root/../Trimato/Trimato/Resources/Tools/ffprobe" "$scratch/Check.app/Contents/Resources/ffprobe"
xcrun swiftc -parse-as-library -module-cache-path "$scratch/ModuleCache" -I "$products" \
    "$check_root/FrameJogCheck.swift" "$binary_directory/Trimato.debug.dylib" \
    -Xlinker -rpath -Xlinker "$binary_directory" -o "$scratch/Check.app/Contents/MacOS/check"
"$scratch/Check.app/Contents/MacOS/check" "${2:?Provide encoded fixture}" "${@:3}"
