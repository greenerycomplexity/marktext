#!/bin/zsh
# Window screenshot of the optimized Debug build, for runs started over ssh (see remote.sh).
# usage: Scripts/remote-snapshot.sh <name> [harness args, e.g. --mode read --theme light --popover]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="$1"; shift
OUT="$ROOT/build/shots/$NAME"; rm -rf "$OUT"; mkdir -p "$OUT"
FILE="$ROOT/Packages/MarkTextKit/Tests/MarkTextKitTests/Fixtures/${FIXTURE:-showcase.md}"
open -g -n --stderr "$OUT/app.log" "$ROOT/build/${DD:-DerivedOpt}/Build/Products/Debug/MarkText.app" --args --snapshot "$FILE" --out "$OUT" --hold 5 --size 1100x800 "$@"
for _ in {1..150}; do [[ -s "$OUT/tier-a-done.txt" ]] && break; sleep 0.1; done
for _ in {1..40}; do [[ -s "$OUT/window.png" ]] && break; sleep 0.1; done
sleep 1; pkill -f "MarkText.app/Contents/MacOS/MarkText --snapshot" 2>/dev/null
ls -la "$OUT" | grep png
