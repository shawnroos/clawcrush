# ClawCrush

Find and destroy zombie processes and repo slop spawned by Claude Code sessions.

## What it does

ClawCrush has two claws:

1. **Process Claw** — kills orphaned MCP servers, stale node processes, abandoned browser instances
2. **Slop Claw** — destroys untracked garbage files in repos (debug logs, numbered dupes, temp files, test artifacts)

## Install

```bash
claude install-plugin shawnroos/clawcrush
```

## Commands

| Command | Description |
|---------|-------------|
| `/crush` | Dispatcher — routes to your default mode (lowfat or fullcream) |
| `/crush-setup` | Global system scan, creates `.crushignore`, configures scheduling |
| `/crush-lowfat` | Supervised mode — presents tables, you pick what to crush |
| `/crush-fullcream` | Autonomous mode — crushes everything not in `.crushignore` |

## .crushignore

A gitignore-style file at repo root that controls what survives the crush. Created by `/crush-setup`.

```
# default: lowfat
docs/plans/**
.beads/
```

- First comment line sets default mode: `lowfat` or `fullcream`
- Body patterns protect files from deletion (gitignore syntax)
- Required gate — `/crush` won't run without it

## Safety rules

These are hardcoded and never overridden:

- Never delete git-tracked files (reports them for manual `git rm`)
- Never touch files modified in last 10 minutes
- Never touch `node_modules/`, `.git/`, `.env*`, lock files
- Process kills: PPID=1 (orphaned) as primary signal, age >60m as secondary
- Kill signal: SIGTERM first, SIGKILL after 5s for stubborn processes

## Scheduling

`/crush-setup` can install automatic hourly zombie crushing via:

- **que-do** (recommended if available) — gets retry logic, stall detection, manifest tracking
- **macOS LaunchAgent** — standalone fallback

## License

MIT
