#!/bin/sh
# Run the real app through tools/darkroom-walk.txt on the fixture card, with a
# throwaway record and save folder, and leave pictures in out/walk: they hold
# photos, so they stay in an ignored folder.
#
#   sh tools/darkroom-walk.sh [script]
set -e
SCRIPT="${1:-tools/darkroom-walk.txt}"
case "$SCRIPT" in /*) ;; *) SCRIPT="$PWD/$SCRIPT";; esac
CARD="$PWD/out/bench-card"
APP="out/Soup Darkroom.app"
[ -d "$CARD" ] || { echo "walk: no fixture card; run make bench S=<samples>"; exit 2; }
[ -d "$APP" ] || { echo "walk: no app; run make darkroom"; exit 2; }

WORK=$(mktemp -d /tmp/soup-walk.XXXXXX)
rm -rf out/walk; mkdir -p out/walk
# Through open(1), so the app comes to the front: a click on a window that is
# not key is only an activation, and a drag would never reach the view.
open -W -n --env SOUP_SUPPORT="$WORK/support" --env SOUP_SHOTS="$PWD/out/walk" --env SOUP_SAVE="$WORK/prints" \
    --stdout "$PWD/out/walk/log.jsonl" --stderr "$PWD/out/walk/err.txt" \
    "$APP" --args --open "$CARD" --drive "$SCRIPT" || true
ls "$WORK/prints" 2>/dev/null > out/walk/prints.txt || true
rm -rf "$WORK"
grep -c . out/walk/log.jsonl | sed 's/$/ dumps in out\/walk\/log.jsonl/'
if grep -q driveError out/walk/log.jsonl; then grep driveError out/walk/log.jsonl; exit 1; fi
