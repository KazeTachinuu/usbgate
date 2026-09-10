#!/bin/bash
# Prints the path of a Swift toolchain that can build this package.
#
# A toolchain is picked only if it meets the minimum version AND can actually
# load Package.swift. Reporting a good version is not enough: a half-upgraded
# install answers 6.3.2 and still fails, so every candidate is tried for real.
#
# Looked at in order: $SWIFT, PATH, swiftly, installed toolchains, Xcode.
# If none qualifies, prints the first one found so the caller can report it.
set -u

minimum=${1:-6.0.3}

version_of() {
    "$1" -version 2>/dev/null |
        sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1
}

meets() {
    [ -n "$1" ] || return 1
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

# Only meaningful next to a manifest; elsewhere the version is all we can check.
#
# A probe killed by a signal says nothing about the toolchain, only that the
# probe itself fell over, so it counts as a pass. Just a non-zero exit is a real
# verdict: the manifest was read and rejected.
loads() {
    [ -f Package.swift ] || return 0
    sh -c '"$0" package dump-package; exit $?' "$1" >/dev/null 2>&1
    status=$?
    [ "$status" -lt 128 ] || return 0
    [ "$status" -eq 0 ]
}

candidates() {
    echo "${SWIFT:-}"
    command -v swift || true
    echo "$HOME/.swiftly/bin/swift"
    ls -d /Library/Developer/Toolchains/*/usr/bin/swift \
          "$HOME"/Library/Developer/Toolchains/*/usr/bin/swift \
          /Applications/Xcode*.app/Contents/Developer/Toolchains/*/usr/bin/swift \
          2>/dev/null
}

fallback=""
seen=""
while read -r candidate; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    case "$seen" in *"|$candidate|"*) continue ;; esac
    seen="$seen|$candidate|"
    [ -n "$fallback" ] || fallback=$candidate
    meets "$(version_of "$candidate")" "$minimum" || continue
    loads "$candidate" || continue
    echo "$candidate"
    exit 0
done <<CANDIDATES
$(candidates)
CANDIDATES

echo "${fallback:-swift}"
