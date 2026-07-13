#!/bin/bash
# U3 — load-contention diagnosis. Report + attribution + recommendation, zero destructive surface.
#
# When `ng test` times out and Chrome disconnects, the cause is usually N concurrent test runs in
# SIBLING worktrees, not the diff. The field-correct action was to reroute specs to CI, not to
# kill the siblings — so this mode never acts. The read-only property is proven, not promised.

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

setup_tmp

wt_a=$(mk_repo "$TMPROOT/wtA")
wt_b=$(mk_repo "$TMPROOT/wtB")

ng=$(mk_exec "$TMPROOT/bin" "ng")

# ── Schema ────────────────────────────────────────────────────────────────────────────────

out=$(crush_in "$wt_a" contention 2>/dev/null)
rc=$?
expect_eq "schema: contention exits 0" "0" "$rc"
expect_json "schema: contention emits valid JSON" "$out"

cores=$(json_get "$out" 'd["cores"]')
if [[ "$cores" =~ ^[0-9]+$ ]] && (( cores > 0 )); then
  ok "schema: cores is a positive integer ($cores)"
else
  nok "schema: cores should be a positive integer (got '$cores')"
fi

for k in 1 5 15; do
  v=$(json_get "$out" "d['load']['$k']")
  if [[ "$v" =~ ^[0-9.]+$ ]]; then ok "schema: load[$k] is a number ($v)"; else nok "schema: load[$k] is a number (got '$v')"; fi
done

# ratio must actually be load1/cores, not a decorative field
ratio=$(json_get "$out" 'd["ratio"]')
load1=$(json_get "$out" 'd["load"]["1"]')
consistent=$(python3 -c "
l=float('$load1'); c=float('$cores'); r=float('$ratio')
print('yes' if abs(r - l/c) < 0.02 else 'no')
" 2>/dev/null)
expect_eq "schema: ratio is consistent with load1/cores" "yes" "$consistent"

# ── Grouping by owning worktree ───────────────────────────────────────────────────────────
# The whole point of the report: name WHOSE processes are causing the load.

read -r a_pid a_session <<< "$(spawn_attached "$wt_a" "$ng" test)"
read -r b_pid b_session <<< "$(spawn_attached "$wt_b" "$ng" test)"
sleep 1

out=$(crush_in "$wt_a" contention 2>/dev/null)
expect_json "grouping: contention with live candidates emits valid JSON" "$out"

owner_of_pid() {
  printf '%s' "$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
pid = int(sys.argv[1])
for g in d["groups"]:
    for p in g["procs"]:
        if p["pid"] == pid:
            print(g["worktree"])
            sys.exit(0)
print("MISSING")
' "$2" 2>/dev/null
}

if [[ -z "$a_pid" || -z "$b_pid" ]]; then
  nok "grouping: could not mint both ng test candidates (harness failure)"
else
  expect_eq "grouping: my worktree's ng test is grouped under my worktree" \
    "$wt_a" "$(owner_of_pid "$out" "$a_pid")"
  expect_eq "grouping: the sibling's ng test is grouped under the SIBLING worktree" \
    "$wt_b" "$(owner_of_pid "$out" "$b_pid")"
fi

# ── Read-only proof ───────────────────────────────────────────────────────────────────────
# A candidate that IS killable (a genuine orphan, safe_kill) must survive a contention run.
# If contention could ever act, this is the process it would take.

orph=$(spawn_orphan "$wt_a" "$ng" test)
if [[ -z "$orph" ]]; then
  nok "read-only: could not mint the killable orphan (harness failure)"
else
  cls=$(CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" classify "$orph" 2>/dev/null)
  expect_eq "read-only: the control process really IS killable (safe_kill)" \
    "safe_kill" "$(json_get "$cls" 'd["classification"]')"

  rm -f "$(crush_log)"
  CRUSH_MIN_AGE_MINUTES=0 crush_in "$wt_a" contention >/dev/null 2>&1
  sleep 1

  expect_alive "read-only: a safe_kill orphan survives a contention run" "$orph"
  expect_alive "read-only: the sibling's live ng test survives too" "$b_pid"

  logtxt=$(log_contents)
  expect_not_contains "read-only: contention logged no kill" "$logtxt" "Killed PID"
  expect_not_contains "read-only: contention logged no delete" "$logtxt" "Deleted:"
fi

# ── bash 3.2 shape ────────────────────────────────────────────────────────────────────────
# NOTE, honestly: a true "nothing contends" state cannot be forced hermetically — the scan is
# machine-wide and this box always has some dev processes running. So this asserts the shape
# (rc=0, valid JSON, groups is an array) rather than an empty groups list. The empty-array abort
# itself is pinned by u0's F6 assertions, which exercise the same json_array idiom on a genuinely
# empty list.

out=$(crush_in "$wt_a" contention 2>/dev/null)
rc=$?
expect_eq "shape: contention exits 0 under /bin/bash" "0" "$rc"
expect_json "shape: contention emits valid JSON under /bin/bash" "$out"
expect_eq "shape: groups is a JSON array" "yes" \
  "$(json_get "$out" '"yes" if isinstance(d["groups"], list) else "no"')"
expect_eq "shape: karma_port_clashes is an integer" "yes" \
  "$(json_get "$out" '"yes" if isinstance(d["karma_port_clashes"], int) else "no"')"

finish
