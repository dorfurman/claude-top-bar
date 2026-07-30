#!/usr/bin/env python3
"""Decode the baked Clawd frames back into pixel grids, for studying the art and
authoring new animations. Renders frames as PNG contact sheets and text art.

usage: tools/anim_lab.py sheet out.png      # all 43 original frames
       tools/anim_lab.py text N             # frame N as text art
"""
import re
import struct
import sys
import zlib
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "Sources" / "Clawd.swift"

# original palette: 0 black (eyes/mouth), 1 body, 2 shade, 3 gray (laptop)
RGB = [(0, 0, 0), (0xD8, 0x76, 0x56), (0xBE, 0x68, 0x4D), (0x8B, 0x8B, 0x8B)]


def load():
    text = SRC.read_text()
    frames = int(re.search(r"frames = (\d+)", text).group(1))
    w, h = map(int, re.search(r"cellsWide = (\d+), cellsHigh = (\d+)", text).groups())
    groups = []
    for m in re.finditer(r"\((\d+), 0x([0-9a-f]+), \[([\d, ]+)\]\)", text):
        ci, mask, quads = int(m.group(1)), int(m.group(2), 16), [int(v) for v in m.group(3).split(",")]
        groups.append((ci, mask, quads))
    return frames, w, h, groups


def grid(frame, w, h, groups):
    """Frame as rows of colour indices, -1 = transparent."""
    g = [[-1] * w for _ in range(h)]
    for ci, mask, quads in groups:
        if not mask >> frame & 1:
            continue
        for i in range(0, len(quads), 4):
            x, y, qw, qh = quads[i:i + 4]
            for yy in range(y, y + qh):
                for xx in range(x, x + qw):
                    g[yy][xx] = ci
    return g


def png(path, pixels, w, h):
    """Minimal RGBA PNG writer — stdlib only."""
    raw = b"".join(b"\0" + b"".join(
        bytes(RGB[p] + (255,)) if p >= 0 else b"\0\0\0\0" for p in row) for row in pixels)

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

    Path(path).write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b""))


def upscale(g, f=8):
    return [[p for p in row for _ in range(f)] for row in g for _ in range(f)]


if __name__ == "__main__":
    frames, w, h, groups = load()
    if sys.argv[1] == "text":
        g = grid(int(sys.argv[2]), w, h, groups)
        chars = {-1: "·", 0: "#", 1: "O", 2: "o", 3: "L"}
        print("\n".join("".join(chars[p] for p in row) for row in g))
    elif sys.argv[1] == "sheet":
        cols, scale = 8, 6
        rows = (frames + cols - 1) // cols
        sheet = [[-1] * (cols * (w + 2) * scale) for _ in range(rows * (h + 2) * scale)]
        for f in range(frames):
            g = upscale(grid(f, w, h, groups), scale)
            ox, oy = (f % cols) * (w + 2) * scale, (f // cols) * (h + 2) * scale
            for yy, row in enumerate(g):
                sheet[oy + yy][ox:ox + len(row)] = row
        png(sys.argv[2], sheet, len(sheet[0]), len(sheet))
        print(f"wrote {sys.argv[2]} ({frames} frames)")
