#!/bin/zsh
set -euo pipefail
products="${1:?Provide the Debug build products directory}"
check_root="${0:A:h}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/trimato-recording-check.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export LLVM_PROFILE_FILE="$scratch/check.profraw"
binary_directory="$products/Trimato.app/Contents/MacOS"
mkdir -p "$scratch/Check.app/Contents/MacOS" "$scratch/Check.app/Contents/Resources"
# Use the same tool binaries before Xcode adds parent-sandbox inheritance.
ln -s "$check_root/../Trimato/Trimato/Resources/Tools/ffmpeg" "$scratch/Check.app/Contents/Resources/ffmpeg"
ln -s "$check_root/../Trimato/Trimato/Resources/Tools/ffprobe" "$scratch/Check.app/Contents/Resources/ffprobe"
xcrun swiftc -parse-as-library -module-cache-path "$scratch/ModuleCache" \
    -I "$products" "$check_root/RecordingPlaybackCheck.swift" \
    "$binary_directory/Trimato.debug.dylib" \
    -Xlinker -rpath -Xlinker "$binary_directory" -o "$scratch/Check.app/Contents/MacOS/check"
"$scratch/Check.app/Contents/MacOS/check"
