#!/usr/bin/env bash
# Validates the App Shortcuts phrases before a build.
#
# Siri only matches a phrase that contains the app-name token, and the App Intents metadata
# processor drops malformed entries silently. This is a source-level lint: it cannot prove Siri
# matching on a device, it only proves the phrases are well-formed and that every intent has one.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
file="$root/StrengthApp/Intents/StrengthShortcuts.swift"

if [[ ! -f "$file" ]]; then
  echo "error: $file not found" >&2
  exit 1
fi

python3 - "$file" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
problems = []

shortcuts = len(re.findall(r"AppShortcut\(", text))
if shortcuts != 6:
    problems.append(f"expected 6 AppShortcut entries, found {shortcuts}")

for key in ("shortTitle:", "systemImageName:"):
    count = len(re.findall(re.escape(key), text))
    if count != shortcuts:
        problems.append(f"{key} appears {count} times for {shortcuts} shortcuts")

phrase_lines = [
    line.strip().rstrip(",")
    for line in text.splitlines()
    if re.match(r'^\s*".*",?$', line)
]
if not phrase_lines:
    problems.append("no phrase strings found")
for phrase in phrase_lines:
    if "\\(.applicationName)" not in phrase:
        problems.append(f"phrase lacks the app-name token: {phrase}")
    if len(phrase) > 100:
        problems.append(f"phrase is longer than 100 characters: {phrase}")

for problem in problems:
    print(f"error: {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY

echo "shortcut phrases: ok"
