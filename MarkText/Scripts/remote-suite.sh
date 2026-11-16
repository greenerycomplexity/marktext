# Run on the Air through Scripts/remote.sh: builds the optimized Debug app, then runs every UI script ROUNDS times.
cd ~/MarkTextRemote/MarkText
xcodebuild -project MarkText.xcodeproj -scheme MarkText -configuration Debug -derivedDataPath build/DerivedOpt SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule build > build/opt-build.log 2>&1; echo "opt build xc=$?"
grep -E " error: " build/opt-build.log | head
for round in $(seq 1 ${ROUNDS:-3}); do
  echo "== round $round"
  for t in a-close-unsaved b-settings c-type-split d-scroll-read e-idle f-menus-and-keys g-quit-clean h-quit-unsaved i-new-open-close i2-close-autosaves j-open-stall k-real-keys-read-focus k-real-keys-edit-focus l-sidebar-toggle; do
    echo "$t: $(DD=DerivedOpt NOBUILD=1 ./Scripts/ui-test.sh Scripts/ui/$t.json $PWD/build/ui/$t-r$round 2>&1 | grep -E 'FAIL|RESULT|^stalls' | tr '\n' ' ' | cut -c1-520)"
  done
done
pkill -f "MarkTextRemote/.*MarkText.app/Contents/MacOS/MarkText" 2>/dev/null; echo SUITE-DONE
