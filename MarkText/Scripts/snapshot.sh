#!/bin/zsh
# Tier A + B snapshot. Never activates the app and never touches the user's Space.
# usage: Scripts/snapshot.sh <file.md> <outdir> [extra harness args, e.g. --theme dark --size 1100x760]
#   NOBUILD=1 skips the build step.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$1"; OUT="$2"; shift 2
APP="$ROOT/build/DerivedData/Build/Products/Debug/MarkText.app"
if [[ -z "${NOBUILD:-}" ]]; then
  xcodebuild -project "$ROOT/MarkText.xcodeproj" -scheme MarkText -configuration Debug \
    -derivedDataPath "$ROOT/build/DerivedData" build -quiet > "$ROOT/build/snapshot-build.log" 2>&1 \
    || { tail -30 "$ROOT/build/snapshot-build.log"; exit 1; }
fi
rm -rf "$OUT"; mkdir -p "$OUT"
"$APP/Contents/MacOS/MarkText" --snapshot "$FILE" --out "$OUT" --hold "${HOLD:-3}" "$@" 2> "$OUT/app.log" &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT
for _ in {1..100}; do [[ -s "$OUT/window-id.txt" ]] && break; sleep 0.1; done
[[ -s "$OUT/window-id.txt" ]] || { echo "no window-id.txt"; cat "$OUT/app.log"; exit 1; }
# wait for tier-A artifacts so the page has rendered before the OS capture
for _ in {1..120}; do [[ -s "$OUT/tier-a-done.txt" ]] && break; sleep 0.1; done
sleep 0.5
WID="$(cat "$OUT/window-id.txt")"
screencapture -x -o -l "$WID" "$OUT/window.png" || echo "screencapture failed"
# extra windows (popover): capture each separately
if [[ -s "$OUT/extra-windows.txt" ]]; then
  n=0; while IFS=$'\t' read -r id _ || [[ -n $id ]]; do n=$((n+1)); screencapture -x -o -l "$id" "$OUT/extra-$n.png" 2>/dev/null || true; done < "$OUT/extra-windows.txt"
fi
wait $PID
echo "tier A: $OUT/webview.png $OUT/dom.json   tier B: $OUT/window.png (window $WID)"
