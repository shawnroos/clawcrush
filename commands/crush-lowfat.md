---
description: Supervised crush — scan and present results for user selection
allowed-tools: Read, Bash(*), Glob, Grep, AskUserQuestion
---

# ClawCrush — Lowfat Mode (Supervised)

Scan for zombies and slop, present formatted tables, let the user choose what to crush.

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

Parse the JSON output. It contains two arrays: `zombies` and `slop`.

Each slop item has a `tracked` field (true/false). Tracked items are **report-only** — they cannot be deleted by ClawCrush because they're committed to git. Separate them from untracked items.

## Step 3: Present Results

Display results using numbered markdown tables. Number **crushable items** (zombies + untracked slop) sequentially so the user can select by number. Show tracked slop in a separate unnumbered table.

If there are zombie processes, show:

### Zombie Processes

| # | PID | Name | Age | Reason |
|---|-----|------|-----|--------|
| 1 | 12847 | remote | 3h 12m | ppid=1 (orphaned) |
| 2 | 13201 | chromium | 1h 44m | ppid=1 (orphaned) |

If there are untracked slop files, show:

### Repo Slop (untracked — crushable)

| # | File | Type | Size |
|---|------|------|------|
| 3 | arras-debug.log | log | 24K |
| 4 | test-tool-sync12.js | dupe | 3K |

If there are tracked slop files, show them separately:

### Committed Slop (report only — needs git rm)

| File | Type | Size |
|------|------|------|
| arras-crash.log | log | 12K |
| temp-utils.ts | temp | 2K |

Add a note: "These files are tracked by git. To remove them, use `git rm` and commit."

If ALL tables are empty: Say "Nothing to crush. This repo is clean." and stop.

## Step 4: User Selection

Use AskUserQuestion to ask:

"What do you want to crush?

- **all** — crush everything listed above (zombies + untracked slop)
- **1,3,5** — crush specific items by number
- **none** — abort, crush nothing"

## Step 5: Execute

Based on the user's selection:

**If "all":** Kill all zombie PIDs and delete all untracked slop files. Never touch tracked files.

**If specific numbers:** Map the numbers back to the corresponding PIDs or file paths. Kill/delete only those.

**If "none":** Say "Nothing crushed." and stop.

For killing processes, run:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/crush.sh kill <pid1> <pid2> ...
```

For deleting files, run:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/crush.sh delete <file1> <file2> ...
```

## Step 6: Summary

Show a final summary line:

"Crushed: X zombies killed, Y files deleted (Z reclaimed)"

If tracked slop was found, add: "+ N committed slop files flagged (use git rm to clean)"

Use the `killed`, `deleted`, and `freed_fmt` values from the script output.
