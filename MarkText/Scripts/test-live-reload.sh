#!/bin/zsh
# Verifies NSDocument auto-revert of a clean document when the file changes on disk,
# and that the app never rewrites the file. Runs headless (accessory app, window ordered back).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DerivedData/Build/Products/Debug/MarkText.app/Contents/MacOS/MarkText"
T="$(mktemp -d)"; F="$T/live.md"; OUT="$T/out"
printf '# Live reload\n\nORIGINAL-BODY\n' > "$F"
if [[ -n "${REMOTE_RUN:-}" ]]; then
  open -g -W -n --stderr "$T/app.log" "$ROOT/build/DerivedData/Build/Products/Debug/MarkText.app" --args --snapshot "$F" --out "$OUT" --hold 12 &
  sleep 1.5; PID=$(pgrep -n -f "MarkText.app/Contents/MacOS/MarkText --snapshot" || echo 0)
else
  "$APP" --snapshot "$F" --out "$OUT" --hold 12 2> "$T/app.log" &
  PID=$!
fi; trap 'kill $PID 2>/dev/null || true' EXIT
for _ in {1..100}; do [[ -s "$OUT/dom.json" ]] && break; sleep 0.1; done
grep -q ORIGINAL-BODY "$OUT/dom.json" || { echo "FAIL: initial render missing"; cat "$T/app.log"; exit 1; }
R0=$(python3 -c "import json;print(json.load(open('$OUT/dom.json'))['renderedCount'])")
sleep 1
# external edit from the shell (like an editor, git pull or an AI agent)
printf '\nAPPENDED-TOKEN-%s\n' "$$" >> "$F"
SHA1=$(shasum "$F" | cut -d' ' -f1); M1=$(stat -f %m.%N "$F" 2>/dev/null || stat -f %m "$F")
M1=$(stat -f %Fm "$F")
ok=""
for _ in {1..80}; do
  if grep -q "APPENDED-TOKEN-$$" "$OUT/dom.json" 2>/dev/null; then ok=1; break; fi; sleep 0.1
done
sleep 1.5   # give a would-be autosave time to happen
SHA2=$(shasum "$F" | cut -d' ' -f1); M2=$(stat -f %Fm "$F")
R1=$(python3 -c "import json;print(json.load(open('$OUT/dom.json'))['renderedCount'])")
reads=$(grep -c "document read" "$T/app.log" || true)
echo "renderedCount $R0 -> $R1; document reads: $reads"
echo "file sha unchanged by app: $([[ $SHA1 == $SHA2 ]] && echo yes || echo NO); mtime unchanged by app: $([[ $M1 == $M2 ]] && echo yes || echo NO)"
cat "$T/app.log" | sed 's/^/  log: /'
[[ -n "$ok" && $SHA1 == $SHA2 && $M1 == $M2 && $R1 -gt $R0 ]] && echo "PASS: auto-revert + re-render, file untouched" || { echo "FAIL"; exit 1; }
