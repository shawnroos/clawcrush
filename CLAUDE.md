# ClawCrush

ClawCrush finds and destroys zombie processes and repo slop spawned by Claude Code sessions.

## Two Claws

1. **Process Claw** — kills orphaned MCP servers, stale node processes, abandoned browser instances
2. **Slop Claw** — destroys untracked garbage files in repos (debug logs, numbered dupes, temp files, test artifacts). Also detects tracked slop (committed garbage) and reports it without deleting.

## Commands

- `/crush` — dispatcher. Checks for `.crushignore` gate, routes to user's default mode (lowfat or fullcream). First run forces `/crush-setup`.
- `/crush-setup` — global system scan. Recommends `.crushignore` contents. Creates the file. Sets default mode. Optionally installs hourly LaunchAgent for zombie killing.
- `/crush-lowfat` — supervised mode. Presents formatted tables of zombies and slop. Uses AskUserQuestion for user to multi-select what to crush.
- `/crush-fullcream` — autonomous mode. Scans, narrates, and destroys everything not in `.crushignore`. No confirmation.

## .crushignore

- Located at CWD repo root
- **Required gate** — `/crush` refuses to run without it
- Created by `/crush-setup`
- Header line sets default mode: `# default: lowfat` or `# default: fullcream`
- Body uses gitignore-style patterns for files that should survive the crush
- Lines starting with `#` are comments

## Safety Rules (hardcoded, never overridden)

- Never delete git-tracked files (report them with `tracked: true` for the user to handle via `git rm`)
- Never touch files modified in last 10 minutes
- Never touch `node_modules/`, `.git/`, `.env*`, `package-lock.json`, `yarn.lock`
- Process kills: PPID=1 (orphaned) as primary signal, age >60m as secondary
- Kill signal: SIGTERM first, SIGKILL after 5s for stubborn processes

## Scanner Script

`scripts/crush.sh` is the core engine. It outputs JSON and accepts action commands:
- `crush.sh scan` — returns JSON of zombies + slop in CWD
- `crush.sh kill <pid1> <pid2> ...` — kill specific processes
- `crush.sh delete <file1> <file2> ...` — delete specific files
- `crush.sh scan --global` — scan across ~/projects/ and ~/.claude/
- `crush.sh setup-launchagent` — install standalone hourly LaunchAgent
- `crush.sh cron` — silent auto-kill mode (used by LaunchAgent/que-do)

## Que-Do Integration

If `~/.slate-queue/` exists, `/crush-setup` offers que-do as the preferred scheduling method.

`scripts/setup-quedo.sh` creates:
- Runner script at `~/.slate-queue/scripts/clawcrush.sh` (custom script type, no Claude needed)
- Wrapper at `~/.slate-queue/jobs/slate-clawcrush`
- LaunchAgent at `~/Library/LaunchAgents/com.slate.clawcrush.plist`
- Manifest entry: `clawcrush|flexible|Hourly zombie process cleanup`

The runner sources `~/.slate-queue/lib/boilerplate.sh` for locking, logging, and log rotation. Marked as `flexible` so the scheduler can defer it when system is busy.

Remove with: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-quedo.sh --remove`

## Presentation

- Use rich markdown tables for displaying scan results
- Use AskUserQuestion for lowfat mode selections
- Fullcream mode narrates with short status lines as it crushes
- Always show a final summary: count of zombies killed, files deleted, space reclaimed
