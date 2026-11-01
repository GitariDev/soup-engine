#!/bin/sh
# Every gate the polish climb must keep: sh tools/darkroom-gates.sh <samples dir>
# Runs from src/. Stops at the first failure and names it.
S="$1"
[ -d "$S" ] || { echo "usage: darkroom-gates.sh <samples dir>"; exit 2; }
export SOUP_SAMPLES="$S"
fail() { echo "GATE FAILED: $1"; exit 1; }

LINK=$(mktemp -d /tmp/soup-gates.XXXXXX)
ln -s "$S/IMG_3990.CR2" "$LINK/IMG_3990.CR2"

make test 2>&1 | tail -1 | grep -q "0 failures" || fail "engine selftest"
echo "ok   engine selftest"
make sim700d SIM700D_SAMPLE="$LINK/IMG_3990.CR2" 2>&1 | grep -q "the module writes what the desktop computes" || fail "sim700d"
echo "ok   sim700d"
make darkroom-test > "$LINK/t" 2>&1 || { grep -E "error:" "$LINK/t" | head; fail "swift test"; }
echo "ok   swift test: $(grep -cE "Test Case .* passed" "$LINK/t") passed, $(grep -cE "Test Case .* skipped" "$LINK/t") skipped"
make darkroom-parity S="$S" 2>&1 | tail -1 | grep -q "13 of 13 byte-identical" || fail "print parity"
echo "ok   parity 13 of 13"
make bench S="$S" > "$LINK/b" 2>&1 || { tail -5 "$LINK/b"; fail "fixture card"; }
echo "ok   fixture card"
make darkroom 2>&1 | grep -q "Soup Darkroom.app" || fail "app bundle"
sh tools/darkroom-walk.sh > "$LINK/w" 2>&1 || { cat "$LINK/w"; fail "walk"; }
python3 -I tools/darkroom-walk-check.py out/walk/log.jsonl out/walk/prints.txt || fail "walk assertions"
echo "ok   walk"
git -C .. ls-files -o --exclude-standard | grep -iE '\.(cr2|jpe?g)$' && fail "a photo is about to be tracked"
git -C .. ls-files | grep -iE '\.(cr2)$' && fail "a CR2 is tracked"
rm -rf "$LINK"
echo "all gates pass"
