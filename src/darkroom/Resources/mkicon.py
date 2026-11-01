#!/usr/bin/env python3
"""mkicon.py <out.icns>: the app's icon, drawn here with no photos in it.

An amber ring on the app's dark ground, the colours of Enlarger Bench v4.
Needs only Python, sips and iconutil.
"""
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

SIZE = 1024
GROUND = (0x08, 0x08, 0x0c)
AMBER = (0xf4, 0xb4, 0x5c)
PLATE = 824 / 2         # half width of the rounded plate, Apple's icon grid
CORNER = 185
RING = 262              # radius of the ring's centre line
WIDTH = 34              # half its thickness


def clamp(v):
    return min(1.0, max(0.0, v))


def pixel(x, y):
    px, py = abs(x) - PLATE + CORNER, abs(y) - PLATE + CORNER
    plate = math.hypot(max(px, 0), max(py, 0)) + min(max(px, py), 0) - CORNER
    alpha = clamp(0.5 - plate)
    if alpha == 0:
        return b"\0\0\0\0"
    edge = abs(math.hypot(x, y) - RING) - WIDTH
    ring = clamp(0.5 - edge)
    glow = 0.30 * math.exp(-max(edge, 0) / 46)     # the safelight on the wall
    mix = max(ring, glow)
    r, g, b = (round(c + (a - c) * mix) for c, a in zip(GROUND, AMBER))
    return bytes((r, g, b, round(alpha * 255)))


def png():
    half = SIZE / 2 - 0.5
    rows = (b"\0" + b"".join(pixel(x - half, y - half) for x in range(SIZE)) for y in range(SIZE))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 6))
            + chunk(b"IEND", b""))


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: mkicon.py <out.icns>")
    work = tempfile.mkdtemp(prefix="soup-icon-")
    try:
        iconset = os.path.join(work, "SoupDarkroom.iconset")
        os.mkdir(iconset)
        master = os.path.join(iconset, "icon_512x512@2x.png")
        with open(master, "wb") as f:
            f.write(png())
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                if size * scale == SIZE:
                    continue
                name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
                subprocess.run(["sips", "-z", str(size * scale), str(size * scale), master,
                                "--out", os.path.join(iconset, name)],
                               check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", sys.argv[1]], check=True)
    finally:
        shutil.rmtree(work)


main()
