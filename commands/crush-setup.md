---
description: Global system scan — creates .crushignore and configures ClawCrush
allowed-tools: Read, Write, Bash(*), Glob, Grep, AskUserQuestion
---

# ClawCrush Setup

Run a global scan to understand the user's system, then create a `.crushignore` file in the current working directory.

## Step 1: Global Scan

Run the scanner in global mode:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/crush.sh scan --global
```

Also run a local CWD scan to see repo-level slop:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/crush.sh scan
```

Parse the JSON output from both scans.

## Step 2: Present Findings

Present the results in formatted sections. Use this layout:

### System-wide findings:

**Zombie Processes:**

| # | PID | Name | Age | Reason |
|---|-----|------|-----|--------|
(list each zombie from the scan)

If no zombies: "No zombie processes found."

**Orphaned Project References** (in `~/.claude/projects/`):

Show count and total size. List a few examples if many exist.

**Config Backups** (in `~/.claude/`):

Show count and total size of `.backup` files.

**Plugin Cache:**

Show size and entry count.

### Current repo findings:

**Slop Files:**

| # | File | Type | Size |
|---|------|------|------|
(list each slop file from the scan)

If no slop: "This repo is clean."

## Step 3: Recommend .crushignore

Based on what was found in the CWD repo, recommend which patterns should be KEPT (ignored by ClawCrush). Look at the untracked files and suggest patterns for anything that looks intentional — like `docs/plans/**`, `docs/brainstorms/**`, `.beads/`, screenshot directories used for testing, etc.

Use AskUserQuestion to ask the user:

"Here's my recommended .crushignore. Edit or confirm:

```
# default: lowfat
(recommended patterns, one per line)
```

**Options:**
- Confirm as-is
- Add or remove patterns
- Change default to fullcream"

## Step 4: Create .crushignore

Write the `.crushignore` file to the CWD root with the confirmed content. The first non-comment line should be the default mode comment: `# default: lowfat` or `# default: fullcream`.

Format:
```
# ClawCrush config
# default: lowfat

# Patterns below survive the crush (gitignore syntax)
docs/plans/**
docs/brainstorms/**
.beads/
```

## Step 5: Scheduled Auto-Crush

First, detect if que-do is available:

```bash
test -d "$HOME/.slate-queue" && test -f "$HOME/.slate-queue/queue.sh" && echo "QDO_AVAILABLE" || echo "QDO_MISSING"
```

### If que-do IS available:

Use AskUserQuestion to ask:

"Enable automatic zombie crushing every hour?

- **que-do** (recommended) — register with que-do scheduler. Gets retry logic, stall detection, manifest tracking, and Raycast visibility.
- **launchagent** — standalone macOS LaunchAgent (simpler, no que-do dependency)
- **skip** — no auto-crush (run `/crush` manually)"

**If que-do selected:**

Run the que-do registration script:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-quedo.sh
```

This creates the runner script, registers with que-do, and verifies the LaunchAgent loaded.

**If launchagent selected:**

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/crush.sh setup-launchagent
```

### If que-do is NOT available:

Use AskUserQuestion to ask:

"Enable automatic zombie crushing every hour? This installs a macOS LaunchAgent that silently kills orphaned MCP processes on a schedule.

- **Yes** — install hourly auto-crush
- **No** — skip (you can always run /crush manually)"

If yes, run:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/crush.sh setup-launchagent
```

Report the result.

## Step 6: Summary

Show a brief summary:
- `.crushignore` created with X patterns
- Default mode: lowfat/fullcream
- Auto-crush: que-do / launchagent / skipped
- "Run `/crush` to start crushing."
