#!/bin/sh
# darkroom-parity.sh <samples dir> [frame]
#
# A print from the desktop app must be the same file as `filmdev looks
# --from-raw` makes of the same frame on the same film: same bytes, not just
# the same look. Run it on a landscape frame, since the app also carries the
# orientation and filmdev does not.
#
# Output goes under src/out/, which is ignored: these are the owner's photos.
set -eu

[ $# -ge 1 ] || { echo "usage: $0 <samples dir> [IMG_3990.CR2]" >&2; exit 2; }
SRC=$(cd "$(dirname "$0")/.." && pwd)
FRAME=$1/${2:-IMG_3990.CR2}
OUT=$SRC/out/darkroom-parity
CTL=$SRC/darkroom/.build-engine/release/darkroomctl

[ -f "$FRAME" ] || { echo "no frame at $FRAME" >&2; exit 2; }

make -C "$SRC" all
(cd "$SRC/darkroom" && swift build -c release --build-path .build-engine --product darkroomctl)

rm -rf "$OUT"
mkdir -p "$OUT/filmdev" "$OUT/darkroom"

(cd "$SRC" && ./filmdev looks "$FRAME" "$OUT/filmdev" --from-raw)
WROTE=$(ls "$OUT/filmdev" | wc -l | tr -d ' ')
[ "$WROTE" -eq 13 ] || { echo "filmdev wrote $WROTE stocks, expected 13" >&2; exit 1; }

BAD=0
for FS in "$SRC"/stocks/*.fs; do
    NAME=$(sed -n 's/^NAME[[:space:]]*//p' "$FS" | head -1 | tr ' /\\' '___')
    "$CTL" print "$FRAME" "$FS" "$OUT/darkroom" --name "$NAME.jpg" >/dev/null
    if cmp "$OUT/filmdev/$NAME.jpg" "$OUT/darkroom/$NAME.jpg"; then
        echo "  same  $NAME"
    else
        echo "  DIFF  $NAME"
        BAD=$((BAD + 1))
    fi
done

[ "$BAD" -eq 0 ] || { echo "$BAD of $WROTE differ" >&2; exit 1; }
echo "$WROTE of $WROTE byte-identical to filmdev looks --from-raw"
