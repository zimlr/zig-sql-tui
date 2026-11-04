#!/usr/bin/env python3
"""Check mechanically detectable rules in project Markdown prose."""

import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
EXCLUDED = {".git", ".zig-cache", "zig-out", "vendor", "__pycache__"}
CODE_SPAN = re.compile(r"(`+)(?:[^`]|`(?!\1))*?\1")
LINK = re.compile(r"\[([^]]+)\]\([^)]*\)")
BANNED = re.compile(
    r"\b(?:we|our|ours|us|you|your|yours|let's|certainly|"
    r"great question|here's the thing|it's worth noting|in conclusion|"
    r"battle-tested|bulletproof|blazing|supercharge|unlock|journey)\b",
    re.IGNORECASE,
)
PUNCTUATION = re.compile(r"[;—–!?]|\.\.\.|…|[\U0001F000-\U0001FAFF]")


def check_text(text):
    errors = []
    fence = None
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.lstrip()
        marker = re.match(r"(`{3,}|~{3,})", stripped)
        if marker:
            run = marker.group(1)
            if fence is None:
                fence = run
            elif run[0] == fence[0] and len(run) >= len(fence):
                fence = None
            continue
        if fence is not None or line.startswith("    "):
            continue
        prose = CODE_SPAN.sub("", line)
        prose = LINK.sub(r"\1", prose)
        punctuation = PUNCTUATION.search(prose)
        if punctuation:
            errors.append((number, f"prohibited punctuation: {punctuation.group()}"))
        word = BANNED.search(prose)
        if word:
            errors.append((number, f"prohibited phrase: {word.group()}"))
    if fence is not None:
        errors.append((number, "unclosed code fence"))
    return errors


def markdown_files():
    for directory, dirs, names in os.walk(ROOT):
        dirs[:] = sorted(d for d in dirs if d not in EXCLUDED and not (Path(directory) == ROOT / "tools" and d == "zig"))
        for name in sorted(names):
            if name.endswith(".md"):
                yield Path(directory) / name


def main():
    failed = False
    for path in markdown_files():
        for line, message in check_text(path.read_text(encoding="utf-8")):
            print(f"{path.relative_to(ROOT)}:{line}: {message}")
            failed = True
    if failed:
        return 1
    print("Project Markdown passed the mechanical prose check.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
