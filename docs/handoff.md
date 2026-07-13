# Spinoff: clawcrush resource-reclamation redesign

> This handoff is directional — author intent + researched evidence, not a spec.
> The code (`~/projects/clawcrush`, esp. `scripts/crush.sh`) is the source of truth; validate against it.

## Goal
Improve **clawcrush** (the "find & destroy zombie processes + repo slop" plugin) using
lessons learned repeatedly freeing resources on this machine. Two research streams fed this:
a **transcript mining** pass (143 project dirs) and a **memory** pass. They partly disagree —
that disagreement is important and reconciled below. Do NOT treat every idea as settled; the
priorities are ranked by evidence strength.

## Repo & where things are
- **Dev repo:** `~/projects/clawcrush` (public `shawnroos/clawcrush`). Branch a worktree from here.
- **Engine:** `scripts/crush.sh`. **Modes:** `commands/crush-{fullcream,lowfat,setup}.md` + `crush.md` dispatcher.
- **Also vendored** in shrimpshack (`plugins/clawcrush`) — publish flow mirrors the other shrimpshack plugins (see memory `project_shrimpshack_marketplace_publish_workflow`): edit dev repo → PR → re-vendor to shrimpshack to release.
- **What crush.sh already does today** (don't rebuild): kills MCP-pattern procs + orphaned `node`/`bun`/`chromium`/`chrome` with `ppid=1` AND age>60m (SIGTERM→wait 5s→SIGKILL); `scan_global` reclaims orphaned `~/.claude/projects/<dash-encoded>` refs whose real path is gone, `*.backup/*.bak` config backups, reports plugin-cache size; hourly LaunchAgent `cron` mode auto-kills silently; slop scan removes git-untracked `*.log/*.bak/*.orig`, `temp-/scratch-/debug-/untitled` prefixes, root media, numbered dupes, `test-results/playwright-report/.playwright-mcp`, guarded by `is_recent` (10min) + `SAFE_PATTERNS` + `.crushignore`.

---

## THE reconciliation (read this first — the two streams disagree)
- **Transcript mining** (historical, 143 dirs) found the dominant real toil is the **Angular test/serve cycle** — `karma` + `ChromeHeadless` + `ng serve` — killed by hand ~100+ times across dozens of Slate worktrees. It found **no** transcript evidence for swap-thrash diagnosis, bg-spare reaping, the auto-mode classifier consent-block, or D-state handling, and recommended NOT building those.
- **BUT** those "no evidence" items are **firsthand-real from the current session** (2026-07-13) and from memory — they're just not in the *historical transcript corpus* the agent searched (this session isn't indexed yet; the lessons live in memory). This session literally: diagnosed swap thrash (load 229, ~7GB swap reclaimed), killed 5 bg-spare daemons, and got **blocked by the auto-mode classifier** trying to mass-kill sessions.
- **Resolution:** the karma/serve finding is the highest-frequency, best-evidenced win (build it first). The swap/classifier/bg-spare items are real but lower-frequency — build them as **secondary/opt-in**, informed by memory, not dismissed. Don't let "not in old transcripts" override firsthand evidence; don't let firsthand recency inflate a rare case over the daily karma toil.

---

## Prioritized improvement roadmap

### P0 — the karma/ChromeHeadless/ng-serve blind spot (best-evidenced, ~100+ manual kills)
1. **Add the Angular test/dev stack to kill patterns:** `karma`, `ChromeHeadless`/`Google Chrome for Testing`, `ng serve`, `webpack`, `vite`, `esbuild`, `ng test`. Detect them **even when `ppid != 1`** — they're often children of a dead `ng`/node parent not yet reparented. (Today crush.sh only reaps `ppid=1` orphans, so it never sees these.)
2. **Port-based orphan detection:** enumerate `lsof -nP -iTCP -sTCP:LISTEN` for dev-server ports (4200–4299, 9222 CDP) and flag/kill listeners with no live parent. Pattern+PPID matching misses **port-squatters** that block the next `ng serve`. Manual fix was always `lsof -ti:PORT | kill -9`.
3. **SIGKILL escalation, tuned:** karma/Chrome **always** needed `pkill -9` (SIGTERM left survivors). Keep the 5s SIGTERM grace generally, but for known-trap browsers drop grace to ~2s. (Corroborated by memory: U-state procs ignore TERM.)
4. **Byproduct slop:** `/tmp/ngserve-*.log` / `/tmp/ng-serve-*.log` accumulate outside any repo — crush's slop scan only looks in-CWD. Add a `/tmp` dev-log sweep.

### P0 — critical SAFETY GAP the agent found in current code
5. **Protect the live session's own PID + parent `claude` tree.** crush.sh's `node`/`chrome` pattern match has **no exclusion for the running agent's own process tree** — it could kill its own host. Exclude `$PPID` and the current Claude process tree before any kill. (Memory: `cannot_self_remove_running_worktree`, and protect-live-PID was central to this session's kills.)
6. **Never-kill process allowlist:** `pnpm`/`npm`/`yarn install` (mid-flight → corrupts node_modules/lockfile), `tsserver`, LSP servers. Today only *files* have `SAFE_PATTERNS`; processes have no allowlist.

### P1 — disk reclaim (memory-rich; agent confirms crush is blind to the biggest sinks)
Both streams agree crush touches none of the real disk hogs (it skips `node_modules`, `.angular` is gitignored so never shows as "untracked slop", `/tmp` is out of CWD). From `reference_disk_reclaim_angular_worktree_caches` (freed 65–217GB per run):
7. **Opt-in build-cache sweep:** `.angular/cache` + `dist` + `.nx/cache` per worktree (100% regenerable, safe even under live `ng serve`), `cdk.out` (seen at 40GB), `~/.cache/huggingface` (16GB). Gate on `[ -f "$wt/package.json" ]`. Report sizes via `du -sh`.
8. **pnpm store, not node_modules:** node_modules reclaim is **phantom** for pnpm (hardlinks into `~/Library/pnpm/store`; `du` counts shared bytes). Real lever: `pnpm store prune`. Always verify reclaim by `df` free-space delta, not `du` sum.
9. **Docker=Colima two-step:** `docker system prune -af --volumes` frees VM-internal only; host reclaim needs `colima ssh -- sudo fstrim -av` (seen 65G→782M). Detect via `docker context ls`.
10. **Diagnose top-down:** `df -h /System/Volumes/Data` first; **avoid recursive `du` when nearly full** (OOM-killed, exit 137). The dominant hog VARIES every cleanup — never anchor on last time.
11. **Backstop-aware:** an armed `auto` run's destructive backstop pauses on any `rm -rf`. Prefer native cache cmds (`pnpm store prune`, `npm cache clean`) which don't trip it. Remove worktrees with `git worktree remove`, never `rm -rf` (orphans git metadata). Never trust `git merge-base --is-ancestor` for "safe to delete a worktree".

### P1 — worktree pruning (both streams: only manual, rare)
12. Extend `scan_global`: `git worktree list --porcelain` per known repo; flag worktrees whose branch is merged/gone or whose dir is missing (`git worktree prune` + `remove --force`). Also reap **orphaned `.claude/worktrees/agent-*`** (8+ days, not in `worktree list`, no live process — auto/CE don't auto-reap them; seen 23GB from 7 dirs). Condition on LIVENESS, not blanket protect.

### P2 — memory/swap mode (firsthand this session; NOT in historical transcripts — build opt-in)
13. **Swap/pressure diagnosis + reclaim mode:** `top -l 1` PhysMem (unused/compressor), `sysctl vm.swapusage`, `vm.loadavg`, count U/D-state procs. Signal: **high load + low CPU + U-state = swap thrash, not CPU runaway.** Rank reclaimable procs by RSS; report swap freed (this session: ~7GB). Note the post-mass-kill **load spike is transient reclaim churn** (1min>5min>15min = settling) — don't misread.
14. **bg-spare daemons** (`claude bg-spare …`) respawn on demand → safe to kill under pressure. Root cause of recurring thrash here: many concurrent idle Claude sessions (23 seen) + bg-spare + orphaned dev servers + Chrome/Dia.

### P2 — consent & attribution (firsthand this session; agent found no transcript trace — real but subtle)
15. **Classifier-safe consent flow:** the auto-mode classifier **blocks mass-killing processes the agent only inferred were its own / didn't create** — matches the user's LITERAL words, not context. Present grouped candidates via **`AskUserQuestion` per-item selection** (that clears the block); or hand a `!`-prefixed command. Don't retry variants. (`classifier_authorizes_literal_user_words`.)
16. **Attribute before cleanup:** "orphan" is a claim, not a vibe. Inspect labels/cwds/running-cmd; only act on a clear self-created signature; never key off COUNT (`attribute_shared_infra_before_cleanup` — nearly closed 11 of Shawn's real workspaces).
17. **Non-interactive file ops:** `cp`/`mv` are `-i`-aliased in Shawn's zsh → silently skip overwrite. Use `command cp -f` / Edit / `git checkout --`.

### P3 — hooks as a throughput drain (memory only; adjacent to clawcrush's "session slop" remit)
18. Surface slow/blocking hooks: prompt-type `PostToolUse` hooks cost a whole turn per edit (`nerd`), `exit 2` Stop hooks block turn-end (`slate-roadmap` watchdog). This session's doctor found `UserPromptSubmit` avg 4s/94 timeouts. Could be a clawcrush "report" (not auto-fix).

### Explicitly LOW-confidence / maybe-skip
- The agent said don't build swap/classifier/bg-spare *at all* (no transcript evidence). I've kept them as **P2 opt-in** because this session is direct counter-evidence — but they are genuinely lower-frequency than the karma toil. Let Shawn weigh in on whether the memory/consent modes are worth the complexity vs. just nailing P0/P1.

## Suggested first move
Start with **P0** (karma/ChromeHeadless/ng-serve patterns + port detection + live-PID protection) — highest evidence, biggest daily win, and #5/#6 are safety fixes to existing code. Then P1 disk. Treat P2/P3 as opt-in modes behind flags.

## Key references
- Engine: `~/projects/clawcrush/scripts/crush.sh`; modes in `commands/`.
- Memories: `reference_disk_reclaim_angular_worktree_caches`, `feedback_stop_background_agents_taskstop_then_sigterm`, `feedback_classifier_authorizes_literal_user_words`, `feedback_attribute_shared_infra_before_cleanup`, `feedback_worker_rmrf_trips_auto_backstop`, `reference_cp_is_interactive_in_shell`, `feedback_minions_kill_orphaned_microsandbox`, `project_shrimpshack_marketplace_publish_workflow`.
- Richest transcript episode dirs: `~/.claude/projects/-Users-shawnroos-projects-Slate-web-app-worktrees-{feature-ai-service-hub,sam-audio-tool,carousel-20-panels,relight-logo-combined,lower-thirds,logo-removal-eval}/`.

---

## ADDENDUM (post-research correction — strengthens P0 safety + P2)
A late transcript grep surfaced an episode the first pass missed — `Slate/web-app/worktrees/ai-takeover-teardown`, 2026-07-13 — that REVERSES two "no evidence" claims and adds the single most important guardrail:

- **Load-average contention diagnosis IS evidenced** (via `uptime` load-avg + `ps` count of concurrent `ng test`/`tsc`, NOT `vm_stat`/swap). Symptom: `ng test`/typecheck timing out at 3min, 0/0 coverage, Chrome disconnect. Diagnosis found load spiking **26→105→21** with `PhysMem 15G used` and **~6 concurrent `tsc`/`ng test` in sibling worktrees** + a karma port clash. Correct attribution: **the contention, not the diff, is why tests time out** → rerouted spec validation to CI (`run-all-tests` label) instead of fighting for local CPU. So the P2 "memory/swap mode" is better framed as a **load-contention diagnosis** (load ≫ cores from N sibling test runs), and it's real, not aspirational.

- **Self-scoped kills / protect-siblings IS evidenced and was applied by hand** — this is the #1 safety guardrail, promote it into **P0**: *"I won't touch other worktrees' processes, but I'll kill my own defunct spec run"* → `kill <own-pids>` scoped to THIS worktree only, siblings left alone. **clawcrush must distinguish "orphan with no live parent" (safe) from "active `ng test`/`ng serve` owned by ANOTHER worktree/session" (never kill).** Tie every candidate to its worktree via cwd/`lsof`/PPID; in supervised mode require per-item consent for anything outside the current worktree. This is the concrete, evidenced form of the "attribute before cleanup / classifier-safe consent" items (#15/#16) — they are NOT just this-session firsthand; they happened in the field too.

**Still genuinely unevidenced (leave as low-confidence):** `bg-spare` daemon reaping, D/U-state-specific handling, the mv/cp alias gotcha — those remain firsthand-this-session only.
