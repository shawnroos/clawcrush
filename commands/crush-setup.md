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

| # | PID | Name | Age | Owner | Classification | Reason |
|---|-----|------|-----|-------|----------------|--------|
(list each zombie from the scan)

Only `safe_kill` entries are ones the engine has positive proof are abandoned (`ppid=1` **and** a
deleted cwd, an MCP-server signature, or a dev-stack/headless-browser process holding no listening
socket — `ppid=1` on its own is a lifecycle fact, not abandonment). `consent_required` means the
process is attached to a live parent, and `protected` means it belongs to another worktree's live
session, is a daemon, is serving on a socket, or is on the never-kill allowlist — those are shown so
the user understands what clawcrush will *not* touch.

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

## Step 5: Scheduled Scan (report-only)

**The scheduled job does not kill anything.** `crush.sh cron` is a report-only dry run: it logs
`Cron dry-run: would-kill pid …` for genuine orphans past the age gate, and kills nothing.

This is deliberate. The old cron SIGTERM'd every pid the scanner returned, and the scanner counted a
process as a zombie purely for being older than an hour — so it was an hourly mass-kill of every live
session's MCP servers, suppressed only by an unrelated bug in the scheduler's locking. Re-arming it as
an actual killer is *unbuilt*, and should only be considered once the dry-run logs have soaked long
enough to show the classifier is precise in practice.

Describe it to the user as what it is: an hourly **scan that writes a report**, so they can see what
clawcrush *would* reclaim before trusting it to reclaim anything.

First, detect if que-do is available:

```bash
test -d "$HOME/.slate-queue" && test -f "$HOME/.slate-queue/queue.sh" && echo "QDO_AVAILABLE" || echo "QDO_MISSING"
```

### If que-do IS available:

Use AskUserQuestion to ask:

"Enable an hourly zombie **scan** (report-only — it logs what it would reclaim, and kills nothing)?

- **que-do** (recommended) — register with que-do scheduler. Gets retry logic, stall detection, manifest tracking, and Raycast visibility.
- **launchagent** — standalone macOS LaunchAgent (simpler, no que-do dependency)
- **skip** — no scheduled scan (run `/crush` manually)"

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

"Enable an hourly zombie scan? This installs a macOS LaunchAgent that scans on a schedule and writes a
report to `~/.claude/logs/clawcrush.log`. It is report-only — it kills nothing.

- **Yes** — install the hourly scan
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
- Scheduled scan: que-do / launchagent / skipped — **report-only, kills nothing**
- "Run `/crush` to start crushing."
