#!/bin/bash
set -e
echo "Removing budget hooks..."

rm -f ~/.claude/hooks/budget-estimator.py
rm -f ~/.claude/hooks/budget-finalizer.py
rm -f ~/.claude/hooks/budget-statusline.py
rm -f ~/.claude/budget-flag-*.json

python3 << 'EOF'
import json, os
path = os.path.expanduser("~/.claude/settings.json")
if not os.path.exists(path):
    raise SystemExit
with open(path) as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
for event in ("UserPromptSubmit", "Stop"):
    entries = hooks.get(event, [])
    cleaned = []
    for entry in entries:
        kept = [h for h in entry.get("hooks", [])
                if "budget-estimator.py" not in h.get("command", "")
                and "budget-finalizer.py" not in h.get("command", "")]
        if kept:
            entry["hooks"] = kept
            cleaned.append(entry)
    if cleaned:
        hooks[event] = cleaned
    elif event in hooks:
        del hooks[event]

# statusLine: remove only if it points to our budget bar — never clobber a
# user's custom statusLine.
sl = settings.get("statusLine")
if isinstance(sl, dict) and "budget-statusline.py" in sl.get("command", ""):
    del settings["statusLine"]

with open(path + ".tmp", "w") as f:
    json.dump(settings, f, indent=2)
os.replace(path + ".tmp", path)
print("Done. Restart Claude Code.")
EOF