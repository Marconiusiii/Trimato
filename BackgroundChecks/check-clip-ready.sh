#!/bin/zsh
set -euo pipefail
products="${1:?Provide Debug products directory}"
check_root="${0:A:h}"
scratch="$(mktemp -d /tmp/trimato-clip-ready.XXXXXX)"
export LLVM_PROFILE_FILE="$scratch/check.profraw"
binary_directory="$products/Trimato.app/Contents/MacOS"
xcrun swiftc -parse-as-library -module-cache-path "$scratch/ModuleCache" -I "$products" \
    "$check_root/ClipReadyAnnouncementCheck.swift" "$binary_directory/Trimato.debug.dylib" \
    -Xlinker -rpath -Xlinker "$binary_directory" -o "$scratch/check"
"$scratch/check"
