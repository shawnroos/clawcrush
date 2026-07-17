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
  expect_refused_kill "browser: --consent cannot unlock the user's browser" "$wt_a" "$user_chrome_pid"
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
    # REPORT-ONLY, deliberately. This asserted safe_kill under the old model, where "orphaned
    # listener on 42xx" was read as abandonment. A listener is by definition SERVING, and ppid==1
    # does not distinguish "its session died" from "it was disowned on purpose" — which is exactly
    # how the live `ng serve` on :3007 (pid 23675) became a kill candidate.
    #
    # It also contradicted the handoff ADDENDUM's own field-evidenced P0: never kill another
    # worktree's live `ng test`/`serve`. A listener on 4200 IS that server. The correct action there
    # was to reroute specs to CI, not to kill the sibling — so port detection's job is VISIBILITY:
    # it tells you who holds the port and which worktree owns it. Reclaiming it is a human's call.
    expect_eq "ports: an orphaned listener is REPORTED but protected (listening = serving)" \
      "protected" "$(json_get "$entry" 'd["classification"]')"
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
    # This assertion is about the PARSE, not the verdict — it pins that a spaced command name
    # survives scan_ports and arrives classified rather than being dropped on the floor. It read
    # safe_kill under the old model; a listener is now protected (see the 4287 case above), so the
    # verdict moved while the property under test did not. `protected` is still a classification —
    # a dropped listener would show up as a missing entry, which the branch above catches.
    expect_eq "ports(spaced): and it is classified, not silently dropped (listener -> protected)" \
      "protected" "$(json_get "$entry" 'd["classification"]')"
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

# ── THE LIVENESS VETO: a dev server that is SERVING is never killed ───────────────────────
# Round 3's second P0. `ng serve` at ppid==1 was read as "its session died", but
# `nohup npm run start:dev1 … & disown` is the DOCUMENTED launch path in these worktrees, so a dev
# server is ppid==1 FROM BIRTH. Verified live before this fix: pid 23675
# `npm exec ng serve --configuration=dev --port 3007`, ppid==1, 4h15m old, classified
#   {"classification":"safe_kill","owner_worktree":"…/worktrees/unified-canvas-selection"}
# while its child 23709 held `127.0.0.1:3007 (LISTEN)`. do_kill refuses only `protected`, so
# `crush.sh kill 23675` would have taken down a dev server that was actively serving.
#
# The name cannot authorize the kill, so the veto asks what the process is DOING. Deliberately a
# BEHAVIOURAL signal rather than another name list — the name lists failed in rounds 2 and 3, each
# time on the first daemon nobody had enumerated.
#
# THE FIXTURE MIRRORS THE REAL SHAPE: the subject holds NO socket, its CHILD does — exactly like the
# `npm exec` wrapper over node. A veto that only inspected the subject would pass a subject-holds-it
# fixture and still kill 23675. The fixture has to be able to catch the real bug.

veto_port=$(( 20000 + (RANDOM % 20000) ))
ng_serving=$(mk_exec "$TMPROOT/bin2" "ng" \
  "python3 -m http.server $veto_port --bind 127.0.0.1 >/dev/null 2>&1 &
   wait")
serving_pid=$(spawn_orphan "$wt_a" "$ng_serving" serve --port "$veto_port")

# The child needs a moment to bind before the veto can observe it.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  lsof -nP -iTCP:"$veto_port" -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.4
done

veto_listener=$(lsof -nP -iTCP:"$veto_port" -sTCP:LISTEN -t 2>/dev/null | head -1)
veto_kids=$(pgrep -P "${serving_pid:-0}" 2>/dev/null | tr '\n' ' ')

if [[ -z "$serving_pid" ]]; then
  nok "veto: could not mint the serving-dev-server candidate (harness failure)"
elif [[ -z "$veto_listener" ]]; then
  nok "veto: fixture never bound port $veto_port — the veto assertion would be vacuous (harness failure)"
elif [[ " $veto_kids " != *" $veto_listener "* ]]; then
  # A global port check would pass if an unrelated process already held this random port, and every
  # assertion below would then be measuring someone else's socket.
  nok "veto: port $veto_port is held by pid $veto_listener, not our child (${veto_kids:-none}) — fixture is measuring someone else"
else
  # Prove the premise of the fixture: the SUBJECT holds nothing, the CHILD holds the socket.
  if lsof -nP -iTCP -sTCP:LISTEN -a -p "$serving_pid" 2>/dev/null | grep -q LISTEN; then
    nok "veto: fixture is wrong shape — the SUBJECT holds the socket, so it cannot catch the 23675 (wrapper+child) bug"
  else
    ok "veto: fixture mirrors 23675 — subject holds no socket, a child holds it"
  fi

  out=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" classify "$serving_pid" 2>/dev/null)
  cls=$(json_get "$out" 'd["classification"]')
  if [[ "$cls" == "safe_kill" ]]; then
    nok "veto: THE REGRESSION — a ppid=1 ng serve whose child is LISTENING is safe_kill (this is live pid 23675)"
  else
    ok "veto: a ppid=1 ng serve whose child is LISTENING is NOT safe_kill (got $cls)"
  fi
  expect_eq "veto: it is protected, not merely consent_required" "protected" "$cls"

  expect_refused_kill "veto: --consent cannot unlock a serving dev server" "$wt_a" "$serving_pid"
  sleep 1
  expect_alive "veto: --consent cannot unlock a serving dev server either" "$serving_pid"
fi

# ── THE VETO MUST NOT FAIL OPEN ON lsof's EXIT STATUS ─────────────────────────────────────
# `lsof` exits 1 if ANY pid in -p is not found, EVEN WHEN it printed the LISTEN lines. Under
# `set -o pipefail` the original `lsof … | grep -q LISTEN` took lsof's status instead of grep's, so
# a serving process classified safe_kill. One unreaped zombie child was the whole difference between
# protected and safe_kill.
#
# The fixture therefore needs a tree that is BOTH listening AND has a dead child — the shape the
# other veto test structurally cannot produce, because a clean tree makes lsof exit 0 and the bug
# invisible. The same root cause also fires on a pid_tree_of snapshot race (a descendant exiting
# between `ps` and `lsof`), which is nondeterministic; the zombie is its deterministic twin.

zport=$(( 20000 + (RANDOM % 20000) ))

# Written directly rather than via mk_exec: bash REAPS its background children (a `( exit 0 ) &` left
# no zombie and the test went green against the broken engine — the harness-failure guard below is
# the only reason that was visible). Python never reaps without an explicit wait(), so forking there
# and returning gives a durable zombie. argv[0] is the file path, so naming the file `vite` is what
# boundary-matches DEV_PATTERNS — the same shape the real matcher sees.
mkdir -p "$TMPROOT/bin3"
zombie_exec="$TMPROOT/bin3/vite"
cat > "$zombie_exec" <<PYEOF
#!/usr/bin/env python3
import os, socket, sys, time
# Child 1: hold a real LISTENING socket.
if os.fork() == 0:
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", $zport)); s.listen(5)
    while True: time.sleep(1)
# Child 2: exit immediately. Never wait()ed -> stays <defunct> in our tree, which is what makes
# lsof exit non-zero while still printing child 1's LISTEN line.
if os.fork() == 0:
    os._exit(0)
time.sleep(3600)
PYEOF
chmod +x "$zombie_exec"
zombie_pid=$(spawn_orphan "$wt_a" "$zombie_exec" build --watch)
sleep 1

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  lsof -nP -iTCP:"$zport" -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.4
done

if [[ -z "$zombie_pid" ]]; then
  nok "veto/zombie: could not mint the candidate (harness failure)"
else
  # The fixture is only meaningful if the listener really is OUR descendant — a global port check
  # would pass if some unrelated process already held this random port, and the assertion below
  # would then be vacuous.
  listener_pid=$(lsof -nP -iTCP:"$zport" -sTCP:LISTEN -t 2>/dev/null | head -1)
  tree_pids=$(pgrep -P "$zombie_pid" 2>/dev/null | tr '\n' ' ')
  if [[ -z "$listener_pid" ]]; then
    nok "veto/zombie: nothing bound port $zport — the assertion would be vacuous (harness failure)"
  elif [[ " $tree_pids " != *" $listener_pid "* ]]; then
    nok "veto/zombie: port $zport is held by pid $listener_pid which is NOT our child (${tree_pids:-none}) — fixture is measuring someone else"
  else
    ok "veto/zombie: fixture verified — the listener ($listener_pid) is our own child"
    # `pgrep -P` does not report zombies, so ask ps for the whole table and filter by ppid — the
    # zombie is precisely the thing pgrep cannot see, and it is the thing under test.
    if ps -o ppid=,stat= -ax 2>/dev/null | awk -v p="$zombie_pid" '$1==p && $2 ~ /Z/' | grep -q .; then
      ok "veto/zombie: fixture verified — the tree really does contain an unreaped zombie"
    else
      nok "veto/zombie: no zombie in the tree — this fixture cannot catch the pipefail bug (harness failure)"
    fi

    out=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" classify "$zombie_pid" 2>/dev/null)
    cls=$(json_get "$out" 'd["classification"]')
    if [[ "$cls" == "safe_kill" ]]; then
      nok "veto/zombie: THE REGRESSION — a LISTENING tree with a zombie child is safe_kill (lsof exit status read as 'no listener')"
    else
      ok "veto/zombie: a LISTENING tree with a zombie child is still protected (got $cls)"
    fi
    expect_eq "veto/zombie: lsof's exit status must not override what it printed" "protected" "$cls"
  fi
fi

# RECALL CONTROL — the veto must not be a blanket amnesty for dev-stack processes. A finished
# karma/ng-test corpse holds no socket, and it is the ~100+/week toil U2 exists to reclaim. If this
# goes red the fix has bought precision by making the feature do nothing.
corpse_pid=$(spawn_orphan "$wt_a" "$ng" test --watch=false)
if [[ -z "$corpse_pid" ]]; then
  nok "veto: could not mint the finished-test corpse (harness failure)"
else
  out=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" classify "$corpse_pid" 2>/dev/null)
  expect_eq "veto: RECALL — an orphaned ng test holding NO socket is still safe_kill" \
    "safe_kill" "$(json_get "$out" 'd["classification"]')"
fi

finish
