# claude-budget

Token-budget-aware execution hooks for [Claude Code](https://www.claude.com/product/claude-code). When your context window crosses 90%, Claude is automatically instructed to trim scope, finish what it does take on at full quality, and write `plan.md` and `summary.md` to your project root before context runs out — so you have a clean handoff when you `/clear` and start fresh.

No API calls. No subscription. Pure heuristic estimation, runs entirely on your machine.

## Make Sure that WSL is installed in your windows system.

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

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/anshkapuriya01/claude-budget/main/uninstall.sh | bash
```

## How it works

Two hooks get installed in `~/.claude/hooks/`:

- **`budget-estimator.py`** runs on every prompt you submit. It heuristically estimates the prompt's token cost (length + keyword scoring), reads your current context usage from Claude Code's session JSONL, and if the projected total exceeds 90% of the model's context window, prepends a budget reminder to your prompt instructing Claude to trim scope and reserve the last 10% for closing files.
- **`budget-finalizer.py`** runs when Claude finishes responding. If the session was budget-flagged but `plan.md` or `summary.md` weren't written, it creates minimal stubs as a fallback.

Both hooks are silent when you're under 90%. Zero overhead when not triggered.

## Tuning

The keyword weights live in `~/.claude/hooks/budget-estimator.py` under `HEAVY` and `MEDIUM`. If the reminder fires too aggressively or too rarely, edit those dictionaries directly. The 90% ceiling is the `BUDGET_CEILING_PCT` constant at the top.

## Compatibility

Plays nicely with [headroom](https://github.com/) and other Claude Code hooks — installs into `settings.json` without clobbering existing entries.

## License

MIT