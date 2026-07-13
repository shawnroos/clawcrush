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

# ── Liveness: the SAME pid reclassifies when its parent dies ──────────────────────────────

read -r att_pid att_session <<< "$(spawn_attached "$wt_a" "$mcp")"

if [[ -z "$att_pid" ]]; then
  nok "liveness: could not mint an attached candidate (harness failure)"
else
  out=$(crush_in "$wt_a" classify "$att_pid" 2>/dev/null)
  expect_eq "liveness: a live-parent candidate in my worktree is consent_required" \
    "consent_required" "$(json_get "$out" 'd["classification"]')"
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
read -r gone_pid gone_session <<< "$(spawn_attached "$gone_dir" "$mcp")"
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
read -r cons_pid cons_session <<< "$(spawn_attached "$wt_a" "$mcp")"
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

  expect_contains "cron: the genuine orphan appears as a would-kill candidate" \
    "$logtxt" "Cron dry-run: would-kill pid $cron_orph_pid"
  expect_not_contains "cron: the ATTACHED candidate appears in no would-kill line at all" \
    "$logtxt" "would-kill pid $cron_att_pid"
  expect_alive "cron: the orphan is still alive (report-only)" "$cron_orph_pid"
  expect_alive "cron: the attached candidate is still alive" "$cron_att_pid"
fi

finish
