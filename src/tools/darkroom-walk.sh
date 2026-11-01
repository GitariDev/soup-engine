#!/bin/sh
# Run the real app through tools/darkroom-walk.txt on the fixture card, with a
# throwaway record and save folder, and leave pictures in out/walk: they hold
# photos, so they stay in an ignored folder.
#
#   sh tools/darkroom-walk.sh [script]        WALK_OUT=<dir> to put it elsewhere
#
# Run directly, not through open(1): a window that is not key takes no clicks,
# which the driver works round, and a walk should not take the screen from
# whoever is using the Mac.
set -e
SCRIPT="${1:-tools/darkroom-walk.txt}"
case "$SCRIPT" in /*) ;; *) SCRIPT="$PWD/$SCRIPT";; esac
CARD="$PWD/out/bench-card"
APP="out/Soup Darkroom.app/Contents/MacOS/SoupDarkroom"
OUT="${WALK_OUT:-$PWD/out/walk}"
[ -d "$CARD" ] || { echo "walk: no fixture card; run make bench S=<samples>"; exit 2; }
[ -x "$APP" ] || { echo "walk: no app; run make darkroom"; exit 2; }

WORK=$(mktemp -d /tmp/soup-walk.XXXXXX)
rm -rf "$OUT"; mkdir -p "$OUT"
SOUP_SUPPORT="$WORK/support" SOUP_SHOTS="$OUT" SOUP_SAVE="$WORK/prints" \
    "$APP" --open "$CARD" --drive "$SCRIPT" > "$OUT/log.jsonl" 2> "$OUT/err.txt" || true
ls "$WORK/prints" 2>/dev/null > "$OUT/prints.txt" || true
rm -rf "$WORK"
echo "$(grep -c . "$OUT/log.jsonl") dumps in $OUT/log.jsonl"
if grep -q driveError "$OUT/log.jsonl"; then grep driveError "$OUT/log.jsonl"; exit 1; fi
