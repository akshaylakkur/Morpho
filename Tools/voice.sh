#!/bin/zsh
#
# Build, bundle, and launch Morpho Voice — the relay that listens on the Mac's
# microphone, transcribes on-device, and streams the words into the iPhone Duo
# simulator (whose own speech models don't run). Leave it running while
# demoing; Morpho picks it up automatically.
#
#   Tools/voice.sh                     relay for the simulator (Ctrl-C stops it)
#   Tools/voice.sh --listen            print live transcription here, no simulator
#   Tools/voice.sh --selftest "phrase" synthesize a phrase, transcribe, compare
#
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
package="$here/MorphoVoice"
app="$package/.build/Morpho Voice.app"
binary="$app/Contents/MacOS/MorphoVoice"
log="$HOME/Library/Logs/MorphoVoice.log"

cd "$package"
swift build -c release 2>&1 | grep -E "error:|Build complete" || true
mkdir -p "$app/Contents/MacOS"
cp .build/release/MorphoVoice "$binary"
cp Info.plist "$app/Contents/Info.plist"
# A real Apple Development identity keeps the microphone grant stable across rebuilds; ad-hoc otherwise.
identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
codesign --force --sign "${identity:--}" "$app" >/dev/null 2>&1 || codesign --force --sign - "$app" >/dev/null 2>&1

pkill -f "$binary" >/dev/null 2>&1 || true
: > "$log"
echo "Morpho Voice · log: $log"
# Launched through LaunchServices so the microphone prompt is attributed to "Morpho Voice".
open -n -W --stdout "$log" --stderr "$log" "$app" --args "$@" &
open_pid=$!
tail -f "$log" &
tail_pid=$!
trap 'pkill -f "$binary" >/dev/null 2>&1 || true; kill $tail_pid >/dev/null 2>&1 || true' INT TERM EXIT
wait $open_pid
