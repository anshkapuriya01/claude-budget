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

if ! command -v python3 &>/dev/null; then
  echo "Error: python3 is required." >&2
  exit 1
fi

mkdir -p ~/.claude/hooks

# ── budget-estimator.py (UserPromptSubmit hook) ─────────────────────────────
# Fires when the user submits a prompt. Estimates the prompt's likely token
# cost using a heuristic over prompt length + keyword scoring. Reads current
# context usage from the same JSONL transcripts Claude Code writes. If the
# projected total (current + estimate) exceeds 90% of the model's context
# window, injects a budget-aware reminder so Claude trims scope and reserves
# the remaining 10% for plan.md + summary.md.
cat > ~/.claude/hooks/budget-estimator.py << 'PYEOF'
#!/usr/bin/env python3
import json, os, re, sys, glob

MODEL_CONTEXT = {
    "claude-sonnet-4-6[1m]":     1_000_000,
    "claude-opus-4-7":           1_000_000,
    "claude-sonnet-4-6":           200_000,
    "claude-haiku-4-5-20251001":   200_000,
    "claude-haiku-4-5":            200_000,
}

# Reserve 10% of the context window for closing work.
BUDGET_CEILING_PCT = 0.90

# Keyword weights for cost estimation. Tuned conservatively — over-estimating
# is safer than under-estimating because the consequence of under-estimating
# is hitting the context ceiling with no summary written.
HEAVY = {
    "refactor": 12000, "rewrite": 12000, "migrate": 15000,
    "all files": 20000, "entire codebase": 20000, "every file": 18000,
    "whole project": 15000, "across the": 8000,
    "implement": 8000, "build a": 8000, "build the": 8000,
    "test suite": 10000, "audit": 9000, "comprehensive": 8000,
}
MEDIUM = {
    "fix": 3000, "add": 3000, "update": 3000, "change": 2500,
    "create": 4000, "write": 4000, "modify": 3000, "review": 4000,
    "debug": 4000, "explain": 2000, "analyze": 4000,
}
# Multipliers triggered by file/scope hints.
SCOPE_MULTIPLIERS = [
    (re.compile(r"\b(\d+)\s+files?\b", re.I), lambda m: 1 + 0.3 * int(m.group(1))),
    (re.compile(r"\ball\s+(tests|files|components|modules)\b", re.I), lambda m: 2.5),
    (re.compile(r"\beverywhere\b", re.I), lambda m: 2.0),
]

def estimate_prompt_cost(prompt: str) -> int:
    """Return a conservative token-cost estimate for executing this prompt."""
    if not prompt:
        return 1500
    text = prompt.lower()

    # Base: prompt size itself, plus a floor for any non-trivial response.
    # Rough rule: 1 token per 4 chars of prompt; response is usually 3–8x prompt.
    prompt_tokens = max(len(prompt) // 4, 50)
    base = 2000 + prompt_tokens * 4

    # Keyword contributions.
    keyword_total = 0
    for kw, weight in HEAVY.items():
        if kw in text:
            keyword_total += weight
    for kw, weight in MEDIUM.items():
        if kw in text:
            keyword_total += weight

    subtotal = base + keyword_total

    # Scope multipliers stack multiplicatively.
    multiplier = 1.0
    for pattern, fn in SCOPE_MULTIPLIERS:
        m = pattern.search(prompt)
        if m:
            multiplier *= fn(m)

    estimate = int(subtotal * multiplier)
    # Clamp to a sane range.
    return max(1500, min(estimate, 500_000))

def read_current_usage(session_id: str, cwd: str):
    """Return (current_tokens, model) from the latest assistant message in JSONL.
    Returns (0, None) if no transcript exists yet (first prompt of session)."""
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
        with open(jsonl_path) as f:
            for line in f:
                try:
                    d = json.loads(line)
                    if d.get("type") == "assistant":
                        msg = d.get("message", {})
                        usage = msg.get("usage", {})
                        if usage:
                            last_usage = usage
                            last_model = msg.get("model") or last_model
                except Exception:
                    pass
    except Exception:
        return 0, None

    if not last_usage:
        return 0, last_model
    total = (
        last_usage.get("input_tokens", 0)
        + last_usage.get("cache_read_input_tokens", 0)
        + last_usage.get("cache_creation_input_tokens", 0)
    )
    return total, last_model

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    prompt = data.get("prompt", "") or ""
    session_id = data.get("session_id", "") or ""
    cwd = data.get("cwd", "") or os.getcwd()

    current, model = read_current_usage(session_id, cwd)
    model = model or os.environ.get("ANTHROPIC_MODEL", "claude-opus-4-7")
    context_max = MODEL_CONTEXT.get(model, 200_000)

    estimate = estimate_prompt_cost(prompt)
    projected = current + estimate
    ceiling = int(context_max * BUDGET_CEILING_PCT)

    # Persist a flag so the Stop hook knows whether to enforce closing files.
    flag_dir = os.path.expanduser("~/.claude")
    os.makedirs(flag_dir, exist_ok=True)
    flag_path = os.path.join(flag_dir, f"budget-flag-{session_id}.json")

    if projected <= ceiling:
        # Within budget — clear any stale flag and exit silently.
        try:
            os.unlink(flag_path)
        except OSError:
            pass
        sys.exit(0)

    # Over budget. Write flag and inject a reminder.
    try:
        with open(flag_path, "w") as f:
            json.dump({
                "cwd": cwd,
                "current": current,
                "estimate": estimate,
                "projected": projected,
                "ceiling": ceiling,
                "context_max": context_max,
            }, f)
    except Exception:
        pass

    remaining = context_max - current
    reminder = (
        f"[BUDGET NOTICE — context window is tight]\n"
        f"Current usage: {current:,} tokens of {context_max:,} "
        f"({current * 100 // context_max}%).\n"
        f"Estimated cost of this request: ~{estimate:,} tokens.\n"
        f"Hard ceiling: {ceiling:,} tokens (90% of window).\n"
        f"Available before ceiling: ~{ceiling - current:,} tokens.\n\n"
        f"Instructions for this turn:\n"
        f"1. Do NOT compromise quality on whatever you do execute. Better to "
        f"finish 60% of the work properly than 100% sloppily.\n"
        f"2. Identify the highest-value subset of the user's request that fits "
        f"in the available budget, leaving ~{context_max - ceiling:,} tokens "
        f"(10% of window) free.\n"
        f"3. Execute that subset to full quality.\n"
        f"4. Before context fills, write/update two files in the project root "
        f"({cwd}):\n"
        f"   - plan.md: the original plan, marked with what's done and what "
        f"remains. Create it if it doesn't exist.\n"
        f"   - summary.md: a concise summary of what was accomplished this "
        f"session, decisions made, and where to resume. Create it if it "
        f"doesn't exist; append a new dated section if it does.\n"
        f"5. Tell the user briefly that you trimmed scope due to budget and "
        f"point them to plan.md/summary.md for the remainder.\n"
    )

    # Claude Code reads `additionalContext` from UserPromptSubmit hook output
    # and prepends it to the prompt before sending to the model.
    output = {
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": reminder,
        }
    }
    print(json.dumps(output))
    sys.exit(0)

if __name__ == "__main__":
    main()
PYEOF
chmod +x ~/.claude/hooks/budget-estimator.py

# ── budget-finalizer.py (Stop hook) ─────────────────────────────────────────
# Fires when Claude finishes responding. If the session was flagged as
# budget-constrained, verifies plan.md and summary.md exist in cwd. If either
# is missing, writes a minimal stub so the user isn't left without a paper
# trail when context is exhausted.
cat > ~/.claude/hooks/budget-finalizer.py << 'PYEOF'
#!/usr/bin/env python3
import json, os, sys, datetime

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    session_id = data.get("session_id", "") or ""
    cwd = data.get("cwd", "") or os.getcwd()
    if not session_id:
        sys.exit(0)

    flag_path = os.path.expanduser(f"~/.claude/budget-flag-{session_id}.json")
    if not os.path.exists(flag_path):
        sys.exit(0)

    try:
        with open(flag_path) as f:
            flag = json.load(f)
    except Exception:
        sys.exit(0)

    plan_path = os.path.join(cwd, "plan.md")
    summary_path = os.path.join(cwd, "summary.md")
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")

    notes = []
    if not os.path.exists(plan_path):
        try:
            with open(plan_path, "w") as f:
                f.write(
                    f"# Plan\n\n"
                    f"_Auto-stub created {timestamp} because session ended "
                    f"under budget pressure and no plan.md was written._\n\n"
                    f"## Status\nUnknown — Claude did not record plan state "
                    f"before the session ended.\n\n"
                    f"## Next steps\nReview summary.md and the conversation "
                    f"transcript to reconstruct remaining work.\n"
                )
            notes.append("created stub plan.md")
        except Exception:
            pass

    if not os.path.exists(summary_path):
        try:
            with open(summary_path, "w") as f:
                f.write(
                    f"# Summary\n\n"
                    f"## {timestamp} (auto-stub)\n\n"
                    f"Session hit the budget ceiling "
                    f"({flag.get('current', 0):,} tokens used of "
                    f"{flag.get('context_max', 0):,}) without writing a "
                    f"summary. Review the conversation transcript to "
                    f"reconstruct what was done.\n"
                )
            notes.append("created stub summary.md")
        except Exception:
            pass

    # Clear the flag so the next prompt starts clean.
    try:
        os.unlink(flag_path)
    except OSError:
        pass

    if notes:
        # additionalContext on Stop is shown to Claude on the next turn; harmless
        # if the session truly ended.
        msg = (
            f"[BUDGET FINALIZER] Session ended under budget pressure. "
            f"Actions taken: {', '.join(notes)}."
        )
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "Stop", "additionalContext": msg
        }}))
    sys.exit(0)

if __name__ == "__main__":
    main()
PYEOF
chmod +x ~/.claude/hooks/budget-finalizer.py

# ── settings.json patch ─────────────────────────────────────────────────────
# Idempotent: appends our hooks without clobbering existing ones (e.g. headroom).
python3 << 'EOF'
import json, os

path = os.path.expanduser("~/.claude/settings.json")
settings = {}
if os.path.exists(path):
    with open(path) as f:
        try:
            settings = json.load(f)
        except Exception:
            pass

hooks = settings.setdefault("hooks", {})

# UserPromptSubmit: estimator
ups = hooks.setdefault("UserPromptSubmit", [])
estimator_cmd = "python3 ~/.claude/hooks/budget-estimator.py"
if not any(h.get("command") == estimator_cmd
           for entry in ups for h in entry.get("hooks", [])):
    ups.append({
        "hooks": [{"type": "command", "command": estimator_cmd, "timeout": 5}]
    })

# Stop: finalizer
stop = hooks.setdefault("Stop", [])
finalizer_cmd = "python3 ~/.claude/hooks/budget-finalizer.py"
if not any(h.get("command") == finalizer_cmd
           for entry in stop for h in entry.get("hooks", [])):
    stop.append({
        "hooks": [{"type": "command", "command": finalizer_cmd, "timeout": 5}]
    })

tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2)
os.replace(tmp, path)
EOF

echo -e "  ${GREEN}✓${RESET} budget-estimator.py → ~/.claude/hooks/"
echo -e "  ${GREEN}✓${RESET} budget-finalizer.py → ~/.claude/hooks/"
echo -e "  ${GREEN}✓${RESET} settings.json patched"
echo ""
echo -e "Restart Claude Code to activate."
echo ""