#!/bin/zsh
# Regenerates MarkText.xcodeproj. Sets APPICON_NAME only when Resources/AppIcon.icon exists.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e Resources/AppIcon.icon ]]; then export APPICON_NAME=AppIcon; else export APPICON_NAME=""; echo "note: Resources/AppIcon.icon missing, no app icon wired"; fi
xcodegen generate --spec project.yml

# XcodeGen leaves <Testables> empty for local-package test targets; inject MarkTextKitTests into the scheme.
python3 - <<'PY'
p = "MarkText.xcodeproj/xcshareddata/xcschemes/MarkText.xcscheme"
s = open(p).read()
ref = '''      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "MarkTextKitTests"
               BuildableName = "MarkTextKitTests"
               BlueprintName = "MarkTextKitTests"
               ReferencedContainer = "container:Packages/MarkTextKit">
            </BuildableReference>
         </TestableReference>
      </Testables>'''
s = s.replace("      <Testables>\n      </Testables>", ref)
open(p, "w").write(s)
PY
