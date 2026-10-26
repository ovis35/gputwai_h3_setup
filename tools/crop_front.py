"""Crop the front full-body figure (top-left) out of a character model sheet.

A sheet is three full bodies (front, side, back) across the top, optionally a grid of heads below,
on a near-white background. We find the first blank horizontal band below the bodies, then the first
blank vertical band right of the front figure, and crop that box with a margin.
Usage: python crop_front.py OUT_DIR name=path [name=path ...]
"""
import sys
from pathlib import Path

from PIL import Image

TOL = 22          # a pixel within this of the corner background colour on every channel counts as background
GAP_ROWS = 18     # blank rows that separate the body row from the head grid
GAP_COLS = 8      # blank columns that separate two figures
MARGIN = 24


def is_bg(p, bg):
    return all(abs(a - b) <= TOL for a, b in zip(p, bg))


def blank_rows(im, x0, x1, bg):
    px = im.load()
    return [all(is_bg(px[x, y], bg) for x in range(x0, x1, 2)) for y in range(im.height)]


def blank_cols(im, y0, y1, bg):
    px = im.load()
    return [all(is_bg(px[x, y], bg) for y in range(y0, y1, 2)) for x in range(im.width)]


def first_run(flags, start, length, value=True):
    run = 0
    for i in range(start, len(flags)):
        run = run + 1 if flags[i] == value else 0
        if run >= length:
            return i - length + 1
    return len(flags)


def crop_front(path):
    im = Image.open(path).convert("RGB")
    bg = im.getpixel((3, 3))
    rows = blank_rows(im, 0, im.width, bg)
    top = next(i for i, b in enumerate(rows) if not b)
    # Bottom of the body row: first long blank band after the figures are well under way.
    bottom = first_run(rows, top + im.height // 4, GAP_ROWS)
    cols = blank_cols(im, top, bottom, bg)
    left = next(i for i, b in enumerate(cols) if not b)
    right = first_run(cols, left + im.width // 8, GAP_COLS)
    # Wide sleeves can touch the next figure, leaving no blank column; sheets are three equal panels.
    if right - left > im.width * 0.45:
        right = int(im.width * 0.36)
    # Tighten the bottom to the front figure itself.
    rows_f = blank_rows(im, left, right, bg)
    fig_bottom = max(i for i in range(top, bottom) if not rows_f[i])
    # Only a sliver of margin on the right: the next figure starts just past the gap.
    box = (max(0, left - MARGIN), max(0, top - MARGIN), min(im.width, right + 2),
           min(im.height, fig_bottom + MARGIN))
    return im.crop(box), box, im.size


out_dir = Path(sys.argv[1])
out_dir.mkdir(parents=True, exist_ok=True)
for arg in sys.argv[2:]:
    name, path = arg.split("=", 1)
    crop, box, size = crop_front(path)
    crop.save(out_dir / f"{name}.png")
    print(f"{name}: sheet {size} -> box {box} -> {crop.size}")
