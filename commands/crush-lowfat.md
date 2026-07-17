---
description: Supervised crush — scan and present results for user selection
allowed-tools: Read, Bash(*), Glob, Grep, AskUserQuestion
---

# ClawCrush — Lowfat Mode (Supervised)

Scan, present formatted tables, let the user choose what to crush.

Lowfat is the **only** mode that may ever construct a `--consent` flag, and only ever from an explicit
per-item selection the user made in `AskUserQuestion`. Never batch it, never infer it, never synthesize
it to "save a step". The engine cannot tell a human's selection from an invented one — that guarantee
lives here, in this file.

## Step 1: Gate Check

```bash
test -f .crushignore && echo "EXISTS" || echo "MISSING"
```

If MISSING: Tell user "No `.crushignore` found. Run `/crush-setup` first." and stop.

## Step 2: Scan

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/crush.sh scan
```

Parse the JSON: `scan_root`, `zombies`, `ports`, `slop`.

Every zombie and port entry carries a `classification`:

| classification | meaning | what lowfat may do |
|---|---|---|
| `safe_kill` | `ppid=1` **and** positive proof of abandonment: a deleted cwd, an MCP-server signature, or a dev-stack/headless-browser process holding no listening socket | offer it; kill with a plain `kill <pid>` |
| `consent_required` | attached to a live parent, owned by this worktree (or owner unresolvable) | offer it **individually**; kill only with `--consent <pid>` |
| `protected` | another worktree's live session, a daemon, anything serving on a socket, crush's own tree, or the never-kill allowlist | **never offer it.** Display only. |

`ppid=1` on its own is **never** `safe_kill`. It is a lifecycle fact — launchd services, tmux, and
self-daemonizing servers are `ppid=1` for their entire life, and a dev server launched with
`nohup … & disown` is `ppid=1` from birth. Ownership is not abandonment evidence either. Unknowns
(an `lsof` failure, an unresolvable cwd) are never killable. **Do not re-derive any of this in the
command layer — read `classification` and obey it.** The engine is the only place that decides.

Slop items carry `tracked` (report-only when true) and, when untracked, their own `root`.

## Step 3: Present Results

Number only the **selectable** items (`safe_kill` + `consent_required` processes, and untracked slop).
`protected` items and tracked slop get their own unnumbered, display-only tables.

### Zombie Processes

| # | PID | Name | Age | Owner | Classification | Reason |
|---|-----|------|-----|-------|----------------|--------|
| 1 | 12847 | playwright-mcp | 3h 12m | (this worktree) | safe_kill | ppid=1 (orphaned) |
| 2 | 14002 | ng test | 1h 44m | (this worktree) | consent_required | attached to live claude (pid 13990) |

### Port Squatters

| # | Port | PID | Command | Owner | Classification |
|---|------|-----|---------|-------|----------------|
| 3 | 4200 | 13201 | ng serve | (this worktree) | safe_kill |

### Protected — display only, cannot be crushed

| PID | Name | Owner | Why |
|-----|------|-------|-----|
| 15221 | ng test | ../other-worktree | live session in another worktree |
| 15400 | npm install | (this worktree) | never-kill allowlist (mid-flight install) |

Note under it: "These belong to other live sessions or are unsafe to interrupt. ClawCrush will not
kill them, and they cannot be selected."

### Repo Slop (untracked — crushable)

| # | File | Type | Size |
|---|------|------|------|
| 4 | arras-debug.log | log | 24K |

### Committed Slop (report only — needs git rm)

| File | Type | Size |
|------|------|------|
| arras-crash.log | log | 12K |

Add: "These files are tracked by git. To remove them, use `git rm` and commit."

If every selectable table is empty, say "Nothing to crush." and stop — but still show the protected
table if it has rows. Knowing *why* nothing was crushed is the useful part.

## Step 4: User Selection

Use AskUserQuestion for a **per-item** selection. Make consent items visibly distinct — the user is
being asked to kill something attached to a live process:

"What do you want to crush?

- **1** — playwright-mcp (orphaned, safe)
- **2** — ng test — ATTACHED to a live session in this worktree; killing it stops a running test
- **3** — port 4200 (orphaned ng serve)
- **4** — arras-debug.log
- **none** — crush nothing"

Do not offer an "all" that sweeps `consent_required` items in with the orphans. If the user wants
everything, they can select everything — the point is that each attached process is an explicit,
individual choice.

## Step 5: Execute

**Processes.** Build the kill command from what the user actually selected:

- `safe_kill` pids: pass them plainly.
- `consent_required` pids: pass each as `--consent <pid>` — and **only** those the user selected by
  number in Step 4.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/crush.sh kill <safe_pid> --consent <selected_attached_pid>
```

Never add `--consent` for a pid the user did not individually select. Never add it for a `protected`
pid — the engine refuses it regardless, and reaching for it means the flow has drifted.

**Slop.** Delete with each item's own `root` from the scan — never a hardcoded root:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/crush.sh delete --root <item's root> <filepath>
```

## Step 6: Summary

"Crushed: X zombies killed, Y files deleted (Z reclaimed)"

Use the `killed`, `refused`, `deleted`, and `freed_fmt` values from the script output. If `refused` is
non-zero, say so plainly and why — a refusal is the safety model working, not an error to paper over.

Add, when applicable:
- "+ N protected processes (other worktrees' live sessions) — untouched"
- "+ N committed slop files flagged (use git rm to clean)"

## Optional: load contention

If the machine feels slow, or the scan shows dev/test processes across several worktrees, run the
read-only report:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/crush.sh contention
```

If `ratio` (load ÷ cores) is well above 1 and `groups` shows several worktrees each running
`ng test`/`tsc`, say so and recommend **rerouting spec validation to CI** rather than killing the
siblings. That is usually the right fix: the contention, not the diff, is why the tests time out.
Contention never kills anything.
