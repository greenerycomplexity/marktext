#!/bin/zsh
# Runs a command on the MacBook Air ("air" in ~/.ssh/config, over Tailscale) so builds and tests
# don't load this Mac. Syncs sources there first, then copies result folders back.
#
# usage: Scripts/remote.sh <command ...>      (runs in the remote MarkText dir)
#   e.g. Scripts/remote.sh ./Scripts/ui-test.sh build/ui/c-typing/script.json
#        Scripts/remote.sh xcodebuild -project MarkText.xcodeproj -scheme MarkText -configuration Release -derivedDataPath build/DerivedData build
#
# Remote builds are ad-hoc signed (the Air has no Apple Development identity) via XCODE_XCCONFIG_FILE.
# REMOTE_RUN=1 is exported: scripts that start the app must then launch it with `open -g -W -n <app> --args ...`
# (LaunchServices puts it in the logged-in GUI session; a plain exec over ssh has no window server).
set -euo pipefail
HOST=${REMOTE_HOST:-air}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RDIR='~/MarkTextRemote/MarkText'

ssh -o BatchMode=yes "$HOST" "mkdir -p ~/MarkTextRemote/MarkText/build"
rsync -az --delete \
  --exclude 'build/' --exclude '.build/' --exclude '*.xcodeproj/xcuserdata' --exclude '.swiftpm/' \
  "$ROOT/" "$HOST:MarkTextRemote/MarkText/"

ssh -o BatchMode=yes "$HOST" "cat > ~/MarkTextRemote/adhoc.xcconfig" <<'EOF'
CODE_SIGN_IDENTITY = -
CODE_SIGN_STYLE = Manual
DEVELOPMENT_TEAM =
PROVISIONING_PROFILE_SPECIFIER =
EOF

CMD="$*"
set +e
ssh -o BatchMode=yes "$HOST" "/bin/zsh -lc 'export PATH=/opt/homebrew/bin:\$PATH; export REMOTE_RUN=1; export XCODE_XCCONFIG_FILE=\$HOME/MarkTextRemote/adhoc.xcconfig; cd $RDIR && ./Scripts/generate.sh >/dev/null && $CMD'"
STATUS=$?
set -e

# Bring back reports, screenshots and logs (never DerivedData).
rsync -az --exclude 'DerivedData/' --exclude 'vendor-src/' --exclude '*-spm/' --exclude 'editor-sandbox/' \
  "$HOST:MarkTextRemote/MarkText/build/" "$ROOT/build/remote/" 2>/dev/null || true
echo "remote exit: $STATUS (results in build/remote/)"
exit $STATUS
