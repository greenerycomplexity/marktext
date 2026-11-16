#!/bin/zsh
# Runs a keyboard-level UI script in the background (never activates the app).
# usage: Scripts/ui-test.sh <script.json> [outdir]   (NOBUILD=1 skips the build)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$1"; OUT="${2:-$ROOT/build/ui/$(basename "$SCRIPT" .json)}"
APP="$ROOT/build/${DD:-DerivedData}/Build/Products/Debug/MarkText.app/Contents/MacOS/MarkText"
if [[ -z "${NOBUILD:-}" ]]; then
  xcodebuild -project "$ROOT/MarkText.xcodeproj" -scheme MarkText -configuration Debug -derivedDataPath "$ROOT/build/${DD:-DerivedData}" build -quiet > "$ROOT/build/ui-build.log" 2>&1 || { tail -20 "$ROOT/build/ui-build.log"; exit 1; }
fi
rm -rf "$OUT"; mkdir -p "$OUT/fixture"
# Scripts edit a *copy* of the showcase fixture (autosave in place would otherwise rewrite the original).
cp -R "$ROOT/Packages/MarkTextKit/Tests/MarkTextKitTests/Fixtures/." "$OUT/fixture/"
RUN="$OUT/script.json"; sed "s#__FIXTURE__#$OUT/fixture#g" "$SCRIPT" > "$RUN"; SCRIPT="$RUN"
if [[ -n "${REMOTE_RUN:-}" ]]; then
  # Over ssh there is no window server: LaunchServices starts the app in the logged-in GUI session.
  open -g -W -n --stderr "$OUT/app.log" "$ROOT/build/${DD:-DerivedData}/Build/Products/Debug/MarkText.app" --args --ui-script "$SCRIPT" --out "$OUT" ${=EXTRA_ARGS:-} &
  sleep 1.5; PID=$(pgrep -n -f "MarkText.app/Contents/MacOS/MarkText --ui-script" || echo 999999)
else
  "$APP" --ui-script "$SCRIPT" --out "$OUT" ${=EXTRA_ARGS:-} 2> "$OUT/app.log" &
  PID=$!
fi
cleanup() { kill $PID 2>/dev/null || true; sleep 0.2; kill -9 $PID 2>/dev/null || true; pkill -9 -f "MarkText.app/Contents/MacOS/MarkText --ui-script" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
for _ in {1..750}; do [[ -s "$OUT/ui-report.json" ]] && break; kill -0 $PID 2>/dev/null || break; sleep 0.2; done
sleep 0.3
python3 - "$OUT/ui-report.json" <<'PY'
import json,sys
try: r=json.load(open(sys.argv[1]))
except Exception as e: print("NO REPORT", e); sys.exit(1)
for a in r["assertions"]: print(("PASS " if a["pass"] else "FAIL ")+a["name"]+("" if a["pass"] else "  -> "+a["detail"]))
print("stalls >100ms:", len(r["stalls"]), [ (int(s["ms"]), "cpu %d" % s.get("cpuMs", -1), s["step"][:28]) for s in r["stalls"]][:8])
print("metrics:", json.dumps(r["metrics"]))
if r.get("vars"): print("vars:", json.dumps(r["vars"]))
for k in r.get("keyLog",[]): print("key:", k)
print("RESULT", "PASS" if r["pass"] else "FAIL")
sys.exit(0 if r["pass"] else 1)
PY
