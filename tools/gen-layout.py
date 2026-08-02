#!/usr/bin/env python3
"""Generate data/keyboard.json from QMK's keyboard definitions.

The physical layout was previously written from memory, and it was wrong: it invented
two ◇ keys in the bottom row and used the wrong inset, giving a 62-key board where the
HHKB has 60. Geometry belongs to whoever measured the hardware, so it is taken from
qmk_firmware — info.json carries every key's x/y/width, and the default keymap.c carries
the legends for both the base and Fn layers, in the same LAYOUT order.

    ./tools/gen-layout.py                       # HHKB ANSI (default)
    ./tools/gen-layout.py --keyboard hhkb/jp    # any board QMK knows

Source: https://github.com/qmk/qmk_firmware (GPL-2.0) — geometry and legends only.
"""
import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

RAW = "https://raw.githubusercontent.com/qmk/qmk_firmware/master/keyboards"

# QMK keycode -> what is printed on the keycap.
LEGEND = {
    "KC_ESC": "esc", "KC_MINS": "-", "KC_EQL": "=", "KC_BSLS": "\\", "KC_GRV": "`",
    "KC_TAB": "tab", "KC_LBRC": "[", "KC_RBRC": "]", "KC_BSPC": "delete",
    "KC_LCTL": "control", "KC_SCLN": ";", "KC_QUOT": "'", "KC_ENT": "return",
    "KC_LSFT": "shift", "KC_RSFT": "shift", "KC_COMM": ",", "KC_DOT": ".",
    "KC_SLSH": "/", "KC_SPC": "space", "KC_LALT": "⌥", "KC_RALT": "⌥",
    "KC_LGUI": "⌘", "KC_RGUI": "⌘", "KC_CAPS": "caps",
}
# Keycode -> the key names macOS hands us through the Accessibility API.
MATCH = {
    "KC_ESC": ["⎋"], "KC_BSPC": ["⌫"], "KC_ENT": ["↩", "⌤"], "KC_TAB": ["⇥"],
    "KC_SPC": ["␣", " "], "KC_UP": ["↑"], "KC_DOWN": ["↓"], "KC_LEFT": ["←"],
    "KC_RGHT": ["→"], "KC_DEL": ["⌦"], "KC_HOME": ["↖"], "KC_END": ["↘"],
    "KC_PGUP": ["⇞"], "KC_PGDN": ["⇟"],
}


def legend(code: str) -> str:
    if code.startswith("MO(") or code == "KC_TRNS":
        return "fn" if code.startswith("MO(") else ""
    if code in LEGEND:
        return LEGEND[code]
    m = re.fullmatch(r"KC_([A-Z0-9]|F\d{1,2})", code)
    return m.group(1) if m else ""


def matches(code: str) -> list:
    if code in MATCH:
        return MATCH[code]
    m = re.fullmatch(r"KC_([A-Z])", code)
    if m:
        return [m.group(1)]
    m = re.fullmatch(r"KC_(\d)", code)
    if m:
        return [m.group(1)]
    m = re.fullmatch(r"KC_(F\d{1,2})", code)
    if m:
        return [m.group(1)]
    if code in LEGEND and len(LEGEND[code]) == 1:
        return [LEGEND[code]]
    return []


# The upper legend printed on each US keycap. Drawn alongside the base so a pair like
# "−" and "+" stays legible, and so a shortcut an app names with the shifted character
# still lands on a key the eye can find.
SHIFT_LEGEND = {
    "`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&",
    "8": "*", "9": "(", "0": ")", "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|",
    ";": ":", "'": '"', ",": "<", ".": ">", "/": "?",
}


def fetch(url: str) -> str:
    with urllib.request.urlopen(url, timeout=30) as r:
        return r.read().decode("utf-8")


def parse_layer(source: str, name: str) -> list:
    """Pull the keycode list out of `[NAME] = LAYOUT(...)`.

    Counts parentheses rather than matching a closing one: keycodes like `MO(HHKB)` carry
    their own, and a non-greedy regex stops at the first of those — which silently
    truncated the base layer at 55 of 60 keys.
    """
    m = re.search(r"\[%s\]\s*=\s*LAYOUT\w*\s*\(" % name, source, re.S)
    if not m:
        return []
    depth, start = 1, m.end()
    i = start
    while i < len(source) and depth:
        if source[i] == "(":
            depth += 1
        elif source[i] == ")":
            depth -= 1
        i += 1
    body = re.sub(r"/\*.*?\*/", "", source[start:i - 1], flags=re.S)
    body = re.sub(r"//[^\n]*", "", body)   # `LAYOUT( // default layer` swallows KC_ESC
    # Split on commas that are not inside a keycode's own parentheses.
    out, buf, nest = [], "", 0
    for ch in body:
        if ch == "(":
            nest += 1
        elif ch == ")":
            nest -= 1
        if ch == "," and nest == 0:
            out.append(buf.strip())
            buf = ""
        else:
            buf += ch
    if buf.strip():
        out.append(buf.strip())
    return [t for t in out if t]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--keyboard", default="hhkb/ansi")
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "data" / "keyboard.json"))
    args = ap.parse_args()

    info = json.loads(fetch(f"{RAW}/{args.keyboard}/info.json"))
    layout_name = next(iter(info["layouts"]))
    keys = info["layouts"][layout_name]["layout"]

    keymap_src = fetch(f"{RAW}/{args.keyboard}/keymaps/default/keymap.c")
    base = parse_layer(keymap_src, r"\w+")  # first layer defined
    layers = re.findall(r"\[(\w+)\]\s*=\s*LAYOUT", keymap_src)
    base = parse_layer(keymap_src, layers[0]) if layers else []
    fn = parse_layer(keymap_src, layers[1]) if len(layers) > 1 else []

    if len(base) != len(keys):
        print(f"warning: {len(base)} legends for {len(keys)} keys — legends dropped",
              file=sys.stderr)
        base = [""] * len(keys)
    if len(fn) != len(keys):
        fn = [""] * len(keys)

    rows = {}
    for i, k in enumerate(keys):
        rows.setdefault(k["y"], []).append((k, base[i], fn[i]))

    out_rows = []
    for y in sorted(rows):
        entries = sorted(rows[y], key=lambda e: e[0]["x"])
        lead = min(e[0]["x"] for e in entries)
        out_keys = []
        for k, b, f in entries:
            lab = legend(b)
            key = {"label": lab, "match": matches(b), "w": k.get("w", 1)}
            if lab in SHIFT_LEGEND:
                key["shiftLabel"] = SHIFT_LEGEND[lab]
            fm = matches(f) if f and f != "KC_TRNS" else []
            if fm:
                # Reached by holding Fn. Shown with a badge so the panel teaches the real
                # two-handed motion rather than implying a key that is not there.
                key["fnLabel"] = legend(f)
                key["fnMatch"] = fm
            out_keys.append(key)
        out_rows.append({"leadingGap": lead, "keys": out_keys})

    doc = {
        "_comment": "Generated by tools/gen-layout.py from qmk_firmware. Edit freely if "
                    "your board differs (the HHKB Keymap Tool can change it in firmware); "
                    "restart KeyHUD to apply.",
        "_source": f"qmk_firmware keyboards/{args.keyboard}",
        "name": f"{info.get('manufacturer','')} {info.get('keyboard_name','')}".strip(),
        "rows": out_rows,
    }
    Path(args.out).write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8")
    total = sum(len(r["keys"]) for r in out_rows)
    print(f"wrote {args.out}: {len(out_rows)} rows, {total} keys, from {doc['_source']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
