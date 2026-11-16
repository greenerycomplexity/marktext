#!/bin/zsh
# Headless Quick Look preview check: QLPreviewView in an ordered-back window of the installed dev app,
# captured with screencapture -l. Requires Scripts/install-dev.sh to have run.
# usage: Scripts/ql-preview.sh <file.md> <outdir>
set -euo pipefail
FILE="$1"; OUT="$2"; rm -rf "$OUT"; mkdir -p "$OUT"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-$ROOT/build/DerivedData/Build/Products/Debug/MarkText.app/Contents/MacOS/MarkText}"
"$APP" --snapshot "$FILE" --out "$OUT" --quicklook --hold 10 2> "$OUT/app.log" &
PID=$!; trap 'kill $PID 2>/dev/null || true' EXIT
for _ in {1..100}; do [[ -s "$OUT/window-id.txt" ]] && break; sleep 0.1; done
sleep 7   # first run after install is slow (extension cold start)
screencapture -x -o -l "$(cat "$OUT/window-id.txt")" "$OUT/quicklook.png"
wait $PID
echo "$OUT/quicklook.png"
