#!/bin/sh
# mkbench.sh <samples dir> [outdir]
#
# Builds a fixture card in src/out/bench-card/ from real frames, then checks it
# with `darkroomctl scan`. Every sample goes in as a clone. See tools/mkbench.py.
exec python3 "$(dirname "$0")/mkbench.py" "$@"
