# claude-budget

Token-budget-aware execution hooks for [Claude Code](https://www.claude.com/product/claude-code). When your context window crosses 90%, Claude switches to **partial execution mode** — it breaks the request into discrete tasks, completes only as many as fit at full quality, and defers the rest into `plan.md` and `summary.md` (your project's persistent memory). Example: if you ask for 10 tasks and only 7 fit, Claude finishes 7 properly and records the remaining 3 as deferred so the next session can pick them up.

A live progress bar also renders below the chat box, showing current context usage, remaining tokens, and how close you are to the 90% ceiling — green under 70%, yellow up to 90%, red beyond.

No API calls. No subscription. Pure heuristic estimation, runs entirely on your machine.

## Make Sure that WSL is installed in your windows system .

Run powershell as Administrator.
```powershell
wsl --install
```


## Install

```bash
curl -fsSL https://raw.githubusercontent.com/anshkapuriya01/claude-budget/main/install.sh | bash
```

Then restart Claude Code.

If you'd rather inspect before running:

```bash
curl -fsSL https://raw.githubusercontent.com/anshkapuriya01/claude-budget/main/install.sh -o install.sh
less install.sh
bash install.sh
```

## Check the Installation
Restart Claude Code. In any project, send the verify prompt:

Run:
```
 python --version && type %USERPROFILE%\.claude\settings.json
```
If you see Python 3.x and a settings.json with hooks pointing to python ~/.claude/hooks/..., you're live.


## WSL Error
wsl may write the files in linux home. To fix that you have to copy that files to windows using this command
```
wsl bash -c "mkdir -p /mnt/c/Users/kapur/.claude/hooks && cp ~/.claude/hooks/budget-estimator.py /mnt/c/Users/kapur/.claude/hooks/ && cp ~/.claude/hooks/budget-finalizer.py /mnt/c/Users/kapur/.claude/hooks/ && echo done"
```

The install also patched WSL's settings.json, not your Windows one. We need to update the Windows version. Run this in CMD:
```
wsl python3 -c "import json,os; p='/mnt/c/Users/kapur/.claude/settings.json'; s=json.load(open(p)) if os.path.exists(p) else {}; h=s.setdefault('hooks',{}); ups=h.setdefault('UserPromptSubmit',[]); ec='python3 ~/.claude/hooks/budget-estimator.py'; (ups.append({'hooks':[{'type':'command','command':ec,'timeout':5}]}) if not any(x.get('command')==ec for e in ups for x in e.get('hooks',[])) else None); st=h.setdefault('Stop',[]); fc='python3 ~/.claude/hooks/budget-finalizer.py'; (st.append({'hooks':[{'type':'command','command':fc,'timeout':5}]}) if not any(x.get('command')==fc for e in st for x in e.get('hooks',[])) else None); json.dump(s,open(p,'w'),indent=2); print('patched')"
```
## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/anshkapuriya01/claude-budget/main/uninstall.sh | bash
```

## How it works

Three scripts get installed in `~/.claude/hooks/`:

- **`budget-estimator.py`** runs on every prompt you submit. It heuristically estimates the prompt's token cost (length + keyword scoring), reads your current context usage from Claude Code's session JSONL, and if the projected total exceeds 90% of the model's context window, prepends a **partial-execution** reminder to your prompt. The reminder tells Claude to (1) enumerate the discrete tasks in your request, (2) execute only the subset that fits at full quality — never cram or compress to fit more — and (3) record the deferred tasks in `plan.md` (a checklist with `[x]` / `[ ]` markers) and `summary.md` (a dated session log). Both files are created if they don't exist and updated in place if they do, so they accumulate as the project's persistent memory across sessions.
- **`budget-finalizer.py`** runs when Claude finishes responding. If the session was budget-flagged but `plan.md` or `summary.md` weren't written, it creates minimal stubs as a fallback so you're never left without a paper trail.
- **`budget-statusline.py`** is wired into Claude Code's `statusLine` setting and renders a live progress bar below the chat box. After every turn it reads the latest usage from the session transcript and prints something like `budget ███████████░░░░░░░░░░░░ 47% │ 94k/200k tokens │ ~86k free until ceiling`. The bar shifts color (green → yellow → red) as you approach the 90% ceiling, so you can see room remaining at a glance. Install only sets `statusLine` if you don't already have a custom one configured.

The estimator and finalizer are silent when you're under 90% — zero overhead when not triggered. The status line runs every turn but is cheap (just one transcript read + a print).

## Tuning

The keyword weights live in `~/.claude/hooks/budget-estimator.py` under `HEAVY` and `MEDIUM`. If the reminder fires too aggressively or too rarely, edit those dictionaries directly. The 90% ceiling is the `BUDGET_CEILING_PCT` constant at the top.

## Compatibility

Plays nicely with [headroom](https://github.com/) and other Claude Code hooks — installs into `settings.json` without clobbering existing entries.

## License

MIT