#!/usr/bin/env python3
"""Author new pixel-level Clawd animations out of the original art's parts.

Reads the baked rest pose from Clawd.swift (via anim_lab), rebuilds the crab from
named pieces (body, eyes, arms, legs), and composes new 43-frame sequences pose by
pose — the same length as the original cycle so the badge timing code never changes.
Emits Sources/ClawdAnims.swift plus a preview sheet per animation.

usage: tools/make_anims.py [preview_dir]
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from anim_lab import load, grid, png, upscale

FRAMES_, W, H, GROUPS = load()
BASE = grid(0, W, H, GROUPS)          # the rest pose
N = 43                                 # every animation matches the original length
BODY, SHADE, GRAY, BLACK = 1, 2, 3, 0
EYES = [(6, 9), (16, 9)]               # 2x2 black, top-left corners
LEG_XS = [4, 8, 14, 18]                # 2-wide legs, rows 19-22
ARM_L = (0, 3)                         # arm nubs: x ranges within rows 11-14
ARM_R = (20, 23)


def cells(g):
    return [(x, y, c) for y, row in enumerate(g) for x, c in enumerate(row) if c >= 0]


CRAB = cells(BASE)


def compose(dx=0, dy=0, eyes="open", legs="all", arms="down", extra=()):
    """One frame: the crab rebuilt from variant pieces, shifted, plus loose pixels."""
    g = [[-1] * W for _ in range(H)]
    for x, y, c in CRAB:
        # eyes and arms are redrawn from variants, so skip the originals
        if any(ex <= x < ex + 2 and ey <= y < ey + 2 for ex, ey in EYES):
            c = BODY
        # a raised arm loses the lower half of its nub; the top half stays as the shoulder
        if arms != "down" and 13 <= y <= 14 and (x <= ARM_L[1] or x >= ARM_R[0]):
            arm = "left" if x <= ARM_L[1] else "right"
            if (arms == "up") or (arms == arm):
                continue
        if y >= 19:  # legs
            leg = LEG_XS.index(next(lx for lx in LEG_XS if lx <= x <= lx + 1))
            lifted = {"all": [], "even": [0, 2], "odd": [1, 3], "tuck": [0, 1, 2, 3]}[legs]
            if leg in lifted and y >= 21:
                continue
        px, py = x + dx, y + dy
        if 0 <= px < W and 0 <= py < H:
            g[py][px] = c

    def put(x, y, c=GRAY):
        if 0 <= x < W and 0 <= y < H:
            g[y][x] = c

    def rect(x, y, w, h, c):
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                put(xx, yy, c)

    for ex, ey in EYES:
        x, y = ex + dx, ey + dy
        if eyes == "open":
            rect(x, y, 2, 2, BLACK)
        elif eyes == "half":         # drooping
            rect(x, y + 1, 2, 2, BLACK)
        elif eyes == "closed":       # a lid line
            rect(x, y + 1, 2, 1, BLACK)
        elif eyes == "up":
            rect(x, y - 1, 2, 2, BLACK)

    if arms in ("up", "left"):  # raised left claw, joined to the shoulder stub
        rect(0 + dx, 6 + dy, 2, 5, BODY)
        rect(0 + dx, 4 + dy, 3, 2, BODY)
        put(2 + dx, 5 + dy, -1)          # claw notch
    if arms in ("up", "right"):
        rect(22 + dx, 6 + dy, 2, 5, BODY)
        rect(21 + dx, 4 + dy, 3, 2, BODY)
        put(21 + dx, 5 + dy, -1)

    for x, y, *c in extra:
        put(x, y, c[0] if c else GRAY)
    return g


def hold(frames, seq, n):
    frames.extend([seq] * n) if isinstance(seq, list) and seq and isinstance(seq[0], list) \
        else None
    return frames


# --- sprites drawn as loose pixels -------------------------------------------------

def bubble(cx, cy, stage):
    """Growing gray bubble: dot -> ring -> big ring -> pop."""
    if stage == 0:
        return [(cx, cy), (cx + 1, cy), (cx, cy + 1), (cx + 1, cy + 1)]
    if stage == 1:
        return [(cx + i, cy - 1) for i in range(2)] + [(cx + i, cy + 2) for i in range(2)] \
            + [(cx - 1, cy), (cx - 1, cy + 1), (cx + 2, cy), (cx + 2, cy + 1)]
    if stage == 2:
        return [(cx + i, cy - 2) for i in range(2)] + [(cx + i, cy + 3) for i in range(2)] \
            + [(cx - 2, cy), (cx - 2, cy + 1), (cx + 3, cy), (cx + 3, cy + 1)] \
            + [(cx - 1, cy - 1), (cx + 2, cy - 1), (cx - 1, cy + 2), (cx + 2, cy + 2)]
    return [(cx - 2, cy - 2), (cx + 3, cy - 2), (cx - 2, cy + 3), (cx + 3, cy + 3)]


def zee(cx, cy, big=False):
    """A pixel Z with its top-left at (cx, cy)."""
    n = 4 if big else 3
    pts = [(cx + i, cy) for i in range(n)] + [(cx + i, cy + n - 1) for i in range(n)]
    pts += [(cx + n - 2, cy + 1), (cx + 1, cy + n - 2)] if big else [(cx + 1, cy + 1)]
    return pts


def sparkles(k):
    sets = [[(2, 3), (27, 6), (13, 1)], [(5, 1), (30, 3), (20, 0)], [(0, 6), (25, 1), (10, 3)]]
    return sets[k % len(sets)]


# --- the animations, 43 frames each -------------------------------------------------

def scuttle():
    f, rest = [], compose()
    f += [rest] * 2
    f.append(compose(dy=1, legs="tuck"))                     # anticipation
    for i, dx in enumerate([2, 4, 6, 8, 10]):                # dash right, dust behind
        dust = [(dx - 3, 21), (dx - 5, 19), (dx - 2, 22)]
        f.append(compose(dx=dx, dy=-(i % 2), legs="even" if i % 2 else "odd", extra=dust))
    f += [compose(dx=10)] * 2                                # arrive
    f += [compose(dx=10, eyes="closed")] * 2                 # blink
    f += [compose(dx=10)] * 2
    for i, dx in enumerate([8, 6, 4, 2, 0]):                 # dash back
        dust = [(dx + 26, 21), (dx + 28, 19), (dx + 25, 22)]
        f.append(compose(dx=dx, dy=-(i % 2), legs="odd" if i % 2 else "even", extra=dust))
    f.append(compose(dy=1, legs="tuck"))                     # settle
    f += [rest] * (N - len(f))
    return f


def bubbles():
    f = [compose()] * 3
    paths = [(20, 3, [0, 1, 0, -1]), (16, 16, [0, -1, 0, 1]), (21, 28, [1, 0, -1, 0])]
    for i in range(3, N):
        extra = []
        looking = False
        for bx, start, wob in paths:
            age = i - start
            if 0 <= age <= 13:
                looking = True
                stage = min(3, age // 4)
                cy = 6 - (age * 3) // 4  # drifts up from just above the head
                extra += bubble(bx + wob[age % 4], cy, stage)
        f.append(compose(eyes="up" if looking else "open", extra=extra))
    return f


def snooze():
    f = [compose()] * 2
    f += [compose(eyes="half")] * 3
    for i in range(5, N - 4):
        extra = []
        for start, big, zx in [(5, False, 25), (14, True, 27), (23, False, 24),
                               (32, True, 26)]:
            age = i - start
            if 0 <= age <= 8:
                extra += zee(zx + (age % 3) - 1, 9 - age, big)
        f.append(compose(eyes="closed", extra=extra))
    f += [compose(eyes="half")] * 2
    f += [compose()] * 2
    return f


def rave():
    f, rest = [], compose()
    f += [rest] * 2
    f.append(compose(arms="up"))
    for k in range(6):                                        # alternate claws, bob along
        pose = compose(arms="left" if k % 2 else "right", dy=k % 2,
                       legs="odd" if k % 2 else "even", extra=sparkles(k))
        f += [pose] * 3
    for k in range(4):                                        # big finish: both claws
        f += [compose(arms="up", dy=k % 2, eyes="closed" if k >= 2 else "open",
                      extra=sparkles(k))] * 2
    f += [compose(arms="up")] * 2
    f += [rest] * (N - len(f) - 1)
    f.append(rest)
    return f


def jump():
    f, rest = [], compose()
    f += [rest] * 3
    f += [compose(dy=2, legs="tuck", eyes="half")] * 3        # crouch
    for dy, legs in [(-2, "all"), (-4, "tuck"), (-6, "tuck")]:
        f.append(compose(dy=dy, legs=legs))
    f += [compose(dy=-6, legs="tuck", extra=sparkles(0))] * 2  # hang time
    f += [compose(dy=-6, legs="tuck", extra=sparkles(1))] * 2
    for dy in (-4, -2):
        f.append(compose(dy=dy, legs="tuck"))
    f += [compose(dy=1, legs="tuck", eyes="half")] * 2        # land, squash
    f += [rest] * 2
    f += [compose(dy=2, legs="tuck", eyes="half")] * 2        # a second, smaller hop
    for dy in (-2, -3):
        f.append(compose(dy=dy, legs="tuck"))
    f += [compose(dy=-3, legs="tuck", extra=sparkles(2))] * 2
    f.append(compose(dy=-1, legs="tuck"))
    f += [compose(dy=1, legs="tuck", eyes="half")]
    f += [rest] * (N - len(f))
    return f


ANIMS = [("scuttle", scuttle()), ("bubbles", bubbles()), ("snooze", snooze()),
         ("rave", rave()), ("jump", jump())]

# --- encode to Swift ----------------------------------------------------------------

def rects(g):
    """Greedy row runs merged vertically -> flattened (ci, x, y, w, h) ints."""
    runs = []
    for y, row in enumerate(g):
        x = 0
        while x < W:
            if row[x] < 0:
                x += 1
                continue
            c, x0 = row[x], x
            while x < W and row[x] == c:
                x += 1
            runs.append([c, x0, y, x - x0, 1])
    merged = []
    for r in runs:
        m = next((m for m in merged if m[0] == r[0] and m[1] == r[1] and m[3] == r[3]
                  and m[2] + m[4] == r[2]), None)
        if m:
            m[4] += 1
        else:
            merged.append(r)
    return [v for r in merged for v in r]


def encode(frames):
    uniq, seq = [], []
    for g in frames:
        r = rects(g)
        if r not in uniq:
            uniq.append(r)
        seq.append(uniq.index(r))
    return uniq, seq


out = ["import AppKit", "",
       "// Generated by tools/make_anims.py — new pixel animations composed from the",
       "// original Clawd art's parts. Same grid, palette, and frame count as Clawd.",
       "enum ClawdAnims {",
       "    /// `uniq` holds each distinct frame as (colour, x, y, w, h) runs;",
       "    /// `seq` is the 43-frame playback order into it.",
       "    struct Anim { let uniq: [[Int]]; let seq: [Int] }", ""]
for name, frames in ANIMS:
    assert len(frames) == N, f"{name}: {len(frames)} frames"
    uniq, seq = encode(frames)
    out.append(f"    static let {name} = Anim(uniq: [")
    for r in uniq:
        out.append(f"        [{', '.join(map(str, r))}],")
    out.append(f"    ], seq: {seq})")
    out.append("")
out += ["}", "",
        "/// drawClawd's twin for the generated animations.",
        "func drawAnim(_ a: ClawdAnims.Anim, frame: Int, at origin: NSPoint, scale: CGFloat) {",
        "    let n = a.seq.count",
        "    let runs = a.uniq[a.seq[((frame % n) + n) % n]]",
        "    let top = origin.y + CGFloat(Clawd.cellsHigh) * scale",
        "    for i in stride(from: 0, to: runs.count, by: 5) {",
        "        Clawd.colors[runs[i]].setFill()",
        "        NSRect(x: origin.x + CGFloat(runs[i + 1]) * scale,",
        "               y: top - CGFloat(runs[i + 2] + runs[i + 4]) * scale,",
        "               width: CGFloat(runs[i + 3]) * scale,",
        "               height: CGFloat(runs[i + 4]) * scale).fill()",
        "    }",
        "}", ""]

dest = SRC = Path(__file__).resolve().parent.parent / "Sources" / "ClawdAnims.swift"
dest.write_text("\n".join(out))
total = sum(len(encode(f)[0]) for _, f in ANIMS)
print(f"wrote {dest} — {len(ANIMS)} anims, {total} unique frames")

if len(sys.argv) > 1:
    outdir = Path(sys.argv[1])
    outdir.mkdir(parents=True, exist_ok=True)
    for name, frames in ANIMS:
        cols, scale = 9, 5
        rows = (N + cols - 1) // cols
        sheet = [[-1] * (cols * (W + 2) * scale) for _ in range(rows * (H + 2) * scale)]
        for i, g in enumerate(frames):
            up = upscale(g, scale)
            ox, oy = (i % cols) * (W + 2) * scale, (i // cols) * (H + 2) * scale
            for yy, row in enumerate(up):
                sheet[oy + yy][ox:ox + len(row)] = row
        png(outdir / f"{name}.png", sheet, len(sheet[0]), len(sheet))
    print(f"previews in {outdir}")
