#!/bin/zsh
set -euo pipefail
products="${1:?Provide Debug products directory}"
check_root="${0:A:h}"
scratch="$(mktemp -d /private/tmp/trimato-slider-comparison.XXXXXX)"
app="$scratch/Slider Entry Comparison.app"
mkdir -p "$app/Contents/MacOS"
cp "$products/Trimato.app/Contents/MacOS/Trimato.debug.dylib" "$app/Contents/MacOS/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SliderEntryComparison</string>
<key>CFBundleIdentifier</key><string>com.marconius.trimato.slider-entry-comparison</string>
<key>CFBundleName</key><string>Slider Entry Comparison</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -module-cache-path "$scratch/ModuleCache" -I "$products" \
    "$check_root/SliderEntryComparison.swift" "$app/Contents/MacOS/Trimato.debug.dylib" \
    -Xlinker -rpath -Xlinker '@executable_path' -o "$app/Contents/MacOS/SliderEntryComparison"
codesign --force --sign - "$app/Contents/MacOS/Trimato.debug.dylib"
codesign --force --sign - "$app"
LLVM_PROFILE_FILE="$scratch/background-check.profraw" "$app/Contents/MacOS/SliderEntryComparison" --background-check
printf '%s\n' "$app"
