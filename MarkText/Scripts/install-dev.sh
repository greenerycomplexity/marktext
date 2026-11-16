#!/bin/zsh
# Copies the Debug build to ~/Applications/MarkText Dev.app (never /Applications) and registers the Quick Look extension.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/DerivedData/Build/Products/Debug/MarkText.app"
DST="$HOME/Applications/MarkText Dev.app"
[[ -d "$SRC" ]] || { echo "build first: xcodebuild -project MarkText/MarkText.xcodeproj -scheme MarkText -configuration Debug -derivedDataPath MarkText/build/DerivedData build"; exit 1; }
mkdir -p "$HOME/Applications"
rsync -a --delete "$SRC/" "$DST/"
APPEX="$DST/Contents/PlugIns/MarkTextQuickLook.appex"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -f "$DST"
pluginkit -a "$APPEX"
pluginkit -e use -i io.github.greenerycomplexity.MarkText.QuickLook || true
pluginkit -m -v -i io.github.greenerycomplexity.MarkText.QuickLook
qlmanage -r > /dev/null 2>&1 || true
qlmanage -r cache > /dev/null 2>&1 || true
echo "installed $DST"
