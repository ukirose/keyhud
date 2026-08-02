#!/usr/bin/env python3
"""Pixel-compare two directories of panel renders.

A refactor's whole claim is that behaviour did not change, and the only honest way to
show that for a thing whose output is pixels is to compare the pixels. Run once against
two captures of the *same* build first: menus are live, so some drift is the applications'
and not the code's, and a comparison with no measured noise floor proves nothing.

    tools/compare-renders.py <dir-a> <dir-b>
"""
import pathlib
import sys

from PIL import Image, ImageChops


def compare(a: pathlib.Path, b: pathlib.Path):
    rows, clean, missing = [], 0, []
    for left in sorted(a.glob("*.png")):
        right = b / left.name
        if not right.exists():
            missing.append(f"{left.name}: only in {a.name}")
            continue
        one, two = Image.open(left).convert("RGB"), Image.open(right).convert("RGB")
        if one.size != two.size:
            rows.append((left.name, f"size {one.size} -> {two.size}", None))
            continue
        diff = ImageChops.difference(one, two)
        box = diff.getbbox()
        if box is None:
            clean += 1
            continue
        changed = sum(1 for p in diff.getdata() if p != (0, 0, 0))
        total = one.size[0] * one.size[1]
        rows.append((left.name, f"{changed} px ({100 * changed / total:.2f}%)", box))

    for name in sorted(set(p.name for p in b.glob("*.png"))
                       - set(p.name for p in a.glob("*.png"))):
        missing.append(f"{name}: only in {b.name}")

    print(f"{clean} identical, {len(rows)} differ, {len(missing)} unpaired")
    for name, detail, box in rows:
        print(f"  {name:34s} {detail}" + (f"  bbox={box}" if box else ""))
    for line in missing:
        print(f"  {line}")
    return 1 if rows or missing else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        raise SystemExit(2)
    raise SystemExit(compare(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])))
