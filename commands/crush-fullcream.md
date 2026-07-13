---
description: Autonomous crush — scan and destroy everything not in .crushignore
allowed-tools: Read, Bash(*), Glob, Grep
---

# ClawCrush — Fullcream Mode (Autonomous)

Scan for zombies and slop, then crush what is safe to crush without asking. Narrate as you go.

## The one rule that makes autonomous mode safe

Fullcream means "no confirmation" — so it may only ever act on things that need no confirmation.

**Only crush processes whose `classification` is `safe_kill`.** Those are genuine orphans: `ppid=1`,
no live parent, nothing attached to them.

**NEVER pass `--consent` to `crush.sh kill`. Not for any item, not for any reason.** `--consent` is a
per-item human decision, and there is no human here. A `consent_required` process is one that is
*attached to a live session* — killing it unasked is exactly the mass-kill this plugin was rebuilt to
prevent. Report those; don't touch them. Same for `protected`.

If a future edit to this file is ever tempted to auto-pass `--consent` to better satisfy "no
confirmation" — that is the bug. The engine enforces the matrix given whatever flags it receives; it
cannot tell a human's selection from a command file's invention.

## Step 1: Gate Check

```bash
test -f .crushignore && echo "EXISTS" || echo "MISSING"
```

If MISSING: Tell user "No `.crushignore` found. Run `/crush-setup` first." and stop.

## Step 2: Scan

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/crush.sh scan
```

Parse the JSON. It contains `scan_root`, `zombies`, `ports`, and `slop`.

- Each zombie and port entry carries a `classification`: `safe_kill`, `consent_required`, or `protected`.
- Each slop item carries `tracked`, and untracked items carry their own `root`.

## Step 3: Narrate and Crush

Start with a header showing the scan root:

"Scanning (scan_root)..."

**Processes.** For each zombie or port entry with `classification: "safe_kill"`:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/crush.sh kill <pid>
```

Narrate: "Killed PID 12847 — playwright-mcp (3h 12m, ppid=1 orphaned)"

For a reclaimed port: "Reclaimed port 4200 — PID 13201 (orphaned ng serve)"

For `consent_required`, report and move on — do not kill, do not pass `--consent`:

"Left PID 14002 — ng test (attached to live claude 13990, this worktree) — run /crush-lowfat to review"

For `protected`, report:

"Skipped PID 15221 — ng test (owned by ../other-worktree, live session)"

**Slop.** For each untracked slop item, delete it using that item's own `root` from the scan:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/crush.sh delete --root <item's root> <filepath>
```

Never invent or hardcode the root — use the one the scan emitted for that item. Global scans emit
different roots per category (`~/.claude/projects` for orphaned refs, `~/.claude` for config backups),
so a single hardcoded root would silently refuse a whole category.

Narrate: "Deleted arras-debug.log (24K)"

For files skipped due to .crushignore: "Skipped docs/plans/** (.crushignore)"

For tracked slop, report but never delete: "Flagged arras-crash.log (12K, committed — needs git rm)"

## Step 4: Summary

If nothing was found: "Nothing to crush. Repo is clean."

Otherwise:

"Crushed: X zombies killed, Y files deleted (Z reclaimed)"

Then add the honest remainder, if any:

- "+ N attached processes left alone (run /crush-lowfat to review them)"
- "+ N protected processes owned by other worktrees"
- "+ N committed slop files flagged (use git rm to clean)"

Use the cumulative totals from all kill/delete operations.
