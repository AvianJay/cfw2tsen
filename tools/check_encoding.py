#!/usr/bin/env python3
"""Assert every text file in the repo is valid UTF-8 with no U+FFFD.

A non-UTF-8 text round-trip silently replaces characters with '?' or U+FFFD,
which is invisible in review but corrupts comments and, worse, string literals.
Run this in CI to catch it.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

TEXT_SUFFIXES = {".sh", ".yml", ".yaml", ".md", ".py", ".json"}
TEXT_NAMES = {"Dockerfile", ".env.example", ".dockerignore", ".gitignore",
              ".gitattributes", "LICENSE"}

problems: list[str] = []
checked = 0

for path in sorted(ROOT.rglob("*")):
    if not path.is_file():
        continue
    if ".git" in path.parts:
        continue
    if path.suffix not in TEXT_SUFFIXES and path.name not in TEXT_NAMES:
        continue

    checked += 1
    raw = path.read_bytes()
    rel = path.relative_to(ROOT)

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        problems.append(f"{rel}: not valid UTF-8 ({exc})")
        continue

    if "\ufffd" in text:
        count = text.count("\ufffd")
        problems.append(f"{rel}: contains {count} U+FFFD replacement character(s)")

    # A UTF-8 BOM breaks `#!/usr/bin/env bash` shebangs and some YAML parsers.
    if raw.startswith(b"\xef\xbb\xbf"):
        problems.append(f"{rel}: starts with a UTF-8 BOM")

    if b"\r\n" in raw:
        problems.append(f"{rel}: contains CRLF line endings")

    if not text.endswith("\n"):
        problems.append(f"{rel}: does not end with a newline")

print(f"checked {checked} text files")
if problems:
    print(f"\n{len(problems)} problem(s):")
    for p in problems:
        print(f"  - {p}")
    sys.exit(1)
print("all files are valid UTF-8, LF-only, no BOM, no replacement characters")
