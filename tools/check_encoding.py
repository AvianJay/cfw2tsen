#!/usr/bin/env python3
"""Assert every text file in the repo is valid UTF-8 with no U+FFFD.

A non-UTF-8 text round-trip silently replaces characters with '?' or U+FFFD,
which is invisible in review but corrupts comments and, worse, string literals.
Run this in CI to catch it.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

TEXT_SUFFIXES = {".sh", ".yml", ".yaml", ".md", ".py", ".json"}
TEXT_NAMES = {"Dockerfile", ".env.example", ".dockerignore", ".gitignore",
              ".gitattributes", "LICENSE"}

# Directories that are never part of the repository content.
SKIP_DIRS = {".git", ".ci", "node_modules", "__pycache__", ".venv", "venv"}


def candidate_files() -> list[Path]:
    """Tracked files when in a git checkout, otherwise a filesystem walk.

    Using git keeps local scratch directories (downloaded linters, CI logs) out
    of the check; those are not part of the repository and may legitimately hold
    binary or UTF-16 content.
    """
    try:
        out = subprocess.run(
            ["git", "ls-files", "-z"],
            cwd=ROOT, capture_output=True, check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        out = b""
    if out:
        return [ROOT / p for p in out.decode("utf-8").split("\0") if p]

    files = []
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.relative_to(ROOT).parts):
            continue
        files.append(path)
    return files


problems: list[str] = []
checked = 0

for path in candidate_files():
    if not path.is_file():
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
