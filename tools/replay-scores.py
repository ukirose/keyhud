#!/usr/bin/env python3
"""Rebuild learning scores by replaying the usage log.

The scoring model replaced a five-step chain, and the record shape changed without the
file version changing with it. Every record field decoded with a default, so records
written before the change loaded as valid and scored zero — twenty of them on this
machine, one with fifty-one unaided presses behind it.

The counts and timestamps in those records are intact; only the score is gone. It cannot
be recomputed from a record, because the model cares *when* each press happened and how
many landed on the same day. It can be recomputed from `menu-picks.jsonl`, which has one
line per use with a timestamp, a path, and whether the menu was open.

One thing the log does not record is whether the panel was on screen at the time, which is
what separates a look-it-up from a recall. This reconstructs that from `invocations.jsonl`
— a press counts as assisted if a panel for the same app was shown in the preceding
`ASSIST_WINDOW` seconds. That is an approximation, and it is the only one here.

Prints a comparison by default. Pass --write to apply, which backs up first.
"""
import collections
import datetime
import json
import pathlib
import sys

DATA = pathlib.Path(__file__).resolve().parent.parent / "data"
SEP = "\x1f"

# Must match LearningStore's tunables.
GAIN_PER_RECALL = 8.0
DAILY_GAIN_CAP = 16.0
MOUSE_PENALTY = 25.0
DECAY_PER_DAY = 1.0
DECAY_GRACE_DAYS = 3.0
HALL_OF_FAME = 100.0
ASSIST_WINDOW = 30.0


def when(text):
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))


def read(name):
    path = DATA / name
    if not path.exists():
        return []
    out = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return out


def main():
    uses = []
    skipped = 0
    for name in ("menu-picks.pre-viamenu.jsonl", "menu-picks.jsonl"):
        for row in read(name):
            if not row.get("hasShortcut"):
                continue
            # The earliest rows predate `path`/`appKey` and cannot be attributed to a
            # record at all. Counted and reported rather than quietly dropped.
            if not row.get("path") or not row.get("appKey"):
                skipped += 1
                continue
            uses.append(row)
    uses.sort(key=lambda r: r["t"])

    shown = collections.defaultdict(list)
    for row in read("invocations.jsonl"):
        if row.get("shown") and row.get("t") and row.get("app"):
            shown[row["app"]].append(when(row["t"]))

    records = {}
    for row in uses:
        key = row["appKey"] + SEP + SEP.join(row["path"])
        now = when(row["t"])
        r = records.setdefault(key, {"score": 0.0, "at": None, "day": "",
                                     "gained": 0.0, "kb": 0, "mouse": 0})
        if r["at"] is not None:
            idle = (now - r["at"]).total_seconds() / 86400 - DECAY_GRACE_DAYS
            if idle > 0:
                r["score"] = max(0.0, r["score"] - DECAY_PER_DAY * idle)
        r["at"] = now

        if row.get("viaMenu"):
            r["mouse"] += 1
            r["score"] = max(0.0, r["score"] - MOUSE_PENALTY)
            continue

        r["kb"] += 1
        assisted = any(0 <= (now - s).total_seconds() <= ASSIST_WINDOW
                       for s in shown.get(row.get("app", ""), []))
        if assisted:
            continue
        day = now.strftime("%Y-%m-%d")
        if r["day"] != day:
            r["day"], r["gained"] = day, 0.0
        gain = min(GAIN_PER_RECALL, max(0.0, DAILY_GAIN_CAP - r["gained"]))
        r["gained"] += gain
        r["score"] = min(HALL_OF_FAME, r["score"] + gain)

    store = json.loads((DATA / "learning.json").read_text())
    live = store.get("records", {})

    print(f"replayed {len(uses)} logged uses over {len(records)} shortcuts"
          + (f" ({skipped} log lines too old to attribute)" if skipped else ""))
    print(f"\n{'was':>4} {'->':>4}  {'kb':>4} {'mouse':>5}  shortcut")
    changed = 0
    for key, r in sorted(records.items(), key=lambda kv: -kv[1]["score"]):
        current = live.get(key, {}).get("score", 0)
        if round(r["score"]) == round(current):
            continue
        changed += 1
        print(f"{current:4.0f} {r['score']:4.0f}  {r['kb']:4d} {r['mouse']:5d}  "
              + key.replace(SEP, " / "))
    print(f"\n{changed} records would change.")

    if "--write" not in sys.argv:
        print("Nothing written. Re-run with --write to apply.")
        return

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = DATA / f"learning.json.before-replay-{stamp}"
    backup.write_text((DATA / "learning.json").read_text())

    # Every flagged record is answered, not just the ones the log can rebuild. Four of
    # this machine's twenty are named in no log line that carries a path — the counted
    # "too old to attribute" rows — so their score is not recoverable by any means. Leaving
    # the flag up for them means the launch banner asks forever for a repair this tool
    # cannot perform. Clearing it says what is true: nothing further can be done.
    unrecoverable = [k for k, v in live.items()
                     if v.get("needsScoreRepair") and k not in records]
    for key in unrecoverable:
        live[key]["needsScoreRepair"] = False
        live[key]["v"] = 3
    if unrecoverable:
        print(f"{len(unrecoverable)} flagged record(s) appear in no attributable log line; "
              "their score stays 0 and the flag is cleared, because nothing can rebuild it:")
        for key in sorted(unrecoverable):
            print("  " + key.replace(SEP, " / "))

    for key, r in records.items():
        rec = live.get(key, {})
        rec["v"] = 3
        # The repair happened, so the flag comes down. Nothing else lowers it, which is
        # what makes the store's stale count converge instead of oscillating.
        rec["needsScoreRepair"] = False
        rec["score"] = round(r["score"], 3)
        rec["scoredAt"] = r["at"].timestamp() - 978307200.0   # Foundation reference date
        rec["hallOfFameLogged"] = r["score"] >= HALL_OF_FAME
        live[key] = rec
    store["records"] = live
    (DATA / "learning.json").write_text(json.dumps(store, ensure_ascii=False, indent=2))
    print(f"written. previous file kept as {backup.name}")


if __name__ == "__main__":
    main()
