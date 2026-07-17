# ClawCrush

ClawCrush finds and destroys zombie processes and repo slop spawned by Claude Code sessions.

## Two Claws

1. **Process Claw** — reclaims orphaned MCP servers, stale node processes, abandoned browser
   instances, and the Angular dev/test stack (karma, ChromeHeadless, `ng serve`/`ng test`, vite,
   webpack, esbuild) plus port squatters on 4200-4299 / 9222. What it kills is decided by the
   attribution model below, never by age.
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

**Age is NEVER sufficient to call a process a zombie. Neither is `ppid == 1`.** Every candidate is
classified on two axes:

- **Liveness** — `ppid == 1` is **necessary but never sufficient** for abandonment. It is a
  *lifecycle* fact, not an abandonment fact: launchd services, tmux/screen/pm2/sshd, and
  self-daemonizing session servers (`agent-browser`) are `ppid == 1` for their **entire life** — that
  is their designed steady state, not the residue of a dead parent. So an orphan is only *abandoned*
  when it also carries a **positive abandonment signal**, of which there are exactly two:
  1. a **session-child signature** — a named MCP server or dev-stack process, which exists only as a
     child of a claude session, so `ppid == 1` proves that session is gone; or
  2. its **cwd resolved and has since been deleted** — the worktree is gone, so nothing wants it.

  Absent both, it fails closed to `protected`. Do **not** try to fix this by enumerating daemons to
  skip — that list is unbounded and it failed once per review round. Demand proof of abandonment.
- **Ownership** — which worktree owns it (`lsof` cwd → git toplevel), and which live `claude`
  session, if any, is its ancestor. **Ownership never testifies to abandonment.** A cwd says who
  owns a process, never whether it was abandoned; inferring the latter from the former is the defect
  that produced three consecutive P1s.

"orphan" below means `ppid == 1` **and** a positive abandonment signal:

|                      | orphan (abandoned)                  | attached (live parent)        |
|----------------------|-------------------------------------|-------------------------------|
| **my worktree**      | `safe_kill`                         | `consent_required`            |
| **another worktree** | `safe_kill` (reported with owner)   | `protected` — **NEVER KILL**  |
| **owner unknown**    | `safe_kill`                         | `consent_required` (fail closed) |

`ppid == 1` **without** a positive abandonment signal is `protected` in every column. The cost is a
false negative — an abandoned process whose name is in no pattern list and whose worktree still
exists survives until its cwd goes away. That is the intended trade: a missed zombie costs RAM, a
false positive SIGTERMs live work.

- `protected` is refused **unconditionally**. No flag — `--consent` included — unlocks it. There is
  no caller-reachable path to kill a protected pid.
- `consent_required` needs an explicit per-pid `--consent`. That flag may **only** be constructed
  from a per-item human selection in lowfat's `AskUserQuestion`. `fullcream` never passes it and so
  acts on `safe_kill` alone.
- Crush's own process tree and a never-kill allowlist (mid-flight `npm/pnpm/yarn install`,
  `tsserver`/LSP servers) always classify `protected`. These are not separate features — they are the
  same predicate short-circuiting.
- Unknowns fail closed: `lsof` failure, a cwd that's gone, a cwd that isn't a git repo → never
  auto-killed.
- Classification is re-derived at kill time, not trusted from the scan (macOS recycles pids, and
  lowfat waits on a human in between).
- Age survives only as display metadata and the cron gate.

Files:

- Never delete git-tracked files (report them with `tracked: true` for the user to handle via `git rm`)
- Never touch files modified in last 10 minutes (for directories, judged by newest *content* mtime)
- Never touch `node_modules/`, `.git/`, `.env*`, `package-lock.json`, `yarn.lock`
- **`delete` refuses any target that does not resolve strictly under its `--root`.** No root, no delete.

Kill signal: SIGTERM, then SIGKILL — after 2s for TERM-resistant browsers (karma/Chrome), 5s otherwise.

## Scanner Script

`scripts/crush.sh` is the core engine. It outputs JSON and accepts action commands:
- `crush.sh scan` — JSON of zombies + port squatters + slop in CWD. Every process carries
  `orphan`, `owner_worktree`, `owning_session`, and `classification`.
- `crush.sh scan --global` — scan across `~/.claude/`; each deletable item emits its own authorized `root`
- `crush.sh contention` — READ-ONLY load-vs-cores report, grouped by owning worktree. Never acts.
- `crush.sh classify <pid>` — the classification for one pid (read-only)
- `crush.sh kill [--consent <pid>]... <pid>...` — kill, enforcing the matrix above
- `crush.sh delete --root <path> <file>...` — delete, contained strictly under `<root>`
- `crush.sh setup-launchagent` — install standalone hourly LaunchAgent (report-only cron)
- `crush.sh cron` — **REPORT-ONLY dry run.** Logs `Cron dry-run: would-kill pid …` for genuine
  `safe_kill` orphans past the age gate and kills nothing. Re-arming it as a killer is deliberately
  unbuilt; do it only once the dry-run logs have soaked.

## Tests

`tests/run.sh` — runtime harness. Always invokes the engine via `/bin/bash` (macOS bash 3.2, the
interpreter launchd resolves regardless of PATH; homebrew bash 5.x hides the empty-array abort).
Candidates are minted as real executables named after shipped patterns, so tests exercise the real
matching path rather than a synthetic bypass.

Seams: `CRUSH_MIN_AGE_MINUTES` (age gate), `CRUSH_SESSION_RE` (what counts as a live session),
`CRUSH_EXTRA_PATTERNS` (harness-only patterns), `$HOME` (fixture for `scan --global` and the log).

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
