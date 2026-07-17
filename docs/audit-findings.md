# clawcrush — verified audit findings (2026-07-13)

Companion to `docs/handoff.md` (+ its ADDENDUM). Everything here was **verified by execution**
against `scripts/crush.sh` in this worktree, not inferred. Where this contradicts the handoff's
priority ranking, **this file wins** — the handoff is directional; these are measurements.

---

## F1 — The zombie predicate has ZERO precision (CONFIRMED, root cause)

`scan_zombies` (`scripts/crush.sh:181-187`):

```bash
if [[ "$ppid" == "1" ]]; then                  is_orphan="true"; reason="ppid=1 (orphaned)"
elif (( age_mins >= MIN_AGE_MINUTES )); then   is_orphan="true"; reason="age > ${MIN_AGE_MINUTES}m"
```

It is an `elif` — so **age alone is sufficient**. Running `bash scripts/crush.sh scan` flagged
**14 processes, all with `reason:"age > 60m"`, ZERO with `ppid=1`** — every one an MCP server
(`playwright-mcp`, `qmd mcp`, `mcp-remote`, `gong-lite`) whose parent was a **live, healthy Claude
session**. A later scan returned **0** flagged, purely because the sessions had aged out.

**The detector's output is a pure function of session age.** At 59m a process is clean; at 61m the
identical, actively-used process is a "zombie." Nothing about it changed. Precision is 0%.

Note the asymmetry: the **second** loop (node/bun/chromium, ~199-229) correctly requires
`ppid==1` **AND** age. A correct model already exists in the same function. The MCP loop is one
word away from it.

## F2 — The destructive cron is ARMED, and only a BUG is suppressing it

- `com.slate.clawcrush` is **loaded in launchd** (`StartInterval 3600`).
- `~/.slate-queue/scripts/clawcrush.sh` invokes `crush.sh cron`.
- `do_cron` (628-643) kills **every** pid from `scan_zombies` — no confirmation, no liveness
  re-check, no dry-run, errors swallowed by `|| true`.

Combined with F1 that is an **hourly SIGTERM of every live Claude session's MCP servers**.

All 20 logged runs in `~/.slate-queue/logs/clawcrush/` skipped — but the logs show:

```
boilerplate.sh: line 39: : No such file or directory
flock: data error: Bad file descriptor
[2026-07-13 00:41:02] clawcrush already running, skipping
```

The `flock` **errors out and fails closed**; "already running" is a misreport. This is a **bug, not
a safeguard**. Repairing que-do's boilerplate — exactly what a routine cleanup does — unmasks the
mass-kill instantly.

> **STATUS 2026-07-13: NEUTRALISED.** `com.slate.clawcrush` was **unloaded** from launchd
> (`launchctl bootout gui/$(id -u)/com.slate.clawcrush`, confirmed gone from `launchctl list`).
> The plist remains at `~/Library/LaunchAgents/com.slate.clawcrush.plist`, so re-arming is one
> `launchctl bootstrap`.
>
> **This is a stopgap, not the fix, and it changes U0's job:** U0 must still make `do_cron`
> safe (dry-run-to-log until the F3 predicate lands), and **re-arming the LaunchAgent is a
> POST-CONDITION of U0/U1** — it must not be bootstrapped back until the attribution model is in
> and proven by a runtime test. Do not treat "the cron is unloaded" as closing F2.

## F3 — The predicate needs TWO axes (liveness AND ownership)

From the handoff ADDENDUM, and verified live. Both mechanisms work:

- **Liveness** — walk the ancestor chain. Terminates at a live `claude` → **attached, not
  abandoned**. (`ps -o ppid=,comm= -p <pid>`)
- **Ownership** — which worktree/session owns it. (`lsof -a -p <pid> -d cwd -Fn` → cwd →
  `git rev-parse --show-toplevel`)

**Kill matrix:**

|                    | orphan (no live parent) | attached (live parent) |
|--------------------|-------------------------|------------------------|
| **my worktree**    | safe kill               | consent only           |
| **another worktree** | safe kill, but report | **NEVER KILL**         |

**Ownership is a hard PREREQUISITE of the Angular/karma work, not a guardrail bolted on after.**
The handoff wants karma/`ng serve` killed *even when `ppid != 1`*. But a sibling's **active**
`ng test` and my own **defunct** one are both "old with a live-ish parent" — without cwd→worktree
attribution they are literally indistinguishable, so that rule is unimplementable safely at any
priority.

**Verified live:** MCP pids 58544 / 58721 / 58818 / 59292 — live `claude` parent (ppid 57656),
cwd `/Users/shawnroos/projects/Slate/worktrees/editor-browser-gpu-config` — a **sibling** session,
not this one. At 42m they scan clean; crossing 60m makes crush flag them and the armed cron would
SIGTERM another live session's MCP servers.

## F4 — `do_delete` has NO path containment (worst bug in the file)

`do_delete` (539-578) takes arbitrary paths and `rm -rf`s them. Proven in a sandbox: an **absolute
path outside the repo, never scanned**, was deleted. Guards are only `is_safe` (7 substrings) and
`is_recent`. Nothing ties the delete target to the repo that was scanned. One hallucinated or
mis-relayed path = arbitrary recursive delete. **Worse than the kill path — processes respawn,
files don't.**

## F5 — `scan_global` dash-decode is lossy → 138/145 project dirs look "orphaned"

Line 439: `sed 's/^-/\//; s/-/\//g'` turns **every** literal dash into a slash. This worktree
decodes to `.../worktrees/resource/reclaim/redesign` — nonexistent. **138 of 145** dirs in
`~/.claude/projects` therefore report as `orphaned_refs` — i.e. live session history offered up for
deletion. The encoding is not invertible; needs a different strategy (read `cwd` from the session
JSONL, or match against real candidate dirs).

## F6 — bash 3.2 empty-array abort fails OPEN on the dangerous case

Shebang is `#!/bin/bash` = **macOS bash 3.2**; launchd's minimal PATH resolves there too. Under
`set -u`, expanding an empty array `"${json_items[@]}"` is an *unbound variable* error:

```
/bin/bash scripts/crush.sh scan  →  rc=1, stderr "json_items[@]: unbound variable", stdout EMPTY
```

(Interactively it *looks* fine only because homebrew bash 5.3 is on PATH.)

**Do not mistake this for a safety net.** It fires only when a list is **empty** — i.e. nothing to
kill, harmless. When the list is **non-empty**, the script runs fine and the mass-kill proceeds. It
**fails closed on the harmless case and open on the dangerous one.** Sites: 234, 417, 490, 499.
(`read_crushignore`, line 113, is dead code — never called.)

## F7 — Lesser defects (real, lower blast radius)

- **`is_recent` on a directory** only stats the dir's own mtime, not its contents. Every entry in
  `SLOP_DIRS` is a directory, so the guard is weakest exactly where deletion is recursive. Proven:
  a `playwright-report/` with a file written seconds ago is judged "not recent" and `rm -rf`'d.
- **TOCTOU scan→act.** Lowfat scans, renders a table, waits on a human via `AskUserQuestion`, *then*
  acts. `do_kill` never re-validates the pid still matches; `do_delete` never re-validates the path
  is still slop. macOS recycles PIDs. Minutes-wide window.
- **`do_kill` has zero input validation** (514). A negative arg becomes a process-**group** kill.
- **`is_safe` is substring matching** (86-94) — a 7-string denylist wearing a safety model's
  clothes. Protects nothing else: not `~/.ssh`, not `~/.aws`, not git metadata.
- **`grep -F "$pattern"` matches the whole `ps` line including args** (195) — any process whose
  command line merely *contains* e.g. `playwright-mcp` (a `tail -f`, an editor) gets flagged.
- **JSON escaping is quote-only** (352, 409, 450) — no backslash escaping; `git ls-files` quotes
  non-ASCII paths → malformed JSON / wrong delete targets. Needs `git ls-files -z`.

**Tested and REFUTED** (do not chase): the `find -o` precedence at line 471 is *not* a bug on macOS
(BSD `find` treats `-maxdepth` as global); `is_recent` does *not* fail open on a broken symlink
(BSD `stat` doesn't follow links).

## F8 — Load-contention diagnosis is real (handoff ADDENDUM), and is READ-ONLY

Signal: load average **≫ core count**, driven by N concurrent `ng test`/`tsc` in **sibling**
worktrees (+ karma port clashes) — not swap, not `vm_stat`. Measured on this machine during the
audit: **load 97.79 on 10 cores** (`hw.ncpu` = 10).

The field episode's correct action was to **reroute spec validation to CI, not to kill siblings**.
So this mode's output is a **report + recommendation with no destructive surface at all**. It is
the natural partner to the ownership guardrail (F3): it tells you the contention is *siblings'*,
and that the answer is CI rather than crushing them.

## Out of scope (ADDENDUM: still unevidenced)

`bg-spare` daemon reaping · D/U-state-specific handling · the `cp`/`mv` `-i`-alias gotcha.
Leave unbuilt.

---

## Required unit ordering (the handoff's P0 order is actively dangerous)

The handoff's top P0 — "add karma/ChromeHeadless/`ng serve`/vite/webpack patterns, detect them even
when `ppid != 1`" — implemented literally, puts those patterns in the **broken OR-loop** of F1. A
long-running `ng serve` is **by definition** >60m old. That converts "kills live MCP servers" into
"kills live MCP servers **and the dev server you are actively using**", targeting precisely the
process class most likely to be legitimately old-and-alive. There is no win to ship on top of a
detector whose precision is zero.

- **U0 — Disarm.** `do_cron` → dry-run-to-log; repo containment on `do_delete` (F2, F4).
- **U1 — Attribution model (keystone).** Both axes of F3. Handoff #5 (protect own PID), #6
  (never-kill allowlist) and the ADDENDUM's sibling guardrail are **the same predicate** — the
  handoff wrongly splits them across three items.
- **U2 — Angular stack + port detection.** karma / ChromeHeadless / `ng serve` / vite / webpack /
  esbuild, plus `lsof` port-squatter detection (4200-4299, 9222). **Gated on U1.** Per-item consent
  for anything outside the current worktree.
- **U3 — Load-contention diagnosis.** Read-only report (F8). No kills.

Also fold in F5/F6/F7 as hardening — F6 in particular must be fixed *before* U0's dry-run is
trusted, since the script silently produces empty output under `/bin/bash` 3.2.
