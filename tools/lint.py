#!/usr/bin/env python3
"""Checks the compiler cannot make.

Four of the review findings were the same shape: a rename or a removal applied at one end
and not the other. The digest counted an event no producer emits, so its headline was
pinned at zero. Two menu toggles were wired to settings nothing read, so pressing them did
nothing at all — a UI that lies. A style constant described a reflow that was never
written. None of it is a compile error, and none of it is visible in a diff.

A fifth shape was logic fused to an I/O boundary where no test could reach it. That one
cost two high-severity bugs in the trigger alone. The files that have since been pulled
free of it are listed in PURE below, and this stops them drifting back.

Run: tools/lint.py       (from anywhere; exits non-zero on a finding)
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = sorted((ROOT / "Sources/KeyHUDCore").glob("*.swift"))

# Files that have been deliberately separated from I/O so their logic can be tested. The
# separation is the whole reason they exist as separate files; a stray `import Cocoa` here
# is the first step back to a state machine nobody can drive from a test.
PURE = {"HoldMachine.swift", "ChordMatch.swift", "PanelContent.swift"}
# Written against the idioms this codebase actually uses, not against a tidy idea of what
# impurity looks like. The first version matched `Data(contentsOf` and not
# `String(contentsOf` — and `String(contentsOf` was already three lines away in HUDPanel;
# it matched `AXUIElement…(` and not `AXIsProcessTrusted()` or `AXValueGetValue(`; it
# banned `import Cocoa` and not `import ApplicationServices`. Every one of those is a way
# to write the exact bug the rule exists to catch and be told the code is clean.
IMPURE = [
    (re.compile(r"^\s*import\s+(Cocoa|AppKit|ApplicationServices|CoreGraphics|Carbon)\b", re.M),
     "imports a UI or system framework"),
    (re.compile(r"\bAX[A-Z]\w*\s*\("), "calls the Accessibility API"),
    (re.compile(r"\bCG(Event|Display|MainDisplay)\w*\s*[.(]"), "calls CoreGraphics"),
    (re.compile(r"\bNS(Screen|Window|Panel|Workspace|Event|Application)\b"),
     "touches the window server or the running-application list"),
    (re.compile(r"\b(FileManager|FileHandle|Bundle\.main|UserDefaults|CFPreferences\w*)\b"),
     "reads or writes persistent state"),
    (re.compile(r"\b(String|Data)\(contentsOf|\.write\(to(File)?:"), "does file I/O"),
    (re.compile(r"ProcessInfo\.\w*\.environment"), "reads the environment"),
    (re.compile(r"\b(TextBindings\.all|DataDir\.url)\b"),
     "reaches for a global backed by the filesystem"),
]


def read(name):
    return (ROOT / "Sources/KeyHUDCore" / name).read_text()


def stored_properties(text, type_name):
    """`var x = …` / `var x: T` declared directly inside `struct <type_name>`.

    Brace-counted, not regex-bounded: a lazy `.*?` for the closing brace ran past the end
    of the struct and swept up members of the enclosing type, so the first thing this file
    reported was a property that does not exist.
    """
    start = re.search(r"struct\s+" + type_name + r"\b[^{]*\{", text)
    if not start:
        return []
    depth, i = 0, start.end() - 1
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    body = text[start.end():i]
    # The struct's own members, not locals inside its methods. Without the depth count
    # this picked up `pt` from a font helper and `c` from a decoder, and passed only
    # because names that short happen to appear in other files too.
    own, depth = [], 0
    for line in body.split("\n"):
        if depth == 0:
            own.append(line)
        depth += line.count("{") - line.count("}")
    body = "\n".join(own)
    # Stored declarations only — a computed property is code, not state, and has no
    # "nobody reads it" problem. A computed one is recognised by the brace that opens its
    # body, and by nothing else: excluding lines containing "=" as well swallowed every
    # `let x: CGFloat = 3`, which is most of PanelStyle. That rule then found no properties
    # at all and passed silently, which is how a check that cannot fail looks from outside.
    # `[^{\n]` and not `[^{]`: a negated character class matches newlines, so the greedy
    # run from the first `let` swallowed every line after it up to the next brace and the
    # rule saw three properties where there are fifteen. It reported nothing and passed.
    return re.findall(r"^\s+(?:var|let)\s+(\w+)\s*[:=][^{\n]*$", body, re.M)


def references(name, exclude_files=(), exclude_patterns=()):
    """Lines that *read* `name`.

    Comments and assignments do not count. Both used to: `PanelStyle.maxHeightFraction`
    was satisfied by its own mention in a comment in another file, so deleting its one
    real reader left the rule silent — and a settings property was satisfied by the line
    that writes it. A check that a mention exists is not a check that anything uses it.
    """
    hits = []
    for path in SOURCES:
        if path.name in exclude_files:
            continue
        for number, line in enumerate(path.read_text().split("\n"), 1):
            code = line.split("//")[0]
            if not re.search(r"\b" + re.escape(name) + r"\b", code):
                continue
            # `x.name = …` or `name = …` with no other use on the line is a write.
            if re.search(r"(?<![=!<>])\b" + re.escape(name) + r"\s*=(?!=)", code) \
               and len(re.findall(r"\b" + re.escape(name) + r"\b", code)) == 1:
                continue
            if any(re.search(p, code) for p in exclude_patterns):
                continue
            hits.append(f"{path.name}:{number}")
    return hits


def main():
    problems = []
    global problems_later
    problems_later = []

    # 1. A settings toggle with no reader is a switch wired to nothing. Its declaration,
    #    its decoder line, its checkbox row and its toggle case do not count as reading it.
    noise = (r"decodeIfPresent.*forKey", r'^\s*\("[^"]*",\s*"\w+",', r'case\s+"\w+":.*toggle\(\)',
             r"^\s+(?:var|let)\s+\w+\s*[:=]")
    for prop in stored_properties(read("LearningStore.swift"), "Settings"):
        if not references(prop, exclude_patterns=noise):
            problems.append(f"Settings.{prop} is stored and toggled but never read — "
                            "a menu item that does nothing")

    # 2. Same shape, one layer down: a style constant nothing draws with.
    for prop in stored_properties(read("PanelStyle.swift"), "PanelStyle"):
        if not references(prop, exclude_files={"PanelStyle.swift"}):
            problems.append(f"PanelStyle.{prop} is declared but nothing reads it")

    # 3. An event with no consumer, or a consumer waiting on an event nobody sends. The
    #    digest spent a release counting "graduated", which the producer had renamed.
    # Every source, not just LearningStore: a second producer elsewhere was invisible.
    produced = set()
    for path in SOURCES:
        produced |= set(re.findall(r'appendEvent\(\s*"([^"]+)"', path.read_text()))
        for name in re.findall(r"appendEvent\(\s*([a-z]\w*)\s*,", path.read_text()):
            problems_later.append(f"{path.name} writes an event whose name is the variable "
                                  f"`{name}`, so no check can tell what it produces")
    digest = read("Digest.swift")
    # `== "x"` and `case "x":` both consume. Rewriting the filters as a switch used to make
    # the rule report three false positives, which teaches the reader to weaken it.
    consumed = set(re.findall(r'==\s*"([^"]+)"', digest)) \
        | set(re.findall(r'case\s+"([^"]+)"\s*:', digest))
    # The payload the digest reads has to be a key some producer writes, or every line
    # comes out as "?" and nothing fails. The digest reads two logs — events.jsonl from
    # `appendEvent` and menu-picks.jsonl from UsageLog — and `label()` accepts either
    # shape, so the union is what it can legitimately ask for.
    written = set()
    for source in ("LearningStore.swift", "UsageLog.swift"):
        text = read(source)
        for literal in re.findall(r"\[String: Any\] = \[(.*?)\n\s*\]", text, re.S) \
                + re.findall(r"write\(to: \w+, \[(.*?)\n\s*\]\)", text, re.S):
            written |= set(re.findall(r'"(\w+)":', literal))
    for field in sorted(set(re.findall(r'o\["(\w+)"\]', digest)) - written):
        problems_later.append(f'Digest.swift reads "{field}" out of events.jsonl and '
                              "appendEvent never writes it")
    for event in sorted(produced - consumed):
        problems.append(f'"{event}" is written to events.jsonl and Digest.swift never reads it')
    for event in sorted(c for c in consumed - produced if "_" in c):
        problems.append(f'Digest.swift counts "{event}" and nothing ever writes it')
    problems += problems_later

    # 4. The committed fixture must not carry anything about the machine that made it.
    #
    #    The corpus is captured from every running app, and a Window menu lists the open
    #    documents underneath its standard commands. That is how a Terminal window title —
    #    carrying a user name, a host name and a working directory — came to be staged for a
    #    public repository. It survived a first scan that looked only for file extensions
    #    and URLs, which is the shape of the mistake: the check knew what it was looking for,
    #    and the leak was not that. The string itself is deliberately not quoted here.
    #
    #    Classifying "document title" against "menu command" is not reliable, so this does
    #    not try. It fails on the traces a machine leaves in a string, and leaves deciding
    #    what to do about a hit to a person.
    personal = [
        (re.compile(r"/Users/\w"), "an absolute home path"),
        (re.compile(r"[\w.+-]+@[\w-]+\.?[\w-]*"), "an address or user@host"),
        (re.compile(r"~/"), "a home-relative path"),
        (re.compile(r"\b\d{1,3}×\d{1,3}\b"), "a terminal window geometry"),
    ]
    fixtures = ROOT / "Tests/KeyHUDCoreTests/Fixtures"
    for path in sorted(fixtures.glob("*.json")) if fixtures.is_dir() else []:
        for number, line in enumerate(path.read_text().split("\n"), 1):
            for pattern, what in personal:
                if pattern.search(line):
                    problems.append(f"{path.name}:{number} contains {what} — a fixture "
                                    "captured from this machine is published as-is")

    # 5. The pure layer stays pure.
    for path in SOURCES:
        if path.name not in PURE:
            continue
        text = path.read_text()
        for pattern, what in IMPURE:
            if pattern.search(text):
                problems.append(f"{path.name} {what}; it is listed as pure logic "
                                "because that is what makes it testable")

    for problem in problems:
        print(f"lint: {problem}")
    print(f"lint: {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
