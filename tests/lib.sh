#!/bin/bash
# Shared harness for the clawcrush runtime tests.
#
# Two rules make these tests worth trusting:
#   1. The engine is ALWAYS invoked via /bin/bash — macOS bash 3.2, the interpreter launchd
#      resolves regardless of PATH. Homebrew bash 5.x hides the empty-array abort (F6).
#   2. Process candidates are minted as REAL executables named after shipped patterns, so the
#      tests exercise the real matching path rather than a synthetic bypass.
#
# Deliberately NOT `set -e`: a failing assertion must not abort the remaining assertions.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
CRUSH="$REPO_ROOT/scripts/crush.sh"

PASS=0
FAIL=0
SPAWNED=()
TMPROOT=""
REAL_HOME="$HOME"

# ── Fixture lifecycle ──────────────────────────

setup_tmp() {
  TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/clawcrush-test.XXXXXX") || exit 1
  # Isolate HOME: this reroutes CRUSH_LOG and scan_global's ~/.claude entirely into the fixture.
  export HOME="$TMPROOT/home"
  mkdir -p "$HOME/.claude/logs"
}

cleanup_tmp() {
  local p
  for p in ${SPAWNED[@]+"${SPAWNED[@]}"}; do
    [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null
  done
  # Fake executables all live under TMPROOT, so this reaps anything still referencing it.
  if [[ -n "$TMPROOT" ]]; then
    pkill -9 -f "$TMPROOT" 2>/dev/null
    rm -rf "$TMPROOT" 2>/dev/null
  fi
  return 0
}
trap cleanup_tmp EXIT

crush_log() { printf '%s' "$HOME/.claude/logs/clawcrush.log"; }

log_contents() {
  local f
  f=$(crush_log)
  [[ -f "$f" ]] && cat "$f" || printf ''
}

# ── Engine invocation (ALWAYS /bin/bash) ───────

crush() { /bin/bash "$CRUSH" "$@"; }

crush_in() {
  local d="$1"; shift
  ( cd "$d" && /bin/bash "$CRUSH" "$@" )
}

# ── Assertions ─────────────────────────────────

ok()  { PASS=$((PASS + 1)); echo "  ok   — $1"; }
nok() { FAIL=$((FAIL + 1)); echo "  FAIL — $1"; }

expect_eq() {
  local desc="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then ok "$desc"; else nok "$desc (want '$want', got '$got')"; fi
}

expect_contains() {
  local desc="$1" hay="$2" needle="$3"
  if [[ "$hay" == *"$needle"* ]]; then ok "$desc"; else nok "$desc (missing '$needle')"; fi
}

expect_not_contains() {
  local desc="$1" hay="$2" needle="$3"
  if [[ "$hay" != *"$needle"* ]]; then ok "$desc"; else nok "$desc (unexpectedly found '$needle')"; fi
}

expect_alive() {
  local desc="$1" pid="$2"
  if kill -0 "$pid" 2>/dev/null; then ok "$desc"; else nok "$desc (pid $pid is dead)"; fi
}

expect_dead() {
  local desc="$1" pid="$2"
  if kill -0 "$pid" 2>/dev/null; then nok "$desc (pid $pid is still alive)"; else ok "$desc"; fi
}

expect_exists() {
  local desc="$1" path="$2"
  if [[ -e "$path" ]]; then ok "$desc"; else nok "$desc (missing $path)"; fi
}

expect_missing() {
  local desc="$1" path="$2"
  if [[ ! -e "$path" ]]; then ok "$desc"; else nok "$desc ($path still exists)"; fi
}

expect_json() {
  local desc="$1" json="$2"
  if printf '%s' "$json" | python3 -m json.tool >/dev/null 2>&1; then
    ok "$desc"
  else
    nok "$desc (not valid JSON: '${json:0:120}')"
  fi
}

# json_get <json> <python expr over `d`> — prints the value, booleans as true/false.
json_get() {
  printf '%s' "$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
r = eval(sys.argv[1])
if isinstance(r, bool):
    print("true" if r else "false")
elif r is None:
    print("null")
else:
    print(r)
' "$2" 2>/dev/null
}

finish() {
  echo "RESULT: $PASS passed, $FAIL failed"
  if (( FAIL > 0 )); then exit 1; fi
  exit 0
}

# ── Git repo fixtures ──────────────────────────

mk_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q 2>/dev/null
  git -C "$dir" config user.email "test@clawcrush.local"
  git -C "$dir" config user.name "clawcrush test"
  printf 'seed\n' > "$dir/README.md"
  git -C "$dir" add README.md >/dev/null 2>&1
  git -C "$dir" commit -qm seed >/dev/null 2>&1
  ( cd "$dir" && pwd -P )
}

# Backdate a path so it clears the 10-minute is_recent guard.
age_path() {
  touch -t "$(date -v-1d +%Y%m%d%H%M)" "$1" 2>/dev/null
}

# ── Fake process fixtures ──────────────────────

# mk_exec <dir> <name> [body]
# Mints an executable literally NAMED after a shipped pattern. Its ps command line becomes
# "/bin/bash <dir>/<name> [args]", so the shipped pattern match hits it for real.
# Body default: a sleep loop, so a kill -9 on the script leaves no long-lived orphan `sleep`.
mk_exec() {
  local dir="$1" name="$2" body="${3:-while true; do sleep 1; done}"
  mkdir -p "$dir"
  printf '#!/bin/bash\n%s\n' "$body" > "$dir/$name"
  chmod +x "$dir/$name"
  printf '%s' "$dir/$name"
}

track_pid() { [[ -n "${1:-}" ]] && SPAWNED+=("$1"); }

# Block until a pid has reparented to launchd (ppid == 1). Killing a process's parent makes it
# an orphan immediately, but "immediately" is not "synchronously with our next ps".
wait_ppid1() {
  local pid="$1" i=0 pp
  while (( i < 60 )); do
    pp=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ "$pp" == "1" ]] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# The zombie entry for a pid, as JSON ("null" when the scan did not report it at all).
zombie_for() {
  local scan_json="$1" pid="$2"
  printf '%s' "$scan_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
pid = int(sys.argv[1])
hit = [z for z in d["zombies"] if z["pid"] == pid]
print(json.dumps(hit[0]) if hit else "null")
' "$pid" 2>/dev/null
}

# spawn_orphan <cwd> <exe> [args...] -> prints the child pid (ppid == 1)
# The launcher exits immediately after backgrounding the child, so the child reparents to
# launchd. Verified: reparenting to ppid 1 is immediate on parent death.
spawn_orphan() {
  local cwd="$1"; shift
  local pf launcher pid="" i=0 pp
  pf=$(mktemp "$TMPROOT/pid.XXXXXX")
  launcher="$TMPROOT/launcher.$$.$RANDOM.sh"
  {
    printf '#!/bin/bash\n'
    printf 'cd %q || exit 1\n' "$cwd"
    printf '%q ' "$@"
    # Detach the child's stdio. These spawners are called inside $( ), and a child that
    # inherits the command substitution's stdout pipe keeps it open forever — the substitution
    # would never see EOF and the test would hang, not fail.
    printf '</dev/null >/dev/null 2>&1 &\n'
    printf 'echo $! > %q\n' "$pf"
  } > "$launcher"
  chmod +x "$launcher"
  /bin/bash "$launcher" </dev/null >/dev/null 2>&1

  while (( i < 60 )); do
    pid=$(cat "$pf" 2>/dev/null)
    if [[ -n "$pid" ]]; then
      pp=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      [[ "$pp" == "1" ]] && break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  track_pid "$pid"
  printf '%s' "$pid"
}

# spawn_attached <cwd> <exe> [args...] -> prints "<child_pid> <session_pid>"
# The parent is an executable named `claude`, so the ancestor walk sees a live session and the
# child classifies as attached — the exact F3 shape (a sibling session's live MCP server).
spawn_attached() {
  local cwd="$1"; shift
  local sdir pf session pid="" i=0
  sdir="$TMPROOT/session.$$.$RANDOM"
  mkdir -p "$sdir"
  pf=$(mktemp "$TMPROOT/pid.XXXXXX")
  {
    printf '#!/bin/bash\n'
    printf 'cd %q || exit 1\n' "$cwd"
    printf '%q ' "$@"
    printf '</dev/null >/dev/null 2>&1 &\n'
    printf 'echo $! > %q\n' "$pf"
    printf 'wait\n'
  } > "$sdir/claude"
  chmod +x "$sdir/claude"

  "$sdir/claude" </dev/null >/dev/null 2>&1 &
  session=$!
  track_pid "$session"

  while (( i < 60 )); do
    pid=$(cat "$pf" 2>/dev/null)
    [[ -n "$pid" ]] && break
    sleep 0.1
    i=$((i + 1))
  done
  track_pid "$pid"
  printf '%s %s' "$pid" "$session"
}
