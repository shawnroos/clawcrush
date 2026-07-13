#!/bin/bash
# U2 — the Angular/dev-server stack and port squatters, routed through U1's classifier.
#
# This unit is the reason the classifier had to come first. `ng serve` is BY DEFINITION old and
# alive. Adding these patterns to the old age-alone predicate would have turned "kills live MCP
# servers" into "kills the dev server you are actively using".
#
# Candidates are minted as real executables named after shipped DEV_PATTERNS entries (an
# executable literally named `ng`, invoked with `test`/`serve` as argv[1]), so the tests
# exercise the real matching path.

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

setup_tmp

wt_a=$(mk_repo "$TMPROOT/wtA")   # the scan root
wt_b=$(mk_repo "$TMPROOT/wtB")   # a sibling worktree

ng=$(mk_exec "$TMPROOT/bin" "ng")

# ── THE regression test: a sibling's ACTIVE ng test is never killable ─────────────────────
# The field episode this comes from: "I won't touch other worktrees' processes, but I'll kill
# my own defunct spec run."

read -r sib_pid sib_session <<< "$(spawn_attached "$wt_b" "$ng" test)"

if [[ -z "$sib_pid" ]]; then
  nok "regression: could not mint the sibling ng test (harness failure)"
else
  scan=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" scan 2>/dev/null)
  expect_json "regression: scan emits valid JSON with dev patterns" "$scan"

  entry=$(zombie_for "$scan" "$sib_pid")
  if [[ "$entry" == "null" || -z "$entry" ]]; then
    nok "regression: the sibling's active ng test is not detected at all"
  else
    ok "regression: the sibling's active ng test IS detected (visibility is the point)"
    expect_eq "regression: it is reported as protected" \
      "protected" "$(json_get "$entry" 'd["classification"]')"
    expect_eq "regression: its owner is the sibling worktree" \
      "$wt_b" "$(json_get "$entry" 'd["owner_worktree"]')"
  fi

  out=$(crush_in "$wt_a" kill "$sib_pid" 2>/dev/null)
  expect_eq "regression: killing the sibling's active ng test is refused" \
    "1" "$(json_get "$out" 'd["refused"]')"
  expect_alive "regression: the sibling's active ng test survives" "$sib_pid"
fi

# ── My own defunct run IS reclaimed ───────────────────────────────────────────────────────

own_pid=$(spawn_orphan "$wt_a" "$ng" test)

if [[ -z "$own_pid" ]]; then
  nok "own-defunct: could not mint the orphaned ng test (harness failure)"
else
  out=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" classify "$own_pid" 2>/dev/null)
  expect_eq "own-defunct: my own dead-parent ng test is safe_kill" \
    "safe_kill" "$(json_get "$out" 'd["classification"]')"

  crush_in "$wt_a" kill "$own_pid" >/dev/null 2>&1
  sleep 1
  expect_dead "own-defunct: and it is actually reclaimed" "$own_pid"
fi

# ── ng serve is detected too (not just ng test) ───────────────────────────────────────────

serve_pid=$(spawn_orphan "$wt_a" "$ng" serve)
if [[ -z "$serve_pid" ]]; then
  nok "ng serve: could not mint the candidate (harness failure)"
else
  scan=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" scan 2>/dev/null)
  entry=$(zombie_for "$scan" "$serve_pid")
  if [[ "$entry" == "null" || -z "$entry" ]]; then
    nok "ng serve: an orphaned ng serve is not detected"
  else
    expect_eq "ng serve: an orphaned ng serve is safe_kill" \
      "safe_kill" "$(json_get "$entry" 'd["classification"]')"
  fi
fi

# ── The REAL macOS browser shape is visible — and the user's own browser is still safe ────
# ORPHAN_RUNTIME_PATTERNS listed only lowercase `chrome`/`chromium`, and window_matches_pattern is
# case-sensitive, so the actual macOS executables (`/Applications/Google Chrome.app/Contents/MacOS/
# Google Chrome`) never matched — the single most common leaked-browser shape was invisible to the
# scanner, while BROWSER_CLASS_PATTERNS right below it already used the real capitalized names.
# The two lists disagreed about what a browser is called and the one gating KILL CANDIDACY had it
# wrong.
#
# Fixing that is only safe BECAUSE of the daemon guard: a Dock-launched Google Chrome is ppid==1
# for its entire life (verified on this machine — the user's browser, pid 95603, ppid 1, cwd
# ~/.agent-browser). Naming it here under a bare `orphan <=> ppid==1` rule would have made the
# user's actual browser safe_kill and fullcream would have closed it. Both halves are asserted.

chrome=$(mk_exec "$TMPROOT/bin" "Google Chrome")

# (a) The user's real browser: ppid==1, but its cwd is not a worktree. Must NOT be killable.
user_chrome_pid=$(spawn_orphan "/" "$chrome" --remote-debugging-port=0)
if [[ -z "$user_chrome_pid" ]]; then
  nok "browser: could not mint the user's-browser candidate (harness failure)"
else
  out=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" classify "$user_chrome_pid" 2>/dev/null)
  cls=$(json_get "$out" 'd["classification"]')
  if [[ "$cls" == "safe_kill" ]]; then
    nok "browser: THE REGRESSION — the user's Dock-launched Google Chrome is safe_kill (fullcream would close their browser)"
  else
    ok "browser: the user's ppid=1 Google Chrome (cwd not a worktree) is NOT safe_kill (got $cls)"
  fi
  crush_in "$wt_a" kill --consent "$user_chrome_pid" >/dev/null 2>&1
  sleep 1
  expect_alive "browser: and no --consent unlocks the user's browser either" "$user_chrome_pid"
fi

# (b) A leaked automation browser: orphaned, cwd IS the worktree. Must be seen AND reclaimable.
#     Without this the fix above is satisfied by a scanner that simply cannot see browsers at all.
leaked_chrome_pid=$(spawn_orphan "$wt_a" "$chrome" --headless)
if [[ -z "$leaked_chrome_pid" ]]; then
  nok "browser: could not mint the leaked-browser candidate (harness failure)"
else
  scan=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" scan 2>/dev/null)
  entry=$(zombie_for "$scan" "$leaked_chrome_pid")
  if [[ "$entry" == "null" || -z "$entry" ]]; then
    nok "browser: a leaked orphaned 'Google Chrome' in my worktree is INVISIBLE to the scanner"
  else
    ok "browser: a leaked orphaned 'Google Chrome' IS detected (the real macOS executable name)"
    expect_eq "browser: and it is reclaimable" \
      "safe_kill" "$(json_get "$entry" 'd["classification"]')"
  fi
fi

# ── Port squatters ────────────────────────────────────────────────────────────────────────

port_entry() {
  printf '%s' "$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
pid = int(sys.argv[1])
hit = [p for p in d["ports"] if p["pid"] == pid]
print(json.dumps(hit[0]) if hit else "null")
' "$2" 2>/dev/null
}

# An orphaned listener holding an Angular port — exactly what blocks the next `ng serve`.
squat_pid=$(spawn_orphan "$wt_a" /usr/bin/python3 -m http.server 4287 --bind 127.0.0.1)
# An attached listener owned by a SIBLING worktree.
read -r live_port_pid live_port_session <<< "$(spawn_attached "$wt_b" /usr/bin/python3 -m http.server 4288 --bind 127.0.0.1)"
sleep 1

scan=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" scan 2>/dev/null)
expect_json "ports: scan with a ports section emits valid JSON" "$scan"

if [[ -z "$squat_pid" ]]; then
  nok "ports: could not mint the orphaned listener (harness failure)"
else
  entry=$(port_entry "$scan" "$squat_pid")
  if [[ "$entry" == "null" || -z "$entry" ]]; then
    nok "ports: the orphaned port-squatter is not detected"
  else
    expect_eq "ports: the orphaned squatter is on the expected port" "4287" "$(json_get "$entry" 'd["port"]')"
    expect_eq "ports: the orphaned squatter is safe_kill" "safe_kill" "$(json_get "$entry" 'd["classification"]')"
  fi
fi

if [[ -z "$live_port_pid" ]]; then
  nok "ports: could not mint the sibling's live listener (harness failure)"
else
  entry=$(port_entry "$scan" "$live_port_pid")
  if [[ "$entry" == "null" || -z "$entry" ]]; then
    nok "ports: the sibling's live listener is not reported"
  else
    ok "ports: the sibling's live listener IS reported (it explains 'port already in use')"
    expect_eq "ports: but it is protected, not reclaimable" \
      "protected" "$(json_get "$entry" 'd["classification"]')"
  fi
fi

# ── A listener whose COMMAND contains SPACES ──────────────────────────────────────────────
# Chrome's executables are literally named `Google Chrome` / `Google Chrome for Testing`, and
# Chrome is the process that holds the CDP port (9222) the port scan exists to find. lsof's
# columnar output is a DISPLAY format — a fixed-width COMMAND column carrying a name with spaces
# in it — so any parse keyed on positional fields ($2 for the pid, $9 for the address) is one
# rendering quirk away from reading a command fragment as a pid and dropping the listener on the
# floor. scan_ports reads -F field output (`p<pid>` / `n<addr>`, one field per line) instead.
# This pins that: the port scan must see Chrome's real command shape.

spaced_exec=$(mk_listener "$TMPROOT/bin" "Google Chrome for Testing") || spaced_exec=""

if [[ -z "$spaced_exec" ]]; then
  nok "ports(spaced): could not compile the spaced-name listener (harness failure — needs cc)"
else
  spaced_pid=$(spawn_orphan "$wt_a" "$spaced_exec" 4289)
  sleep 1
  scan=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" scan 2>/dev/null)
  entry=$(port_entry "$scan" "$spaced_pid")
  if [[ "$entry" == "null" || -z "$entry" ]]; then
    nok "ports(spaced): a listener whose command name contains spaces is invisible to the port scan"
  else
    expect_eq "ports(spaced): a spaced-command listener (Chrome's real shape) IS detected" \
      "4289" "$(json_get "$entry" 'd["port"]')"
    expect_eq "ports(spaced): and it is classified, not silently dropped" \
      "safe_kill" "$(json_get "$entry" 'd["classification"]')"
  fi
fi

# ── Grace selection seam ──────────────────────────────────────────────────────────────────

expect_eq "grace: a ChromeHeadless-class process gets the short grace" \
  "2" "$(crush grace-for '/x/ChromeHeadless --headless' 2>/dev/null)"
expect_eq "grace: 'Google Chrome for Testing' gets the short grace" \
  "2" "$(crush grace-for '/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing' 2>/dev/null)"
expect_eq "grace: a non-browser process gets the default grace" \
  "5" "$(crush grace-for '/bin/bash /x/karma' 2>/dev/null)"

# ── Grace in practice: a TERM-ignoring browser dies sooner than the default class ──────────
# karma/Chrome empirically ignore SIGTERM and always needed -9. Both must end up dead; the
# browser class must just get there faster.

trap_body='trap "" TERM; while true; do sleep 1; done'
chrome_exec=$(mk_exec "$TMPROOT/bin" "ChromeHeadless" "$trap_body")
karma_exec=$(mk_exec "$TMPROOT/bin" "karma" "$trap_body")

chrome_pid=$(spawn_orphan "$wt_a" "$chrome_exec")
karma_pid=$(spawn_orphan "$wt_a" "$karma_exec")

if [[ -z "$chrome_pid" || -z "$karma_pid" ]]; then
  nok "grace: could not mint the TERM-ignoring candidates (harness failure)"
else
  t0=$(date +%s)
  crush_in "$wt_a" kill "$chrome_pid" >/dev/null 2>&1
  t1=$(date +%s)
  chrome_elapsed=$((t1 - t0))

  t0=$(date +%s)
  crush_in "$wt_a" kill "$karma_pid" >/dev/null 2>&1
  t1=$(date +%s)
  karma_elapsed=$((t1 - t0))

  expect_dead "grace: the TERM-ignoring browser is dead (SIGKILL escalation)" "$chrome_pid"
  expect_dead "grace: the TERM-ignoring default-class process is dead too" "$karma_pid"

  if (( chrome_elapsed < karma_elapsed )); then
    ok "grace: the browser class waits less than the default class (${chrome_elapsed}s < ${karma_elapsed}s)"
  else
    nok "grace: the browser class should escalate sooner (browser ${chrome_elapsed}s, default ${karma_elapsed}s)"
  fi

  if (( chrome_elapsed <= 4 )); then
    ok "grace: the browser escalated within the short grace (${chrome_elapsed}s)"
  else
    nok "grace: the browser took ${chrome_elapsed}s (expected ~2s + epsilon)"
  fi

  if (( karma_elapsed >= 4 )); then
    ok "grace: the default class took the full grace (${karma_elapsed}s)"
  else
    nok "grace: the default class only took ${karma_elapsed}s (expected ~5s)"
  fi
fi

finish
