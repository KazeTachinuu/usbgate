#!/bin/bash
# Prints the path of a Swift toolchain that meets a minimum version.
#
# Looked at in order: $SWIFT, whatever is on PATH, then any swiftly-managed
# toolchain. Selection is by version, never by location, so a suitable Swift on
# PATH always wins and nothing is silently preferred behind your back.
#
# If none qualifies, prints the best candidate anyway so the caller can report
# the version it actually found.
set -u

minimum=${1:-6.2}

version_of() {
    "$1" -version 2>/dev/null |
        sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1
}

meets() {
    [ -n "$1" ] || return 1
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

fallback=""
for candidate in "${SWIFT:-}" "$(command -v swift || true)" "$HOME/.swiftly/bin/swift"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    [ -n "$fallback" ] || fallback=$candidate
    if meets "$(version_of "$candidate")" "$minimum"; then
        echo "$candidate"
        exit 0
    fi
done

echo "${fallback:-swift}"
