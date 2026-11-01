#!/usr/bin/env python3
"""Is there anything on the strip? The bottom 90 points of a 2x window capture.
Uses sips, so it needs nothing installed. Prints the brightest level found."""
import struct, subprocess, sys, tempfile, os

png = sys.argv[1]
want_blank = len(sys.argv) > 2 and sys.argv[2] == "blank"
with tempfile.TemporaryDirectory() as d:
    bmp = os.path.join(d, "s.bmp")
    subprocess.run(["sips", "-s", "format", "bmp", png, "--out", bmp], capture_output=True, check=True)
    b = open(bmp, "rb").read()
off, = struct.unpack_from("<I", b, 10)
w, h, _, bpp = struct.unpack_from("<iiHH", b, 18)
step = bpp // 8
row = (w * step + 3) & ~3
top_down = h < 0
h = abs(h)
peak = 0
for y in range(0, 180, 3):                       # the strip's 90 points, every third row
    at = off + (y if not top_down else h - 1 - y) * row
    for x in range(0, w, 6):
        p = b[at + x * step : at + x * step + 3]
        peak = max(peak, *p)
print(f"strip peak {peak}")
sys.exit(0 if (peak < 40) == want_blank else 1)
