---
description: Autonomous crush — scan and destroy everything not in .crushignore
allowed-tools: Read, Bash(*), Glob, Grep
---

# ClawCrush — Fullcream Mode (Autonomous)

Scan for zombies and slop, then crush everything. No confirmation. Narrate as you go.

## Step 1: Gate Check

```bash
test -f .crushignore && echo "EXISTS" || echo "MISSING"
```

If MISSING: Tell user "No `.crushignore` found. Run `/crush-setup` first." and stop.

## Step 2: Scan

Run the scanner:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/crush.sh scan
```

Parse the JSON output. Each slop item has a `tracked` field. Only crush items where `tracked` is `false`. Tracked items are reported but never touched.

## Step 3: Narrate and Crush

Start with a header showing the CWD:

"Scanning (current directory path)..."

If there are zombie processes, kill them one by one and narrate each:

For each zombie, run:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/crush.sh kill <pid>
```

And output a line like:
"Killed PID 12847 — remote (3h 12m, orphaned)"

If there are untracked slop files, delete them and narrate each:

For each untracked slop file, run:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/crush.sh delete <filepath>
```

And output a line like:
"Deleted arras-debug.log (24K)"

For files skipped due to .crushignore, note:
"Skipped docs/plans/** (.crushignore)"

For tracked slop files, report but do not delete:
"Flagged arras-crash.log (12K, committed — needs git rm)"

## Step 4: Summary

If nothing was found: "Nothing to crush. Repo is clean."

Otherwise show a final summary:

"Crushed: X zombies killed, Y files deleted (Z reclaimed)"

If tracked slop was found, add: "+ N committed slop files flagged (use git rm to clean)"

Use the cumulative totals from all kill/delete operations.
