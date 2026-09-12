#!/bin/zsh
set -euo pipefail
products="${1:?Provide the Debug build products directory}"
project="${2:?Provide the project package path}"
check_root="${0:A:h}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/trimato-editor-picture-check.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export LLVM_PROFILE_FILE="$scratch/check.profraw"
binary_directory="$products/Trimato.app/Contents/MacOS"
mkdir -p "$scratch/Check.app/Contents/MacOS" "$scratch/Check.app/Contents/Resources"
# Use the same tool binaries before Xcode adds parent-sandbox inheritance.
ln -s "$check_root/../Trimato/Trimato/Resources/Tools/ffmpeg" "$scratch/Check.app/Contents/Resources/ffmpeg"
ln -s "$check_root/../Trimato/Trimato/Resources/Tools/ffprobe" "$scratch/Check.app/Contents/Resources/ffprobe"
developer="$(xcode-select -p)"
frameworks="$developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
cat > "$scratch/Runner.swift" <<'SWIFT'
import Testing
@main struct Runner {
    static func main() async { await Testing.__swiftPMEntryPoint() as Never }
}
SWIFT
xcrun swiftc -parse-as-library -module-cache-path "$scratch/ModuleCache" -I "$products" -F "$frameworks" \
    -plugin-path "$developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing" \
    "$scratch/Runner.swift" "$check_root/../Trimato/TrimatoTests/IPhoneMediaTests.swift" \
    "$check_root/../Trimato/TrimatoTests/SpatialAudioIntegrationTests.swift" \
    "$binary_directory/Trimato.debug.dylib" -Xlinker -rpath -Xlinker "$binary_directory" \
    -Xlinker -rpath -Xlinker "$frameworks" -o "$scratch/Check.app/Contents/MacOS/tests"
"$scratch/Check.app/Contents/MacOS/tests" --filter spatialPreview
xcrun swiftc -parse-as-library -module-cache-path "$scratch/ModuleCache" \
    -I "$products" "$check_root/EditorPictureCheck.swift" \
    "$binary_directory/Trimato.debug.dylib" \
    -Xlinker -rpath -Xlinker "$binary_directory" -o "$scratch/Check.app/Contents/MacOS/check"
"$scratch/Check.app/Contents/MacOS/check" "$project"
