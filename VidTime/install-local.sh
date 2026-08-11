#!/bin/zsh
set -euo pipefail

PROJECT_DIRECTORY="${0:A:h}"
DERIVED_DATA_DIRECTORY="${PROJECT_DIRECTORY}/.build/local-install"
BUILT_APP="${DERIVED_DATA_DIRECTORY}/Build/Products/Release/VidTime.app"
INSTALLED_APP="/Applications/vidTime.app"
LAUNCH_SERVICES_REGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

if pgrep -x VidTime >/dev/null 2>&1; then
    print -u2 "Quit vidTime before installing a new build."
    exit 1
fi

xcodebuild \
    -project "${PROJECT_DIRECTORY}/VidTime.xcodeproj" \
    -scheme VidTime \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED_DATA_DIRECTORY}" \
    build

if [[ ! -d "${BUILT_APP}" ]]; then
    print -u2 "The Release build completed without producing VidTime.app."
    exit 1
fi

rm -rf "${INSTALLED_APP}"
ditto "${BUILT_APP}" "${INSTALLED_APP}"
"${LAUNCH_SERVICES_REGISTER}" -f "${INSTALLED_APP}"

print "Installed ${INSTALLED_APP}"
