#!/bin/bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="Debug"
API_KEY=""
SHARED_SECRET=""

usage() {
    echo "Usage:"
    echo "  $0 --api-key '<32-hex-key>' --shared-secret '<32-hex-secret>'"
    echo "  $0 --prompt"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --api-key)
            [ "$#" -ge 2 ] || { echo "ERROR: --api-key needs a value"; exit 2; }
            API_KEY="$2"
            shift 2
            ;;
        --shared-secret)
            [ "$#" -ge 2 ] || { echo "ERROR: --shared-secret needs a value"; exit 2; }
            SHARED_SECRET="$2"
            shift 2
            ;;
        --prompt)
            read -r -p "My Pod Last.fm API key: " API_KEY
            read -r -s -p "My Pod Last.fm shared secret: " SHARED_SECRET
            echo
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1"
            usage
            exit 2
            ;;
    esac
done

if ! [[ "$API_KEY" =~ ^[0-9A-Fa-f]{32}$ ]]; then
    echo "ERROR: Last.fm API key must be exactly 32 hexadecimal characters."
    exit 2
fi

if ! [[ "$SHARED_SECRET" =~ ^[0-9A-Fa-f]{32}$ ]]; then
    echo "ERROR: Last.fm shared secret must be exactly 32 hexadecimal characters."
    exit 2
fi

cd "$REPO"

echo
echo "=== LAST.FM CREDENTIAL SOURCE ==="
echo "temporary private xcconfig outside the repository; deleted automatically after build"

echo
echo "=== SOURCE SAFETY CHECK ==="
if git grep -qF "$API_KEY" -- . ':!Scripts/build-with-lastfm.sh' 2>/dev/null; then
    echo "ERROR: API key already exists in tracked source."
    exit 1
fi
if git grep -qF "$SHARED_SECRET" -- . ':!Scripts/build-with-lastfm.sh' 2>/dev/null; then
    echo "ERROR: shared secret already exists in tracked source."
    exit 1
fi
echo "PASS: credentials are not present in tracked source"

TMP_XCCONFIG="$(mktemp "${TMPDIR:-/tmp}/mypod-lastfm-xcconfig.XXXXXX")"
chmod 600 "$TMP_XCCONFIG"

cleanup() {
    rm -f "$TMP_XCCONFIG"
}
trap cleanup EXIT HUP INT TERM

printf 'LASTFM_API_KEY = %s\nLASTFM_SHARED_SECRET = %s\n' \
    "$API_KEY" "$SHARED_SECRET" > "$TMP_XCCONFIG"

echo
echo "=== TEMPORARY BUILD CONFIG ==="
echo "$TMP_XCCONFIG"
echo "mode: $(stat -f '%Sp' "$TMP_XCCONFIG")"
echo "NOTE: credential values intentionally not printed"

echo
echo "=== CLEAN KNOWN LIBGPOD AUTORECONF NOISE ==="
git restore -- \
    Vendor/libgpod/m4/libtool.m4 \
    Vendor/libgpod/m4/ltoptions.m4 \
    Vendor/libgpod/m4/ltsugar.m4 \
    Vendor/libgpod/m4/ltversion.m4 \
    'Vendor/libgpod/m4/lt~obsolete.m4' 2>/dev/null || true

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/MyPod-LastFM-CLI"
BUILD_LOG="$HOME/Downloads/My-Pod-lastfm-build-$(date +%Y%m%d-%H%M%S).log"

rm -rf "$DERIVED_DATA"

echo
echo "=== BUILD MY POD ($CONFIGURATION) ==="

set +e
MYPOD_REDACT_API_KEY="$API_KEY" \
MYPOD_REDACT_SHARED_SECRET="$SHARED_SECRET" \
xcodebuild \
    -project "My Pod.xcodeproj" \
    -scheme "My Pod" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -xcconfig "$TMP_XCCONFIG" \
    build 2>&1 |
python3 -c '
import os, sys
a = os.environ.get("MYPOD_REDACT_API_KEY", "")
s = os.environ.get("MYPOD_REDACT_SHARED_SECRET", "")
for line in sys.stdin:
    if a:
        line = line.replace(a, "[REDACTED_API_KEY]")
    if s:
        line = line.replace(s, "[REDACTED_SHARED_SECRET]")
    sys.stdout.write(line)
' | tee "$BUILD_LOG"
STATUS=${PIPESTATUS[0]}
set -e

git restore -- \
    Vendor/libgpod/m4/libtool.m4 \
    Vendor/libgpod/m4/ltoptions.m4 \
    Vendor/libgpod/m4/ltsugar.m4 \
    Vendor/libgpod/m4/ltversion.m4 \
    'Vendor/libgpod/m4/lt~obsolete.m4' 2>/dev/null || true

if [ "$STATUS" -ne 0 ]; then
    echo
    echo "=== BUILD FAILED: CONCISE DIAGNOSTICS ==="
    grep -nE 'error:|warning:|BUILD FAILED|The following build commands failed' "$BUILD_LOG" | tail -n 140 || true
    echo "Full redacted build log: $BUILD_LOG"
    exit "$STATUS"
fi

APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/My Pod.app"
BIN="$APP/Contents/MacOS/My Pod"

if [ ! -x "$BIN" ]; then
    echo "ERROR: build succeeded but executable was not found:"
    echo "$BIN"
    exit 1
fi

echo
echo "=== VERIFY BUILT LAST.FM INTEGRATION ==="
PLIST="$APP/Contents/Info.plist"

CALLBACK="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$PLIST" 2>/dev/null || true)"
if [ -n "$CALLBACK" ]; then
    echo "WARNING: obsolete Last.fm callback URL scheme is still present: $CALLBACK"
else
    echo "PASS: no custom callback URL scheme; Last.fm desktop auth stays in the existing app instance"
fi

BUILT_API_KEY="$(/usr/libexec/PlistBuddy -c 'Print :LASTFM_API_KEY' "$PLIST" 2>/dev/null || true)"
BUILT_SECRET="$(/usr/libexec/PlistBuddy -c 'Print :LASTFM_SHARED_SECRET' "$PLIST" 2>/dev/null || true)"

if [ "$BUILT_API_KEY" = "$API_KEY" ] && [ "$BUILT_SECRET" = "$SHARED_SECRET" ]; then
    echo "PASS: build contains the supplied Last.fm application credentials"
else
    echo "WARNING: build succeeded, but the expected Last.fm plist values were not both found."
    echo "Do not reconnect Last.fm yet; inspect Config/MyPodInfo.plist / build settings."
fi

echo
echo "=== CREDENTIAL TEMP FILE CLEANUP ==="
cleanup
trap - EXIT HUP INT TERM
if [ -e "$TMP_XCCONFIG" ]; then
    echo "ERROR: temporary credential config still exists: $TMP_XCCONFIG"
    exit 1
fi
echo "PASS: temporary credential config deleted"

echo
echo "=== FINAL SOURCE STATE ==="
git status --short

echo
echo "=== LAUNCH EXACT BUILT APP BUNDLE ==="
pkill -x "My Pod" 2>/dev/null || true
sleep 1
"$BIN" &

echo "App: $APP"
echo "Redacted build log: $BUILD_LOG"
