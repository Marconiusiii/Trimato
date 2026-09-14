#!/bin/zsh
set -euo pipefail
products="${1:?Provide Debug products directory}"
project="${2:?Provide project.json}"
check_root="${0:A:h}"
scratch="${3:-$(mktemp -d /tmp/trimato-export-hang.XXXXXX)}"
print "Artifacts: $scratch"
export LLVM_PROFILE_FILE="$scratch/check.profraw"
binary_directory="$products/Trimato.app/Contents/MacOS"
mkdir -p "$scratch/Check.app/Contents/MacOS" "$scratch/Check.app/Contents/Resources"
ln -sf "$check_root/../Trimato/Trimato/Resources/Tools/ffmpeg" "$scratch/Check.app/Contents/Resources/ffmpeg"
ln -sf "$check_root/../Trimato/Trimato/Resources/Tools/ffprobe" "$scratch/Check.app/Contents/Resources/ffprobe"
xcrun swiftc -parse-as-library -module-cache-path "$scratch/ModuleCache" -I "$products" \
    "$check_root/ExportHangCheck.swift" "$binary_directory/Trimato.debug.dylib" \
    -Xlinker -rpath -Xlinker "$binary_directory" -o "$scratch/Check.app/Contents/MacOS/check"
"$scratch/Check.app/Contents/MacOS/check" "$project" "$scratch" "${4:-}"
