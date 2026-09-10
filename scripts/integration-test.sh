#!/bin/bash
# End-to-end checks against a real Disk Arbitration session and the real
# /var/db/usbgate state. Root-only checks are skipped when not run as root.
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0; skip=0
ok()    { echo "  [+] $1"; pass=$((pass+1)); }
bad()   { echo "  [-] $1"; fail=$((fail+1)); }
skipt() { echo "  [!] skipped: $1"; skip=$((skip+1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# Same toolchain the Makefile picks, so this behaves identically whatever is on
# PATH when it runs.
SWIFT=$(./scripts/swift-toolchain.sh 6.0)
# Read from the daemon plist so the identifier lives in one place.
LABEL=$(plutil -extract Label raw deploy/*.plist)
ROOT=0; [ "$(id -u)" -eq 0 ] && ROOT=1
BIN=.build/debug/usbgate
DMG=$(mktemp -d)/ug.dmg
DAEMON_PID=""

cleanup() {
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
    hdiutil detach /Volumes/UGTEST -quiet 2>/dev/null
    rm -rf "$(dirname "$DMG")"
}
trap cleanup EXIT

# Building as root would write root-owned files into .build and break every
# later user build, and sudo resets HOME so the toolchain is not even found.
# `make check` covers this as your own user.
if [ "$ROOT" -eq 1 ]; then
    echo; echo "build and unit tests"
    skipt "building as root; run 'make check' as yourself"
    if [ ! -x "$BIN" ]; then
        bad "no debug binary; run 'make check' first"
        echo; echo "  $pass passed, $fail failed, $skip skipped"; echo; exit 1
    fi
else
    echo; echo "build and unit tests"
    check "package builds"  "$SWIFT build"
    check "unit tests pass" "$SWIFT test"
fi

echo; echo "command surface"
check "version"                  "$BIN version"
check "help"                     "$BIN help"
check "status"                   "$BIN status"
check "rejected"                 "$BIN rejected"
check "unknown command exits 2"  "$BIN nonsense; [ \$? -eq 2 ]"

# As root a bare invocation IS the daemon, and would run forever.
if [ "$ROOT" -eq 1 ]; then
    skipt "bare invocation (as root it starts the daemon)"
else
    check "bare invocation prints usage, does not daemonise" "$BIN | grep -q 'Usage: usbgate'"
fi

if [ "$ROOT" -eq 1 ]; then
    skipt "sudo gating (running as root)"
else
    check "allow refuses without sudo"   "! $BIN allow"
    check "revoke refuses without sudo"  "! $BIN revoke 0951:1665/X"
    check "dismiss refuses without sudo" "! $BIN dismiss 1"
fi

echo; echo "identity cross-check against ioreg"
# usbgate reads the vendor, product and serial from three different IOKit
# properties. Nothing inside the package can prove it read the right one, so
# every attached mass-storage device found in the registry must appear in
# `usbgate status`. Driven from the registry, not from status, because status
# also lists authorised drives that are not plugged in.
registry=$(mktemp)
ioreg -r -c IOUSBHostDevice -l -w0 2>/dev/null > "$registry"
reported=$($BIN status 2>/dev/null)

present=$(awk '
    /"idVendor" =/                { v = $NF }
    /"idProduct" =/               { p = $NF }
    /"USB Serial Number" =/       { gsub(/"/, "", $NF); s = $NF }
    /"bInterfaceClass" = 8$/      { if (v != "" && s != "") printf "%04x:%04x/%s\n", v, p, s }
' "$registry" | sort -u)

if [ -z "$present" ]; then
    skipt "identity cross-check (no usb storage attached)"
else
    for id in $present; do
        if printf '%s' "$reported" | grep -qF "$id"; then
            ok "usbgate reports $id"
        else
            bad "usbgate does not report attached drive $id"
        fi
    done
fi
rm -f "$registry"

echo; echo "disk arbitration"
hdiutil create -size 10m -fs HFS+ -volname UGTEST "$DMG" -quiet
check "test image attaches with no daemon" \
    "hdiutil attach '$DMG' -nobrowse && mount | grep -q UGTEST"
hdiutil detach /Volumes/UGTEST -quiet 2>/dev/null

if [ "$ROOT" -ne 1 ]; then
    echo; echo "daemon (needs root)"
    skipt "daemon lifecycle, mount approval, sweep, live reload"
    echo
    echo "  $pass passed, $fail failed, $skip skipped"
    echo
    [ "$fail" -eq 0 ]; exit $?
fi

echo; echo "sweep: volume mounted before the daemon starts"
hdiutil attach "$DMG" -nobrowse -quiet
"$BIN" & DAEMON_PID=$!
sleep 3
check "daemon is running" "kill -0 $DAEMON_PID"
check "daemon logged that it is active" \
    "log show --predicate 'subsystem == \"$LABEL\"' --last 1m | grep -q active"
# A disk image is out of scope, so deny-all must not touch it.
check "disk image survives the startup sweep" "mount | grep -q UGTEST"
hdiutil detach /Volumes/UGTEST -quiet 2>/dev/null

echo; echo "mount approval while enforcing"
check "disk image mounts while enforcing" \
    "hdiutil attach '$DMG' -nobrowse && mount | grep -q UGTEST"
hdiutil detach /Volumes/UGTEST -quiet 2>/dev/null

echo; echo "allowlist file"
check "allowlist directory is root-owned"     "[ \"\$(stat -f %u /var/db/usbgate)\" = 0 ]"
check "other on is persisted"                 "$BIN other on && $BIN status | grep -q 'allowed'"
check "daemon picked up the change unprompted" \
    "sleep 2; log show --predicate 'subsystem == \"$LABEL\"' --last 30s | grep -q policy"
check "other off is persisted"                "$BIN other off && $BIN status | grep -q refused"
check "allowlist file is not group-writable" \
    "[ \$(( 0\$(stat -f %Lp /var/db/usbgate/allowlist.plist) & 0022 )) -eq 0 ]"

echo; echo "reload"
kill -HUP "$DAEMON_PID"
sleep 2
check "SIGHUP reloads without restart" "kill -0 $DAEMON_PID"
kill "$DAEMON_PID" 2>/dev/null; DAEMON_PID=""

echo
echo "  $pass passed, $fail failed, $skip skipped"
echo
[ "$fail" -eq 0 ]
