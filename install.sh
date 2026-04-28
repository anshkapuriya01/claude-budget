#!/bin/bash
set -e

BOLD='\033[1m'
GREEN='\033[0;32m'
DIM='\033[2m'
RESET='\033[0m'

echo ""
echo -e "${BOLD}budget${RESET}"
echo -e "${DIM}token-budget-aware execution for Claude Code${RESET}"
echo ""

PYTHON_CMD=""
for candidate in python3 python py; do
  if command -v "$candidate" >/dev/null 2>&1 \
      && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
    PYTHON_CMD="$candidate"
    break
  fi
done

if [ -z "$PYTHON_CMD" ]; then
  echo "Error: Python 3 is required. Install Python 3 or make python/python3/py available on PATH." >&2
  exit 1
fi

export CLAUDE_BUDGET_PYTHON_CMD="$PYTHON_CMD"

mkdir -p ~/.claude/hooks

# budget-estimator.py (UserPromptSubmit hook)
# Adds budget guidance when the estimated next turn would exceed 90%.
cat > ~/.claude/hooks/budget-estimator.py << 'PYEOF'
#!/usr/bin/env python3
import glob
import json
import os
import re
import sys

MODEL_CONTEXT = {
    "claude-sonnet-4-6[1m]": 1_000_000,
    "claude-opus-4-7": 1_000_000,
    "claude-sonnet-4-6": 200_000,
    "claude-haiku-4-5-20251001": 200_000,
    "claude-haiku-4-5": 200_000,
}

BUDGET_CEILING_PCT = 0.90

HEAVY = {
    "refactor": 12000,
    "rewrite": 12000,
    "migrate": 15000,
    "all files": 20000,
    "entire codebase": 20000,
    "every file": 18000,
    "whole project": 15000,
    "across the": 8000,
    "implement": 8000,
    "build a": 8000,
    "build the": 8000,
    "test suite": 10000,
    "audit": 9000,
    "comprehensive": 8000,
}
MEDIUM = {
    "fix": 3000,
    "add": 3000,
    "update": 3000,
    "change": 2500,
    "create": 4000,
    "write": 4000,
    "modify": 3000,
    "review": 4000,
    "debug": 4000,
    "explain": 2000,
    "analyze": 4000,
}
SCOPE_MULTIPLIERS = [
    (re.compile(r"\b(\d+)\s+files?\b", re.I), lambda m: 1 + 0.3 * int(m.group(1))),
    (re.compile(r"\ball\s+(tests|files|components|modules)\b", re.I), lambda m: 2.5),
    (re.compile(r"\beverywhere\b", re.I), lambda m: 2.0),
]

def estimate_prompt_cost(prompt):
    if not prompt:
        return 1500
    text = prompt.lower()
    prompt_tokens = max(len(prompt) // 4, 50)
    subtotal = 2000 + prompt_tokens * 4
    subtotal += sum(weight for kw, weight in HEAVY.items() if kw in text)
    subtotal += sum(weight for kw, weight in MEDIUM.items() if kw in text)

    multiplier = 1.0
    for pattern, fn in SCOPE_MULTIPLIERS:
        match = pattern.search(prompt)
        if match:
            multiplier *= fn(match)

    return max(1500, min(int(subtotal * multiplier), 500_000))

def read_current_usage(cwd):
    if not cwd:
        return 0, None
    sanitized = re.sub(r"[^a-zA-Z0-9]", "-", cwd).lstrip("-")
    project_dir = os.path.expanduser(f"~/.claude/projects/-{sanitized}")
    candidates = glob.glob(os.path.join(project_dir, "*.jsonl"))
    if not candidates:
        return 0, None

    jsonl_path = max(candidates, key=os.path.getmtime)
    last_usage, last_model = None, None
    try:
        with open(jsonl_path, encoding="utf-8") as f:
            for line in f:
                try:
                    data = json.loads(line)
                except Exception:
                    continue
                if data.get("type") != "assistant":
                    continue
                msg = data.get("message", {})
                usage = msg.get("usage", {})
                if usage:
                    last_usage = usage
                    last_model = msg.get("model") or last_model
    except Exception:
        return 0, None

    if not last_usage:
        return 0, last_model

    total = (
        int(last_usage.get("input_tokens") or 0)
        + int(last_usage.get("cache_read_input_tokens") or 0)
        + int(last_usage.get("cache_creation_input_tokens") or 0)
    )
    return total, last_model

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    prompt = data.get("prompt", "") or ""
    session_id = data.get("session_id", "") or ""
    cwd = data.get("cwd", "") or os.getcwd()

    current, model = read_current_usage(cwd)
    model = model or os.environ.get("ANTHROPIC_MODEL", "claude-opus-4-7")
    context_max = MODEL_CONTEXT.get(model, 200_000)
    estimate = estimate_prompt_cost(prompt)
    ceiling = int(context_max * BUDGET_CEILING_PCT)

    flag_dir = os.path.expanduser("~/.claude")
    os.makedirs(flag_dir, exist_ok=True)
    flag_path = os.path.join(flag_dir, f"budget-flag-{session_id}.json")

    if current + estimate <= ceiling:
        try:
            os.unlink(flag_path)
        except OSError:
            pass
        return

    try:
        with open(flag_path, "w", encoding="utf-8") as f:
            json.dump({
                "cwd": cwd,
                "current": current,
                "estimate": estimate,
                "projected": current + estimate,
                "ceiling": ceiling,
                "context_max": context_max,
            }, f)
    except Exception:
        pass

    reminder = (
        "[BUDGET NOTICE - context window is tight]\n"
        f"Current usage: {current:,} tokens of {context_max:,} "
        f"({current * 100 // context_max}%).\n"
        f"Estimated cost of this request: ~{estimate:,} tokens.\n"
        f"Hard ceiling: {ceiling:,} tokens (90% of window).\n"
        f"Available before ceiling: ~{ceiling - current:,} tokens.\n\n"
        "Partial execution guidance for this turn:\n"
        "1. Break the user's request into discrete tasks before doing work.\n"
        "2. Execute only the tasks that fit in the available budget at full quality.\n"
        "3. Do not compress, rush, or cram extra tasks just to finish everything.\n"
        f"4. In the project root ({cwd}), maintain plan.md as a [x]/[ ] checklist "
        "and summary.md as a dated session log.\n"
        "5. Mark deferred tasks in plan.md and summarize where to resume in summary.md.\n"
    )

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": reminder,
        }
    }))

if __name__ == "__main__":
    main()
PYEOF
chmod +x ~/.claude/hooks/budget-estimator.py

# budget-finalizer.py (Stop hook)
# Creates fallback memory files if a budget-flagged session ends without them.
cat > ~/.claude/hooks/budget-finalizer.py << 'PYEOF'
#!/usr/bin/env python3
import datetime
import json
import os
import sys

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    session_id = data.get("session_id", "") or ""
    cwd = data.get("cwd", "") or os.getcwd()
    if not session_id:
        return

    flag_path = os.path.expanduser(f"~/.claude/budget-flag-{session_id}.json")
    if not os.path.exists(flag_path):
        return

    try:
        with open(flag_path, encoding="utf-8") as f:
            flag = json.load(f)
    except Exception:
        return

    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    plan_path = os.path.join(cwd, "plan.md")
    summary_path = os.path.join(cwd, "summary.md")
    notes = []

    if not os.path.exists(plan_path):
        try:
            with open(plan_path, "w", encoding="utf-8") as f:
                f.write(
                    "# Plan\n\n"
                    f"_Auto-stub created {timestamp} because the session ended "
                    "under budget pressure without plan.md being written._\n\n"
                    "## Tasks\n"
                    "- [ ] Reconstruct deferred tasks from the conversation transcript and summary.md\n\n"
                    "## Notes\n"
                    "Keep this file as a checklist: mark completed tasks with [x], "
                    "pending tasks with [ ], and annotate budget deferrals with a date.\n"
                )
            notes.append("created stub plan.md")
        except Exception:
            pass

    if not os.path.exists(summary_path):
        try:
            with open(summary_path, "w", encoding="utf-8") as f:
                f.write(
                    "# Summary\n\n"
                    f"## {timestamp} (auto-stub)\n\n"
                    "Session hit budget pressure "
                    f"({flag.get('current', 0):,} tokens used of "
                    f"{flag.get('context_max', 0):,}) without writing a summary. "
                    "Review the conversation transcript to reconstruct what was done.\n"
                )
            notes.append("created stub summary.md")
        except Exception:
            pass

    try:
        os.unlink(flag_path)
    except OSError:
        pass

    if notes:
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "Stop",
                "additionalContext": "[BUDGET FINALIZER] " + ", ".join(notes),
            }
        }))

if __name__ == "__main__":
    main()
PYEOF
chmod +x ~/.claude/hooks/budget-finalizer.py

# budget-statusline.py (Claude Code status line)
# Uses Claude Code's documented context_window input instead of parsing JSONL.
cat > ~/.claude/hooks/budget-statusline.py << 'PYEOF'
#!/usr/bin/env python3
import json
import sys

BUDGET_CEILING_PCT = 0.90
BAR_WIDTH = 24

RESET = "\033[0m"
DIM = "\033[2m"
BOLD = "\033[1m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"

def fmt(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(n)

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    context = data.get("context_window") or {}
    usage = context.get("current_usage") or {}

    ctx_max = int(context.get("context_window_size") or 200_000)
    current = (
        int(usage.get("input_tokens") or 0)
        + int(usage.get("cache_read_input_tokens") or 0)
        + int(usage.get("cache_creation_input_tokens") or 0)
    )
    ceiling = int(ctx_max * BUDGET_CEILING_PCT)

    reported_pct = context.get("used_percentage")
    if reported_pct is None:
        pct = (current / ctx_max) if ctx_max else 0.0
    else:
        pct = float(reported_pct) / 100
    pct = max(0.0, min(pct, 1.0))
    pct_int = int(pct * 100)

    if pct < 0.70:
        color = GREEN
    elif pct < BUDGET_CEILING_PCT:
        color = YELLOW
    else:
        color = RED

    filled = min(BAR_WIDTH, int(round(pct * BAR_WIDTH)))
    bar = color + ("#" * filled) + RESET + DIM + ("-" * (BAR_WIDTH - filled)) + RESET

    free = max(0, ceiling - current)
    free_label = "free until ceiling" if pct < BUDGET_CEILING_PCT else "OVER ceiling"

    print(
        f"budget {bar} "
        f"{BOLD}{color}{pct_int}%{RESET} "
        f"{DIM}|{RESET} {fmt(current)}/{fmt(ctx_max)} tokens "
        f"{DIM}|{RESET} {color}~{fmt(free)} {free_label}{RESET}"
    )

if __name__ == "__main__":
    main()
PYEOF
chmod +x ~/.claude/hooks/budget-statusline.py

# settings.json patch
"$PYTHON_CMD" << 'PYEOF'
import json
import os

python_cmd = os.environ.get("CLAUDE_BUDGET_PYTHON_CMD", "python3")
path = os.path.expanduser("~/.claude/settings.json")
settings = {}

if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as f:
            settings = json.load(f)
    except Exception:
        settings = {}

hooks = settings.setdefault("hooks", {})

ups = hooks.setdefault("UserPromptSubmit", [])
estimator_cmd = f"{python_cmd} ~/.claude/hooks/budget-estimator.py"
if not any("budget-estimator.py" in h.get("command", "") for entry in ups for h in entry.get("hooks", [])):
    ups.append({"hooks": [{"type": "command", "command": estimator_cmd, "timeout": 5}]})

stop = hooks.setdefault("Stop", [])
finalizer_cmd = f"{python_cmd} ~/.claude/hooks/budget-finalizer.py"
if not any("budget-finalizer.py" in h.get("command", "") for entry in stop for h in entry.get("hooks", [])):
    stop.append({"hooks": [{"type": "command", "command": finalizer_cmd, "timeout": 5}]})

statusline_cmd = f"{python_cmd} ~/.claude/hooks/budget-statusline.py"
existing_statusline = settings.get("statusLine")
if (
    not isinstance(existing_statusline, dict)
    or not existing_statusline.get("command")
    or "budget-statusline.py" in existing_statusline.get("command", "")
):
    settings["statusLine"] = {
        "type": "command",
        "command": statusline_cmd,
        "padding": 0,
    }

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(settings, f, indent=2)
os.replace(tmp, path)
PYEOF

echo -e "  ${GREEN}ok${RESET} using Python command: ${PYTHON_CMD}"
echo -e "  ${GREEN}ok${RESET} budget-estimator.py -> ~/.claude/hooks/"
echo -e "  ${GREEN}ok${RESET} budget-finalizer.py -> ~/.claude/hooks/"
echo -e "  ${GREEN}ok${RESET} budget-statusline.py -> ~/.claude/hooks/"
echo -e "  ${GREEN}ok${RESET} settings.json patched"
echo ""
echo -e "Restart Claude Code to activate."
echo ""
