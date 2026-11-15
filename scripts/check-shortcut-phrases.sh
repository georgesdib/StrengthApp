#!/usr/bin/env bash
# Validates the App Shortcuts phrases before a build.
#
# Siri only matches a phrase that contains the app-name token, and the App Intents metadata
# processor drops malformed entries silently. This is a source-level lint: it cannot prove Siri
# matching on a device, it only proves the phrases are well-formed and that every intent has one.
#
# Phrases are per app target, so the phone and the watch are checked separately.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

check() {
  local file="$1" expected="$2"
  if [[ ! -f "$file" ]]; then
    echo "error: $file not found" >&2
    exit 1
  fi
  python3 - "$file" "$expected" <<'PY'
import re
import sys

path, expected = sys.argv[1], int(sys.argv[2])
text = open(path, encoding="utf-8").read()
problems = []

shortcuts = len(re.findall(r"AppShortcut\(", text))
if shortcuts != expected:
    problems.append(f"expected {expected} AppShortcut entries, found {shortcuts}")

for key in ("shortTitle:", "systemImageName:"):
    count = len(re.findall(re.escape(key), text))
    if count != shortcuts:
        problems.append(f"{key} appears {count} times for {shortcuts} shortcuts")

groups = re.findall(r"phrases:\s*\[(.*?)\]\s*,", text, re.S)
if len(groups) != shortcuts:
    problems.append(f"found {len(groups)} phrase lists for {shortcuts} shortcuts")
for group in groups:
    phrases = re.findall(r'"((?:[^"\\]|\\.)*)"', group)
    if not phrases:
        problems.append("a shortcut has an empty phrase list")
    for phrase in phrases:
        if "\\(.applicationName)" not in phrase:
            problems.append(f"phrase lacks the app-name token: {phrase}")
        if len(phrase) > 100:
            problems.append(f"phrase is longer than 100 characters: {phrase}")

for problem in problems:
    print(f"error: {path}: {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
}

check "$root/StrengthApp/Intents/StrengthShortcuts.swift" 6
check "$root/StrengthWatch/WatchReadOnlyIntents.swift" 4

echo "shortcut phrases: ok"
