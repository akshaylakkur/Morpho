#!/bin/zsh
#
# Build, bundle, and launch Morpho Tether — the relay that carries a USB-attached
# iPhone's video into the iPhone Duo simulator. Leave it running while demoing;
# Morpho picks it up automatically. Any MorphoTether option passes through,
# e.g. `Tools/tether.sh --list` or `Tools/tether.sh --crop 0,0.12,1,0.66`.
#
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
package="$here/MorphoTether"
app="$package/.build/Morpho Tether.app"
binary="$app/Contents/MacOS/MorphoTether"
log="$HOME/Library/Logs/MorphoTether.log"

cd "$package"
swift build -c release 2>&1 | grep -E "error:|Build complete" || true
mkdir -p "$app/Contents/MacOS"
cp .build/release/MorphoTether "$binary"
cp Info.plist "$app/Contents/Info.plist"
# A real Apple Development identity keeps the camera grant stable across rebuilds; ad-hoc otherwise.
identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
codesign --force --sign "${identity:--}" "$app" >/dev/null 2>&1 || codesign --force --sign - "$app" >/dev/null 2>&1

pkill -f "$binary" >/dev/null 2>&1 || true
: > "$log"
echo "Morpho Tether · log: $log"
open -n -W --stdout "$log" --stderr "$log" "$app" --args "$@" &
open_pid=$!
tail -f "$log" &
tail_pid=$!
trap 'pkill -f "$binary" >/dev/null 2>&1 || true; kill $tail_pid >/dev/null 2>&1 || true' INT TERM EXIT
wait $open_pid
