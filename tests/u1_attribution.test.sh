#!/bin/bash
# U1 — the two-axis attribution model (the keystone).
#
# Guards F1 (age alone was sufficient to call a live process a zombie — 0% precision) and F3
# (a sibling worktree's ACTIVE process and my own DEFUNCT one are indistinguishable without
# cwd->worktree attribution).
#
# Every candidate here is minted as a real executable named after a shipped MCP_PATTERNS entry,
# so the tests exercise the real matching path, not a synthetic bypass.

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

setup_tmp

wt_a=$(mk_repo "$TMPROOT/wtA")   # "my" worktree — the scan root
wt_b=$(mk_repo "$TMPROOT/wtB")   # a sibling worktree — another live session's territory

mcp=$(mk_exec "$TMPROOT/bin" "playwright-mcp")

# ── The session regex, pinned against REAL captured command lines ─────────────────────────
# The ONE fuzzy judgment in the model. It was previously exercised only through a fixture whose
# session parent was an executable literally named `claude` — a shape that satisfies any plausible
# regex. So the suite was green while the regex could not see the process that actually spawns MCP
# servers, and every attached-process assertion below it was passing for a reason that could not
# fail.
#
# These strings are verbatim `ps -o command=` output captured from live sessions on this machine.
# The first is the one the old regex missed: `claude` followed by `/`, not by whitespace or EOL.
# On a swarm/subagent session it is the ONLY claude process in the ancestor chain (its parent is
# tmux), so missing it killed the session axis outright — 46 of 76 live MCP servers reported
# owning_session:null.

session_re() { crush session-re "$1" 2>/dev/null; }

expect_eq "session-re: the agent version-binary path (the shape the old regex MISSED)" "true" \
  "$(session_re '/Users/shawnroos/.local/share/claude/versions/2.1.207 --resume /x/y.jsonl --agent claude')"
expect_eq "session-re: the version binary of a swarm subagent session" "true" \
  "$(session_re '/Users/shawnroos/.local/share/claude/versions/2.1.207 --agent-id reviewer-r3@session-01df9627')"
expect_eq "session-re: the pty-host wrapper" "true" \
  "$(session_re '/Users/shawnroos/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude --bg-pty-host /tmp/x.sock')"
expect_eq "session-re: the daemon on PATH" "true" \
  "$(session_re '/Users/shawnroos/.local/bin/claude daemon run --json-path /x/daemon.json')"
expect_eq "session-re: the bare argv[0] form" "true" \
  "$(session_re 'claude bg-pty-host --bg-pty-host /tmp/x.sock')"

# Negative controls. Without these the regex could be `.` and every assertion above still passes.
expect_eq "session-re: an MCP server is NOT a session" "false" \
  "$(session_re 'node /Users/shawnroos/.npm/_npx/9833/node_modules/.bin/playwright-mcp')"
expect_eq "session-re: ~/.claude/<...> is a config path, NOT a session process" "false" \
  "$(session_re '/Users/shawnroos/.claude/plugins/cache/some/bin/server --port 1')"
expect_eq "session-re: a plain shell is NOT a session" "false" \
  "$(session_re '/bin/bash /Users/shawnroos/bin/supervisor.sh')"

# ── Liveness: the SAME pid reclassifies when its parent dies ──────────────────────────────
# The parent here is a FOREIGN live claude session (not in crush's own ancestor chain), so the
# child is protected regardless of worktree — see the session-granularity block below.

read -r att_pid att_session <<< "$(spawn_attached "$wt_a" "$mcp")"

if [[ -z "$att_pid" ]]; then
  nok "liveness: could not mint an attached candidate (harness failure)"
else
  out=$(crush_in "$wt_a" classify "$att_pid" 2>/dev/null)
  expect_eq "liveness: it is NOT an orphan" "false" "$(json_get "$out" 'd["orphan"]')"
  expect_eq "liveness: its owning session is the live fake claude" \
    "$att_session" "$(json_get "$out" 'd["owning_session"]')"

  # Kill the session. The child reparents to launchd and becomes a genuine orphan.
  kill -9 "$att_session" 2>/dev/null
  if wait_ppid1 "$att_pid"; then
    out=$(crush_in "$wt_a" classify "$att_pid" 2>/dev/null)
    expect_eq "liveness: the SAME pid is safe_kill once its parent dies" \
      "safe_kill" "$(json_get "$out" 'd["classification"]')"
    expect_eq "liveness: and is now an orphan" "true" "$(json_get "$out" 'd["orphan"]')"
  else
    nok "liveness: candidate never reparented to ppid=1 (harness failure)"
  fi
fi

# ── The version-binary session shape is SEEN (the ADV-1 cardinal bug, end to end) ─────────
# Same assertion as above, but the session parent is NOT named `claude` — it carries the real
# version-binary path shape. Under the old regex this process had owning_session:null and the
# session axis contributed nothing to its classification.

read -r ver_pid ver_session <<< "$(spawn_attached_versioned "$wt_a" "$mcp")"

if [[ -z "$ver_pid" ]]; then
  nok "version-shape: could not mint the versioned-session candidate (harness failure)"
else
  out=$(crush_in "$wt_a" classify "$ver_pid" 2>/dev/null)
  expect_eq "version-shape: a session named by version-binary PATH (not 'claude') is resolved" \
    "$ver_session" "$(json_get "$out" 'd["owning_session"]')"
  expect_eq "version-shape: and its child is protected as another session's process" \
    "protected" "$(json_get "$out" 'd["classification"]')"
fi

# ── Session granularity beats worktree granularity ────────────────────────────────────────
# N Claude sessions routinely share one repo root, so "attached, and its worktree IS my scan root"
# does not make a process mine. A live owning session that is not in MY ancestor chain outranks the
# worktree axis. Previously `session` was computed and then used ONLY to decorate `reason` — the
# axis was in the output and not in the decision.

read -r foreign_pid foreign_session <<< "$(spawn_attached "$wt_a" "$mcp")"

if [[ -z "$foreign_pid" ]]; then
  nok "session-granularity: could not mint the foreign-session candidate (harness failure)"
else
  out=$(crush_in "$wt_a" classify "$foreign_pid" 2>/dev/null)
  expect_eq "session-granularity: another session's live process IN MY OWN WORKTREE is protected" \
    "protected" "$(json_get "$out" 'd["classification"]')"
  expect_contains "session-granularity: and it says so — protected BY SESSION, not by worktree" \
    "$(json_get "$out" 'd["reason"]')" "ANOTHER live claude session"

  # protected is refused unconditionally — the worktree matching mine must not open a consent path.
  crush_in "$wt_a" kill --consent "$foreign_pid" >/dev/null 2>&1
  sleep 1
  expect_alive "session-granularity: --consent CANNOT unlock another session's live process" "$foreign_pid"
fi

# ── ...but MY OWN worktree's attached, session-less process is still consent_required ──────
# The matrix cell must survive the tightening above: an attached process with NO owning claude
# session (a supervisor child, a shell job) in my worktree is mine to reclaim with consent.

read -r plain_pid plain_parent <<< "$(spawn_attached_plain "$wt_a" "$mcp")"

if [[ -z "$plain_pid" ]]; then
  nok "own-attached: could not mint the plain-parent candidate (harness failure)"
else
  out=$(crush_in "$wt_a" classify "$plain_pid" 2>/dev/null)
  expect_eq "own-attached: a live-parent, session-less candidate in my worktree is consent_required" \
    "consent_required" "$(json_get "$out" 'd["classification"]')"
  expect_eq "own-attached: it has no owning session" "null" "$(json_get "$out" 'd["owning_session"]')"
fi

# ── THE DAEMON GUARD: ppid==1 is necessary, never sufficient ──────────────────────────────
# launchd-managed jobs (brew services, user LaunchAgents) and self-daemonized processes run with
# ppid==1 for their ENTIRE LIFE — launchd is their designed parent, not the residue of a dead one.
# Verified on this machine before the guard existed: powerd, usbaudiod, containermanagerd and the
# user's Dock-launched Google Chrome (all ppid==1) every one classified safe_kill.
#
# The discriminator is the cwd: a daemon's is `/` or its install dir, never a git worktree; an
# abandoned session child's IS the worktree it was spawned in. Both directions are asserted — a
# guard that merely refuses everything is satisfied by deleting the feature.

node_exec=$(mk_exec "$TMPROOT/bin" "node")

daemon_pid=$(spawn_orphan "/" "$node_exec" --daemon-ish)
if [[ -z "$daemon_pid" ]]; then
  nok "daemon-guard: could not mint the daemon-shaped candidate (harness failure)"
else
  out=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" classify "$daemon_pid" 2>/dev/null)
  cls=$(json_get "$out" 'd["classification"]')
  if [[ "$cls" == "safe_kill" ]]; then
    nok "daemon-guard: THE REGRESSION — a ppid=1 node daemon with cwd=/ is safe_kill (fullcream would kill a brew service)"
  else
    ok "daemon-guard: a ppid=1 node daemon with cwd=/ is NOT safe_kill (got $cls)"
  fi
  expect_eq "daemon-guard: it is refused outright, so lowfat cannot offer it for consent either" \
    "protected" "$cls"

  # And the refusal holds at ACT time, not merely at scan time — `crush.sh kill <pid>` is reachable
  # by the command layer with an arbitrary pid.
  crush_in "$wt_a" kill --consent "$daemon_pid" >/dev/null 2>&1
  sleep 1
  expect_alive "daemon-guard: --consent cannot unlock a daemon-shaped process either" "$daemon_pid"
fi

# The positive control that keeps the guard honest: an orphan that DOES carry a positive
# abandonment signal is still reclaimed. It must be a session-child signature (a shipped
# MCP_PATTERNS name), not a generic runtime.
#
# This control used to spawn a bare `node`, and asserted safe_kill purely because its cwd resolved
# to a worktree. That encoded the very rule that produced round 3's P1 — `owner != "" -> safe_kill`,
# which reads ABANDONMENT out of OWNERSHIP. A generic `node` orphan in a live worktree is now
# `protected`, so the control has to prove the thing the contract actually claims: that a process
# which can only ever exist as a session's child is reclaimed once that session is gone.
abandoned_pid=$(spawn_orphan "$wt_a" "$mcp" --abandoned)
if [[ -z "$abandoned_pid" ]]; then
  nok "daemon-guard: could not mint the abandoned-child candidate (harness failure)"
else
  out=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" classify "$abandoned_pid" 2>/dev/null)
  expect_eq "daemon-guard: an orphaned MCP server (session-child signature) in a worktree is still safe_kill" \
    "safe_kill" "$(json_get "$out" 'd["classification"]')"
fi

# ── THE CLASS: ppid==1 + a live worktree cwd + NO abandonment signal -> protected ─────────
# Round 3's P1, and the reason the daemon ENUMERATION was abandoned for a positive abandonment
# signal. Verified live before this fix: a self-daemonized `agent-browser` (pid 82997 — LISTENING
# on localhost:54172, ESTABLISHED to its Chrome, live child, cwd in a sibling worktree) classified
#   {"classification":"safe_kill","owner_worktree":"/…/worktrees/relight-logo-combined"}
# and so did its Chrome (83002). agent-browser self-daemonizes for session persistence: ppid==1 is
# its designed steady state. It is not launchd-managed and carries no session-host name, so every
# positive DAEMON signal missed it — and it fell to `owner != "" -> safe_kill`.
#
# The fixture is deliberately a name that is in NO pattern list and NO daemon list — that is the
# whole point. Enumerating `agent-browser` would have made this green while leaving the class open
# for round 4's daemon. The assertion is about the ABSENCE of an abandonment signal, so it holds for
# any daemon nobody thought to name.

selfd_exec=$(mk_exec "$TMPROOT/bin" "agent-browser-darwin-arm64")
selfd_pid=$(spawn_orphan "$wt_a" "$selfd_exec" --serve --port 54172)

if [[ -z "$selfd_pid" ]]; then
  nok "abandonment-signal: could not mint the self-daemonized candidate (harness failure)"
else
  out=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" classify "$selfd_pid" 2>/dev/null)
  cls=$(json_get "$out" 'd["classification"]')
  if [[ "$cls" == "safe_kill" ]]; then
    nok "abandonment-signal: THE REGRESSION — a ppid=1 self-daemonized server whose cwd IS a worktree is safe_kill (this is the live agent-browser + its Chrome)"
  else
    ok "abandonment-signal: a ppid=1 daemon with a live cwd and no session-child signature is NOT safe_kill (got $cls)"
  fi
  expect_eq "abandonment-signal: it fails closed to protected, not consent_required" \
    "protected" "$cls"

  # protected must hold at ACT time too — and --consent must not unlock it.
  crush_in "$wt_a" kill --consent "$selfd_pid" >/dev/null 2>&1
  sleep 1
  expect_alive "abandonment-signal: --consent cannot unlock it either" "$selfd_pid"

  # Ownership is still REPORTED — the axis works, it just does not authorize a kill.
  expect_eq "abandonment-signal: its owning worktree is still reported" \
    "$wt_a" "$(json_get "$out" 'd["owner_worktree"]')"
fi

# ── SESSION HOSTS: ppid==1 AND cwd IS a worktree, and STILL never killable ────────────────
# The daemon guard above only ever exercised cwd=/, which is why the cardinal case survived it: the
# guard's discriminator was "a daemon's cwd is never a git worktree", and that is FALSE for the
# process class that HOSTS live Claude sessions.
#
# Verified live on this machine before this fix: the three claude-swarm tmux servers (pids 1395,
# 11558, 20552) are ppid==1 for their entire life — tmux daemonizes by design, launchd is its
# INTENDED parent — and their cwd resolves to a real git worktree. So `[[ -z "$owner" ]]` was false,
# the guard was skipped, and classify_pid returned:
#   {"classification":"safe_kill","owner_worktree":"/…/worktrees/relight-logo-combined"}
# `crush.sh kill 1395` would have SIGTERMed the tmux server and every live session inside it.
#
# cwd is not a sound liveness discriminator, so the fix is a POSITIVE name signal that never
# consults the cwd at all. Same class: screen, pm2, sshd, zellij.

tmux_exec=$(mk_exec "$TMPROOT/bin" "tmux")
tmux_pid=$(spawn_orphan "$wt_a" "$tmux_exec" -L test-socket new-session -d)

if [[ -z "$tmux_pid" ]]; then
  nok "session-host: could not mint the tmux-server candidate (harness failure)"
else
  out=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" classify "$tmux_pid" 2>/dev/null)
  cls=$(json_get "$out" 'd["classification"]')
  if [[ "$cls" == "safe_kill" ]]; then
    nok "session-host: THE REGRESSION — a ppid=1 tmux server whose cwd IS a worktree is safe_kill (killing it takes every live session inside it down)"
  else
    ok "session-host: a ppid=1 tmux server whose cwd IS a worktree is NOT safe_kill (got $cls)"
  fi
  expect_eq "session-host: it is refused outright, so lowfat cannot offer it for consent either" \
    "protected" "$cls"
  # Assert the REASON. This process is also ppid==1 in a worktree, so a green verdict alone would
  # not tell us WHICH rule produced it.
  expect_contains "session-host: and it is protected BECAUSE it is a session host" \
    "$(json_get "$out" 'd["reason"]')" "session host"

  # The denylist sits BEFORE the pattern lists, so making tmux visible to the scanner must not make
  # it killable. CRUSH_EXTRA_PATTERNS is the shipped seam for exactly that (verified pre-fix: with
  # tmux in the pattern list the scan reported it safe_kill).
  out=$(CRUSH_EXTRA_PATTERNS=tmux CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" classify "$tmux_pid" 2>/dev/null)
  expect_eq "session-host: putting tmux in the scan's pattern list makes it VISIBLE, never killable" \
    "protected" "$(json_get "$out" 'd["classification"]')"

  crush_in "$wt_a" kill --consent "$tmux_pid" >/dev/null 2>&1
  sleep 1
  expect_alive "session-host: --consent cannot unlock a session host either" "$tmux_pid"
fi

# ── LAUNCHD MEMBERSHIP: the positive signal, read instead of guessed ──────────────────────
# `launchctl list` names every job launchd actually MANAGES in this user's domain (brew services,
# user LaunchAgents, login items). A pid in that list has launchd as its live, managing parent —
# which is the exact property the old cwd rule was trying to infer. (`launchctl procinfo` is the
# more direct query but requires root, so it is unusable from the user-context LaunchAgent that
# matters here.)
#
# This runs against REAL launchd-managed pids, not a fixture — a fixture cannot have launchd as its
# manager, and a mocked membership list would only prove the mock. The assertion is on the REASON:
# if the launchd check is removed, no pid on the machine reports `launchd-managed` and this goes red
# (a daemon with cwd=/ would still be protected by the fallback guard — green for the wrong reason).

ld_found=""
ld_reason=""
while IFS= read -r ld_pid; do
  [[ "$ld_pid" =~ ^[0-9]+$ ]] || continue
  ps -o pid= -p "$ld_pid" >/dev/null 2>&1 || continue
  ld_out=$(crush_in "$wt_a" classify "$ld_pid" 2>/dev/null)
  ld_reason=$(json_get "$ld_out" 'd["reason"]')
  if [[ "$ld_reason" == *"launchd-managed"* ]]; then
    ld_found="$ld_pid"
    expect_eq "launchd: a launchd-managed job is protected" \
      "protected" "$(json_get "$ld_out" 'd["classification"]')"
    break
  fi
done < <(launchctl list 2>/dev/null | awk '$1 ~ /^[0-9]+$/ { print $1 }' | head -40)

if [[ -n "$ld_found" ]]; then
  ok "launchd: launchd membership is read from launchctl, not inferred from the cwd (pid $ld_found)"
else
  nok "launchd: NO pid on this machine classifies via launchd membership — the positive daemon signal is not wired"
fi

# ── The subject pid IS a live claude session / the daemon ─────────────────────────────────
# CRUSH_SESSION_RE was applied only to ANCESTORS (owning_session_of starts at the PARENT), so the
# model had no rule about a process that IS a session. `claude daemon run` (ppid==1, the parent of
# every live session) classified protected only INCIDENTALLY — because its cwd happens not to
# resolve to a git repo. Change that accident and the process at the TOP of the session tree comes
# back safe_kill.
#
# Each shape asserts the REASON, not just the verdict: several of these would also reach `protected`
# by some other rule on some other machine, and a test that cannot distinguish which rule fired
# cannot go red when the rule under test is deleted.

claude_exec=$(mk_exec "$TMPROOT/bin" "claude")
ver_exec=$(mk_exec "$TMPROOT/share/claude/versions" "2.1.207")

# (a) A live session in MY OWN worktree, attached. Pre-fix: owner == scan root -> consent_required,
#     i.e. lowfat would offer to kill somebody's live session running in the same repo.
read -r sess_pid sess_parent <<< "$(spawn_attached_plain "$wt_a" "$claude_exec" --resume /x/y.jsonl)"
if [[ -z "$sess_pid" ]]; then
  nok "self-session: could not mint the live-session candidate (harness failure)"
else
  out=$(crush_in "$wt_a" classify "$sess_pid" 2>/dev/null)
  expect_eq "self-session: a live claude session in MY OWN worktree is protected, not consent_required" \
    "protected" "$(json_get "$out" 'd["classification"]')"
  expect_contains "self-session: and it is protected BECAUSE it is itself a session" \
    "$(json_get "$out" 'd["reason"]')" "is itself a live claude session"
fi

# (b) The version-binary shape (`.../share/claude/versions/2.1.207`), ORPHANED in a worktree.
#     Pre-fix: owner resolves -> safe_kill.
verself_pid=$(spawn_orphan "$wt_a" "$ver_exec" --agent-id reviewer@session-01)
if [[ -z "$verself_pid" ]]; then
  nok "self-session: could not mint the version-binary candidate (harness failure)"
else
  out=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" classify "$verself_pid" 2>/dev/null)
  expect_eq "self-session: a version-binary session whose cwd IS a worktree is protected (was safe_kill)" \
    "protected" "$(json_get "$out" 'd["classification"]')"
  expect_contains "self-session: version-binary shape is recognised as a session" \
    "$(json_get "$out" 'd["reason"]')" "is itself a live claude session"
fi

# (c) `claude daemon run` with a resolvable worktree cwd — the parent of every live session.
daemon_run_pid=$(spawn_orphan "$wt_a" "$claude_exec" daemon run --json-path /x/daemon.json)
if [[ -z "$daemon_run_pid" ]]; then
  nok "self-session: could not mint the claude-daemon candidate (harness failure)"
else
  out=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" classify "$daemon_run_pid" 2>/dev/null)
  expect_eq "self-session: 'claude daemon run' in a worktree is protected (was safe_kill)" \
    "protected" "$(json_get "$out" 'd["classification"]')"

  crush_in "$wt_a" kill --consent "$daemon_run_pid" >/dev/null 2>&1
  sleep 1
  expect_alive "self-session: --consent cannot unlock the claude daemon" "$daemon_run_pid"
fi

# ── The DELETED-WORKTREE orphan IS reclaimable (the false-negative twin) ──────────────────
# The old guard's other half. A genuinely abandoned orphan whose cwd is unresolvable BECAUSE the
# worktree was deleted has owner="" — so if its command is a generic runtime rather than a named MCP
# pattern, the guard called it `protected`: permanently unkillable.
#
# That is the highest-value leak scenario on this machine, not an edge case: worktrees are automatic
# and removed after a PR merges (`wtc`), so "session ends, worktree removed, MCP server leaks with a
# dangling cwd" is the NORMAL end state. A safety-looking rule made the real target invisible — the
# same shape as the npm-exec allowlist bug.
#
# The two states the guard conflated are distinguishable: a daemon's cwd EXISTS (`/`, an install
# dir); an abandoned session child's cwd has been DELETED. lsof still reports the path either way,
# so `-d` on it separates them.

leaked_dir="$TMPROOT/leaked-worktree"
mkdir -p "$leaked_dir"
leaked_pid=$(spawn_orphan "$leaked_dir" "$node_exec" /some/leaked-mcp-server/index.js)
rm -rf "$leaked_dir"

if [[ -z "$leaked_pid" ]]; then
  nok "deleted-cwd: could not mint the leaked-server candidate (harness failure)"
else
  out=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" classify "$leaked_pid" 2>/dev/null)
  cls=$(json_get "$out" 'd["classification"]')
  if [[ "$cls" == "protected" ]]; then
    nok "deleted-cwd: THE REGRESSION — an orphan whose worktree was DELETED is protected, i.e. permanently unkillable (this is the normal leak shape after \`wtc\`)"
  else
    ok "deleted-cwd: an orphan whose worktree was deleted is not protected (got $cls)"
  fi
  expect_eq "deleted-cwd: an orphaned runtime whose cwd has been DELETED is safe_kill" \
    "safe_kill" "$cls"
  expect_contains "deleted-cwd: and the reason names the deleted cwd, not 'owner unknown'" \
    "$(json_get "$out" 'd["reason"]')" "has been deleted"

  # And it is actually reclaimable at act time, not merely labelled reclaimable.
  crush_in "$wt_a" kill "$leaked_pid" >/dev/null 2>&1
  sleep 1
  expect_dead "deleted-cwd: the leaked orphan is actually killed" "$leaked_pid"
fi

# The negative control that keeps the deleted-cwd rule from becoming a licence: a daemon-shaped
# orphan whose cwd EXISTS but is not a worktree is still protected. (Asserted above at cwd=/ too;
# repeated here as the direct counterpart of the rule just added.)
live_cwd="$TMPROOT/not-a-repo"
mkdir -p "$live_cwd"
notrepo_pid=$(spawn_orphan "$live_cwd" "$node_exec" --service)
if [[ -z "$notrepo_pid" ]]; then
  nok "deleted-cwd: could not mint the live-cwd daemon candidate (harness failure)"
else
  out=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" classify "$notrepo_pid" 2>/dev/null)
  expect_eq "deleted-cwd: an orphan whose cwd EXISTS but is not a worktree is still protected" \
    "protected" "$(json_get "$out" 'd["classification"]')"
fi

# ── Ownership: a SIBLING worktree's live process is NEVER killable ────────────────────────
# This is the F3 verified live case: MCP servers of a sibling session, scanned from here.

read -r sib_pid sib_session <<< "$(spawn_attached "$wt_b" "$mcp")"

if [[ -z "$sib_pid" ]]; then
  nok "ownership: could not mint a sibling candidate (harness failure)"
else
  out=$(crush_in "$wt_a" classify "$sib_pid" 2>/dev/null)
  expect_eq "ownership: a sibling worktree's live process is protected" \
    "protected" "$(json_get "$out" 'd["classification"]')"
  expect_eq "ownership: its owner_worktree is the sibling, not the scan root" \
    "$wt_b" "$(json_get "$out" 'd["owner_worktree"]')"
fi

# ── AGE IS NOT A PREDICATE (the F1 regression) ────────────────────────────────────────────
# Scoped to the pids this test MINTED — deliberately not a machine-global "zero zombies" count,
# which would be non-hermetic and would flake whenever a genuine orphan happens to exist on the
# dev box. A flaky safety test gets muted, and then nobody notices a predicate regression.
#
# With the age gate wide open (0), a live-parent MCP server must still appear in the report,
# carry orphan:false, and must NEVER be safe_kill. Under the old `elif age >= 60` it was flagged
# outright — at 61 minutes a "zombie", at 59 minutes clean, nothing about it having changed.

read -r f1_pid f1_session <<< "$(spawn_attached "$wt_a" "$mcp")"

if [[ -z "$f1_pid" ]]; then
  nok "F1: could not mint the live-parent candidate (harness failure)"
else
  scan=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" scan 2>/dev/null)
  expect_json "F1: scan with the age gate at 0 emits valid JSON" "$scan"

  entry=$(zombie_for "$scan" "$f1_pid")
  if [[ "$entry" == "null" || -z "$entry" ]]; then
    nok "F1: the minted live-parent MCP candidate is missing from the report entirely"
  else
    ok "F1: the minted live-parent MCP candidate IS reported (with a classification)"
    expect_eq "F1: the minted live-parent candidate is orphan:false" \
      "false" "$(json_get "$entry" 'd["orphan"]')"

    cls=$(json_get "$entry" 'd["classification"]')
    case "$cls" in
      consent_required|protected) ok "F1: it classifies $cls — never auto-killable" ;;
      *) nok "F1: it classifies '$cls' (want consent_required or protected)" ;;
    esac

    if [[ "$cls" == "safe_kill" ]]; then
      nok "F1: THE REGRESSION — a live-parent MCP server is safe_kill purely because of age"
    else
      ok "F1: a live-parent MCP server is NOT safe_kill at any age"
    fi
  fi
fi

# ── Unknown owner fails closed ────────────────────────────────────────────────────────────

gone_dir="$TMPROOT/vanishing"
mkdir -p "$gone_dir"
# Plain parent, so the SESSION axis contributes nothing and the assertion isolates the thing it
# names: an unresolvable OWNER must fail closed. With a claude-shaped parent this would classify
# protected via the foreign-session rule and prove nothing about owner resolution.
read -r gone_pid gone_parent <<< "$(spawn_attached_plain "$gone_dir" "$mcp")"
rm -rf "$gone_dir"

if [[ -z "$gone_pid" ]]; then
  nok "fail-closed: could not mint the deleted-cwd candidate (harness failure)"
else
  out=$(crush_in "$wt_a" classify "$gone_pid" 2>/dev/null)
  expect_eq "fail-closed: an attached process whose cwd is gone is consent_required, not safe_kill" \
    "consent_required" "$(json_get "$out" 'd["classification"]')"
fi

# ── Own process tree is protected ─────────────────────────────────────────────────────────
# $$ is this test script — an ancestor of the crush.sh it invokes. clawcrush must never kill
# its own host.

out=$(crush_in "$wt_a" classify "$$" 2>/dev/null)
expect_eq "own-tree: crush's own ancestor chain is protected" \
  "protected" "$(json_get "$out" 'd["classification"]')"
# Assert the REASON, not just the verdict. This shell also lives in a different worktree from
# the fixture scan root, so it would classify protected via OWNERSHIP even with own-tree
# protection removed entirely — green for the wrong reason, proving nothing.
expect_contains "own-tree: and it is protected BECAUSE it is in crush's own tree" \
  "$(json_get "$out" 'd["reason"]')" "own process tree"

# ── Never-kill allowlist beats even orphanhood ────────────────────────────────────────────

npm_exec=$(mk_exec "$TMPROOT/bin" "npm")
npm_pid=$(spawn_orphan "$wt_a" "$npm_exec" install)

if [[ -z "$npm_pid" ]]; then
  nok "allowlist: could not mint the npm install candidate (harness failure)"
else
  out=$(crush_in "$wt_a" classify "$npm_pid" 2>/dev/null)
  expect_eq "allowlist: a mid-flight npm install is protected even when orphaned" \
    "protected" "$(json_get "$out" 'd["classification"]')"
fi

# ...but the allowlist must stay NARROW. `npm exec` (npx) is how most MCP servers are launched
# (`npm exec mcp-remote …` — 17 of them are running on this machine right now), so allowlisting the
# npm binary broadly would make every npx-launched MCP server permanently unkillable, orphans
# included. An over-broad allowlist entry is a precision leak wearing a safety feature's clothes.
npx_pid=$(spawn_orphan "$wt_a" "$npm_exec" exec mcp-remote https://example.test/mcp)

if [[ -z "$npx_pid" ]]; then
  nok "allowlist: could not mint the npx-launched MCP candidate (harness failure)"
else
  out=$(crush_in "$wt_a" classify "$npx_pid" 2>/dev/null)
  expect_eq "allowlist: an ORPHANED npx-launched MCP server IS reclaimable (not allowlisted)" \
    "safe_kill" "$(json_get "$out" 'd["classification"]')"
fi

# ── Windowed matching: an argument is not a command ───────────────────────────────────────
# `tail -f …/x-playwright-mcp.log` merely MENTIONS a pattern. Matching the whole ps line
# (arguments included) flagged it as an MCP server.

tail_log="$TMPROOT/x-playwright-mcp.log"
printf 'nothing\n' > "$tail_log"
tail_pid=$(spawn_orphan "$wt_a" /usr/bin/tail -f "$tail_log")

if [[ -z "$tail_pid" ]]; then
  nok "windowing: could not mint the tail candidate (harness failure)"
else
  scan=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" scan 2>/dev/null)
  expect_eq "windowing: a tail -f of an MCP-named logfile is NOT flagged" \
    "null" "$(zombie_for "$scan" "$tail_pid")"
fi

# ── Boundaried matching: a WORD is not a command either ───────────────────────────────────
# Windowing the match to the command head is necessary but not sufficient: within the head the
# match was still a bare substring, so any path whose letters happened to CONTAIN a pattern
# matched it. Verified against the pre-fix engine: an orphaned `/bin/bash …/invitee-app/start.sh`
# came back pattern="vite", classification="safe_kill" — which fullcream then kills autonomously,
# with no human in the loop. Same defect class as the `tail -f` case above, one level in.
#
# Both directions are asserted. A test that only proves "not flagged" is satisfied by a pattern
# list that matches nothing at all, so the positive control has to sit next to it.

boundary_dir_exec=$(mk_exec "$TMPROOT/invitee-app" "start.sh")   # path CONTAINS 'vite'
boundary_dir_pid=$(spawn_orphan "$wt_a" "$boundary_dir_exec")

if [[ -z "$boundary_dir_pid" ]]; then
  nok "boundary: could not mint the invitee-app candidate (harness failure)"
else
  scan=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" scan 2>/dev/null)
  expect_eq "boundary: an orphan whose PATH merely contains 'vite' (invitee-app) is NOT flagged" \
    "null" "$(zombie_for "$scan" "$boundary_dir_pid")"
fi

# The same class in argument position: `runner …/invite_tool.py`.
runner_exec=$(mk_exec "$TMPROOT/bin" "runner")
boundary_arg_pid=$(spawn_orphan "$wt_a" "$runner_exec" "$TMPROOT/invite_tool.py")

if [[ -z "$boundary_arg_pid" ]]; then
  nok "boundary: could not mint the invite_tool candidate (harness failure)"
else
  scan=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" scan 2>/dev/null)
  expect_eq "boundary: an orphan whose ARGUMENT merely contains 'vite' (invite_tool.py) is NOT flagged" \
    "null" "$(zombie_for "$scan" "$boundary_arg_pid")"
fi

# Positive control: the real thing still matches. Without this, the two assertions above pass
# trivially if pattern matching breaks entirely.
vite_exec=$(mk_exec "$TMPROOT/bin" "vite")
vite_pid=$(spawn_orphan "$wt_a" "$vite_exec")

if [[ -z "$vite_pid" ]]; then
  nok "boundary: could not mint the real vite candidate (harness failure)"
else
  scan=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" scan 2>/dev/null)
  entry=$(zombie_for "$scan" "$vite_pid")
  if [[ "$entry" == "null" || -z "$entry" ]]; then
    nok "boundary: an orphan ACTUALLY named vite is no longer detected (the fix over-tightened)"
  else
    expect_eq "boundary: an orphan actually named vite IS still matched on 'vite'" \
      "vite" "$(json_get "$entry" 'd["pattern"]')"
  fi
fi

# ── do_kill: input validation ─────────────────────────────────────────────────────────────

crush kill abc >/dev/null 2>&1
if (( $? != 0 )); then ok "do_kill: a non-numeric pid is rejected"; else nok "do_kill: a non-numeric pid is rejected (got rc=0)"; fi

# A negative arg is a process-GROUP kill — the single most dangerous thing an unvalidated
# `kill "$@"` can be handed.
crush kill -- -5 >/dev/null 2>&1
if (( $? != 0 )); then ok "do_kill: a negative (process-group) arg is rejected"; else nok "do_kill: a negative arg is rejected (got rc=0)"; fi

# ── do_kill: the matrix is enforced at act time ───────────────────────────────────────────

# safe_kill: a genuine orphan in my worktree dies.
orph_pid=$(spawn_orphan "$wt_a" "$mcp")
if [[ -z "$orph_pid" ]]; then
  nok "do_kill: could not mint an orphan (harness failure)"
else
  crush_in "$wt_a" kill "$orph_pid" >/dev/null 2>&1
  sleep 1
  expect_dead "do_kill: a safe_kill orphan is killed" "$orph_pid"
fi

# protected (sibling worktree, attached): refused, and --consent does NOT unlock it.
read -r prot_pid prot_session <<< "$(spawn_attached "$wt_b" "$mcp")"
if [[ -z "$prot_pid" ]]; then
  nok "do_kill: could not mint the sibling candidate (harness failure)"
else
  out=$(crush_in "$wt_a" kill "$prot_pid" 2>/dev/null)
  expect_eq "do_kill: a sibling's live process is refused" "1" "$(json_get "$out" 'd["refused"]')"
  expect_alive "do_kill: the sibling's live process survives" "$prot_pid"

  # THE most safety-critical rule in the model. A caller that fabricates consent still must not
  # be able to kill a protected pid.
  crush_in "$wt_a" kill --consent "$prot_pid" >/dev/null 2>&1
  rc=$?
  if (( rc != 0 )); then ok "do_kill: --consent on a protected sibling pid exits non-zero"; else nok "do_kill: --consent on a protected sibling pid exits non-zero (got rc=0)"; fi
  sleep 1
  expect_alive "do_kill: --consent CANNOT unlock a protected sibling pid" "$prot_pid"
fi

# protected (allowlist): --consent does not unlock an allowlisted process either.
npm2_pid=$(spawn_orphan "$wt_a" "$npm_exec" install)
if [[ -z "$npm2_pid" ]]; then
  nok "do_kill: could not mint the second npm candidate (harness failure)"
else
  crush_in "$wt_a" kill --consent "$npm2_pid" >/dev/null 2>&1
  rc=$?
  if (( rc != 0 )); then ok "do_kill: --consent on an allowlisted pid exits non-zero"; else nok "do_kill: --consent on an allowlisted pid exits non-zero (got rc=0)"; fi
  sleep 1
  expect_alive "do_kill: --consent CANNOT unlock an allowlisted mid-flight npm install" "$npm2_pid"
fi

# consent_required: refused bare, killed only with an explicit per-pid --consent.
# Plain (session-less) parent — an attached process owned by ANOTHER live claude session is
# protected now, and no --consent unlocks it, so it cannot carry this assertion.
read -r cons_pid cons_parent <<< "$(spawn_attached_plain "$wt_a" "$mcp")"
if [[ -z "$cons_pid" ]]; then
  nok "do_kill: could not mint the consent candidate (harness failure)"
else
  out=$(crush_in "$wt_a" kill "$cons_pid" 2>/dev/null)
  expect_eq "do_kill: a consent_required pid is refused without --consent" "1" "$(json_get "$out" 'd["refused"]')"
  expect_alive "do_kill: it survives the bare kill" "$cons_pid"

  crush_in "$wt_a" kill --consent "$cons_pid" >/dev/null 2>&1
  sleep 1
  expect_dead "do_kill: it IS killed with an explicit per-pid --consent" "$cons_pid"
fi

# ── Cron routes through the classifier (the F2 re-arm precondition) ───────────────────────
# The dry-run log must contain ONLY genuine orphans. An attached candidate must not appear in
# any would-kill line at all — cron is unattended and has no consent path.

rm -f "$(crush_log)"

read -r cron_att_pid cron_att_session <<< "$(spawn_attached "$wt_a" "$mcp")"
cron_orph_pid=$(spawn_orphan "$wt_a" "$mcp")

if [[ -z "$cron_att_pid" || -z "$cron_orph_pid" ]]; then
  nok "cron: could not mint both candidates (harness failure)"
else
  CRUSH_MIN_AGE_MINUTES=0 crush cron >/dev/null 2>&1
  logtxt=$(log_contents)

  # Delimiter-anchored, NOT a bare substring — see expect_would_kill in lib.sh. A substring needle
  # for pid 123 matches the line for pid 1234, so the positive control below could be satisfied by
  # some OTHER pid's line, and the negative control next to it would then be green against a cron
  # that logged nothing at all.
  expect_would_kill "cron: the genuine orphan appears as a would-kill candidate" \
    "$logtxt" "$cron_orph_pid"
  expect_no_would_kill "cron: the ATTACHED candidate appears in no would-kill line at all" \
    "$logtxt" "$cron_att_pid"
  expect_alive "cron: the orphan is still alive (report-only)" "$cron_orph_pid"
  expect_alive "cron: the attached candidate is still alive" "$cron_att_pid"
fi

finish
