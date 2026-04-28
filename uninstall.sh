#!/bin/bash
set -e

echo "Removing budget hooks..."

rm -f ~/.claude/hooks/budget-estimator.py
rm -f ~/.claude/hooks/budget-finalizer.py
rm -f ~/.claude/hooks/budget-statusline.py
rm -f ~/.claude/budget-flag-*.json

PYTHON_CMD=""
for candidate in python3 python py; do
  if command -v "$candidate" >/dev/null 2>&1 \
      && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
    PYTHON_CMD="$candidate"
    break
  fi
done

if [ -z "$PYTHON_CMD" ]; then
  echo "Error: Python 3 is required to patch settings.json." >&2
  exit 1
fi

"$PYTHON_CMD" << 'PYEOF'
import json
import os

path = os.path.expanduser("~/.claude/settings.json")
if not os.path.exists(path):
    raise SystemExit

with open(path, encoding="utf-8") as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
for event in ("UserPromptSubmit", "Stop"):
    entries = hooks.get(event, [])
    cleaned = []
    for entry in entries:
        kept = [
            h for h in entry.get("hooks", [])
            if "budget-estimator.py" not in h.get("command", "")
            and "budget-finalizer.py" not in h.get("command", "")
        ]
        if kept:
            entry["hooks"] = kept
            cleaned.append(entry)
    if cleaned:
        hooks[event] = cleaned
    elif event in hooks:
        del hooks[event]

statusline = settings.get("statusLine")
if isinstance(statusline, dict) and "budget-statusline.py" in statusline.get("command", ""):
    del settings["statusLine"]

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(settings, f, indent=2)
os.replace(tmp, path)
PYEOF

echo "Done. Restart Claude Code."
