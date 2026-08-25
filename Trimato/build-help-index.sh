#!/bin/zsh

set -euo pipefail

trimato_root="${0:A:h}"
help_pages="$trimato_root/Trimato/Trimato.help/Contents/Resources/en.lproj"
help_index="$help_pages/Trimato.helpindex"
temporary_index="$(mktemp "${TMPDIR:-/tmp}/trimato-help-index.XXXXXX")"

cleanup() {
    rm -f "$temporary_index"
}
trap cleanup EXIT

/usr/bin/hiutil \
    -I corespotlight \
    -C \
    -a \
    -g \
    -s en \
    -l en \
    -f "$temporary_index" \
    "$help_pages"

mv "$temporary_index" "$help_index"
chmod 644 "$help_index"
trap - EXIT

echo "Updated $help_index"
