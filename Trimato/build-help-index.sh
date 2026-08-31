#!/bin/zsh

set -euo pipefail

trimato_root="${0:A:h}"
help_pages="$trimato_root/Trimato/Trimato.help/Contents/Resources/en.lproj"
help_index="$help_pages/Trimato.helpindex"
quick_start_page="$help_pages/quickstart.html"
temporary_index="$(mktemp "${TMPDIR:-/tmp}/trimato-help-index.XXXXXX")"

if [[ ! -f "$quick_start_page" ]]; then
    echo "Missing Quick Start Help page: $quick_start_page" >&2
    exit 1
fi

if ! /usr/bin/grep -Fq '<a name="trimato-quickstart-guide"></a>' "$quick_start_page"; then
    echo "Missing Quick Start Help anchor in $quick_start_page" >&2
    exit 1
fi

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
