#!/bin/zsh
set -euo pipefail
products="${1:?Provide the Debug build products directory}"
check_root="${0:A:h}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/trimato-silence-check.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export LLVM_PROFILE_FILE="$scratch/check.profraw"
binary_directory="$products/Trimato.app/Contents/MacOS"
mkdir -p "$scratch/Check.app/Contents/MacOS" "$scratch/Check.app/Contents/Resources"
ln -s "$check_root/../Trimato/Trimato/Resources/Tools/ffmpeg" "$scratch/Check.app/Contents/Resources/ffmpeg"
ln -s "$check_root/../Trimato/Trimato/Resources/Tools/ffprobe" "$scratch/Check.app/Contents/Resources/ffprobe"
developer="$(xcode-select -p)"
frameworks="$developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
cat > "$scratch/Runner.swift" <<'SWIFT'
import AppKit
import Testing
@main struct Runner {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        await Testing.__swiftPMEntryPoint() as Never
    }
}
SWIFT
xcrun swiftc -parse-as-library -module-cache-path "$scratch/ModuleCache" -I "$products" -F "$frameworks" \
    -plugin-path "$developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing" \
    "$scratch/Runner.swift" "$check_root/../Trimato/TrimatoTests/TrimatoProjectTests.swift" \
    "$check_root/../Trimato/TrimatoTests/ProjectPlaybackTests.swift" \
    "$check_root/../Trimato/TrimatoTests/MultiTrackTimelineTests.swift" \
    "$check_root/../Trimato/TrimatoTests/SilenceTrimmingTests.swift" \
    "$binary_directory/Trimato.debug.dylib" -Xlinker -rpath -Xlinker "$binary_directory" \
    -Xlinker -rpath -Xlinker "$frameworks" -o "$scratch/Check.app/Contents/MacOS/check"
"$scratch/Check.app/Contents/MacOS/check" --filter 'SilenceTrimmingTests|ProjectPlaybackTests|MultiTrackTimelineTests'
