# claude-budget

Token-budget-aware helper hooks for Claude Code.

This project does two things:

- Adds budget guidance to a prompt when the next turn is estimated to push the current context above 90%.
- Shows a live status line with current context usage, token counts, and remaining room before the 90% ceiling.

The hooks do not make API calls and do not enforce behavior outside Claude Code. The estimator can add context that asks Claude to do partial execution and maintain `plan.md` / `summary.md`; Claude still performs the work through its normal model behavior.

## Install

Run from Git Bash, WSL, macOS, or Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/anshkapuriya01/claude-budget/main/install.sh | bash
```

Then restart Claude Code.

If you would rather inspect before running:

```bash
curl -fsSL https://raw.githubusercontent.com/anshkapuriya01/claude-budget/main/install.sh -o install.sh
less install.sh
bash install.sh
```

The installer looks for a Python 3 command in this order: `python3`, `python`, then `py`. It writes the command that worked into `~/.claude/settings.json`, so Windows installs do not depend on `python3` being on PATH.

## Verify

In the same shell you use to launch Claude Code:

```bash
python --version || python3 --version || py --version
cat ~/.claude/settings.json
```

You should see hooks for:

- `budget-estimator.py`
- `budget-finalizer.py`
- `budget-statusline.py`

If the status line still does not appear, run Claude Code with `--debug`. Claude Code logs the first status-line command error in debug output.

## Clean Old Installs

If you previously installed a broken version, uninstall it before reinstalling.

From Git Bash, WSL, macOS, or Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/anshkapuriya01/claude-budget/main/uninstall.sh | bash
```

Or, if you already cloned this repo:

```bash
bash uninstall.sh
```

Then confirm the old files are gone:

```bash
ls ~/.claude/hooks/budget-*.py
cat ~/.claude/settings.json
```

The `ls` command should report no `budget-*.py` files. `settings.json` should no longer contain `budget-estimator.py`, `budget-finalizer.py`, or `budget-statusline.py`.

On Windows PowerShell, you can inspect the Windows Claude Code config directly:

```powershell
Get-ChildItem "$env:USERPROFILE\.claude\hooks\budget-*.py"
Get-Content "$env:USERPROFILE\.claude\settings.json"
```

If those files or settings entries still exist after running the uninstaller, remove only the `budget-*.py` files and only the settings entries that mention this project. Do not delete unrelated Claude Code settings or hooks.

## How It Works

Three scripts get installed in `~/.claude/hooks/`:

- `budget-estimator.py` runs on `UserPromptSubmit`. It estimates prompt cost from prompt length and scope keywords, reads current usage from Claude Code's JSONL transcript, and injects partial-execution guidance only when projected usage exceeds 90%.
- `budget-finalizer.py` runs on `Stop`. If a budget flag was set and `plan.md` or `summary.md` were not created, it writes minimal fallback stubs.
- `budget-statusline.py` is configured as Claude Code's `statusLine`. It reads Claude Code's documented `context_window` JSON from stdin and prints a color-coded ASCII progress bar.

The status line looks like:

```text
budget ###########------------- 47% | 94k/200k tokens | ~86k free until ceiling
```

Colors are green under 70%, yellow from 70% to 89%, and red at 90% or higher.

## Important Limits

This is a helper, not a hard scheduler.

- The estimator cannot force Claude to complete exactly N tasks.
- `plan.md` and `summary.md` are only meaningful if Claude follows the injected guidance or the finalizer creates fallback stubs.
- Token estimates are heuristic. Claude Code's status line is the more accurate live usage display because it uses `context_window.current_usage`.

## Tuning

Edit `~/.claude/hooks/budget-estimator.py` after installation:

- `BUDGET_CEILING_PCT` controls the trigger threshold.
- `HEAVY`, `MEDIUM`, and `SCOPE_MULTIPLIERS` control prompt-cost estimation.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/anshkapuriya01/claude-budget/main/uninstall.sh | bash
```

The uninstaller removes only this project's hook scripts and settings entries.

## Compatibility

Claude Code supports status lines through the `statusLine` setting in `~/.claude/settings.json`. On Windows, Claude Code runs status-line commands through Git Bash, so this installer avoids Windows-only path syntax and writes a shell-compatible Python command.

## License

MIT
