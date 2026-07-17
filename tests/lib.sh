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
TMPROOT=""
PIDFILE=""
REAL_HOME="$HOME"

# ── Fixture lifecycle ──────────────────────────

setup_tmp() {
  TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/clawcrush-test.XXXXXX") || exit 1
  # Isolate HOME: this reroutes CRUSH_LOG and scan_global's ~/.claude entirely into the fixture.
  export HOME="$TMPROOT/home"
  mkdir -p "$HOME/.claude/logs"
  # Spawned pids go to a FILE, not a shell array. The spawners are called as $(spawn_orphan …),
  # i.e. in a subshell, so an array append inside them is discarded — nothing would ever be
  # tracked, and a leaked listener would squat a test port and fail the NEXT run.
  PIDFILE="$TMPROOT/spawned.pids"
  : > "$PIDFILE"
}

cleanup_tmp() {
  local p
  if [[ -n "$PIDFILE" && -f "$PIDFILE" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null
    done < "$PIDFILE"
  fi
  # Belt and braces: the fake executables all live under TMPROOT.
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

# Cron-log assertions get their own matchers, because `expect_contains` is a bash SUBSTRING test and
# pids PREFIX-ALIAS: a needle for pid 123 matches the line written for pid 1234 (verified — needles
# 123, 1234 and 12345 all match a line for pid 12345). These are the SAFETY PROOFS that gate
# re-arming the LaunchAgent, so a false pass here is worse than it looks: the positive control
# ("the genuine orphan appears as a would-kill candidate") could be satisfied by a DIFFERENT pid's
# line, which means the paired negative ("the attached candidate appears in no would-kill line")
# would go green even against a cron that logged nothing at all.
#
# `would-kill pid <pid> ` — anchored on the field delimiter the log format already provides — is
# unambiguous: 1234's line reads `would-kill pid 1234 name=`, which cannot contain `pid 123 `.
expect_would_kill() {
  local desc="$1" hay="$2" pid="$3"
  if printf '%s\n' "$hay" | grep -qE "would-kill pid ${pid}( |$)"; then ok "$desc"
  else nok "$desc (no would-kill line for pid $pid)"; fi
}

expect_no_would_kill() {
  local desc="$1" hay="$2" pid="$3"
  if printf '%s\n' "$hay" | grep -qE "would-kill pid ${pid}( |$)"; then
    nok "$desc (found a would-kill line naming pid $pid)"
  else ok "$desc"; fi
}

expect_alive() {
  local desc="$1" pid="$2"
  if kill -0 "$pid" 2>/dev/null; then ok "$desc"; else nok "$desc (pid $pid is dead)"; fi
}

expect_dead() {
  local desc="$1" pid="$2"
  if kill -0 "$pid" 2>/dev/null; then nok "$desc (pid $pid is still alive)"; else ok "$desc"; fi
}

# expect_refused_kill <desc> <cwd> <pid...> — run `kill --consent <pid>` and assert the engine
# REFUSED it, positively.
#
# `crush … kill --consent "$p" >/dev/null 2>&1; expect_alive …` is NOT this assertion. It discards
# both output and status, so it is equally satisfied by the engine refusing (what we mean) and by
# the kill never running at all — a parse error, a bad flag, an argv change. The most
# safety-critical rule in the model ("no flag unlocks protected") would then be green on the wrong
# error path, which has already happened once on this branch. Assert the verdict, then survival.
expect_refused_kill() {
  local desc="$1" cwd="$2"; shift 2
  local out
  out=$(crush_in "$cwd" kill --consent "$@" 2>/dev/null) || true
  expect_json "$desc — kill emits valid JSON (proves it ran)" "$out"
  expect_eq "$desc" "1" "$(json_get "$out" 'd["refused"]')"
  expect_eq "$desc — and nothing was killed" "0" "$(json_get "$out" 'd["killed"]')"
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

# mk_listener <dir> <name> — a real Mach-O that binds 127.0.0.1:<argv[1]> and then sleeps.
# Prints its path; fails (prints nothing) when there is no compiler.
#
# It has to be COMPILED, not copied or aliased. lsof's COMMAND comes from the kernel's p_comm,
# which is the executable FILE's basename: `exec -a "Some Name"` does not change it (verified —
# lsof still reports `Python`), a symlink resolves to its target's name, and a copy of a system
# binary is SIGKILLed on exec by code signing. Compiling is the only way to mint a process whose
# lsof COMMAND genuinely contains spaces — i.e. Chrome's real shape (`Google Chrome`,
# `Google Chrome for Testing`), the process that holds the CDP port the scan looks for.
mk_listener() {
  local dir="$1" name="$2" src
  command -v cc >/dev/null 2>&1 || return 1
  mkdir -p "$dir"
  src="$dir/.listener.c"
  cat > "$src" <<'CSRC'
#include <stdlib.h>
#include <unistd.h>
#include <netinet/in.h>
#include <sys/socket.h>
int main(int argc, char **argv) {
  int port = (argc > 1) ? atoi(argv[1]) : 0;
  int s = socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a;
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  a.sin_port = htons(port);
  if (bind(s, (struct sockaddr *)&a, sizeof a)) return 1;
  if (listen(s, 1)) return 1;
  for (;;) sleep(1);
}
CSRC
  cc -o "$dir/$name" "$src" 2>/dev/null || return 1
  printf '%s' "$dir/$name"
}

track_pid() {
  [[ -n "${1:-}" && -n "$PIDFILE" ]] && printf '%s\n' "$1" >> "$PIDFILE"
  return 0
}

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

# spawn_parented <parent_rel_path> <cwd> <exe> [args...] -> prints "<child_pid> <parent_pid>"
#
# The generalized attached-process fixture. <parent_rel_path> is minted UNDER $TMPROOT and becomes
# the parent's argv[0], so the caller chooses the exact command shape the ancestor walk will see.
#
# This parameterization is the point. The original fixture hardcoded a parent named literally
# `claude`, which trivially satisfies ANY plausible session regex — so every attached-process
# assertion in the suite exercised a session shape that could not fail, and the suite stayed green
# while the session axis was dead against the real-world shape (a bare version-binary path). A
# fixture that cannot fail is not evidence.
spawn_parented() {
  local prel="$1" cwd="$2"; shift 2
  local ppath pf session pid="" i=0
  ppath="$TMPROOT/$prel.$$.$RANDOM/$(basename "$prel")"
  mkdir -p "$(dirname "$ppath")"
  pf=$(mktemp "$TMPROOT/pid.XXXXXX")
  {
    printf '#!/bin/bash\n'
    printf 'cd %q || exit 1\n' "$cwd"
    printf '%q ' "$@"
    printf '</dev/null >/dev/null 2>&1 &\n'
    printf 'echo $! > %q\n' "$pf"
    printf 'wait\n'
  } > "$ppath"
  chmod +x "$ppath"

  "$ppath" </dev/null >/dev/null 2>&1 &
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

# spawn_attached <cwd> <exe> [args...] -> prints "<child_pid> <session_pid>"
# Parent is named `claude` — a live Claude session that is NOT ours. The child is attached and,
# because the session is foreign, protected whatever worktree it sits in.
spawn_attached() {
  spawn_parented "session/claude" "$@"
}

# spawn_attached_versioned <cwd> <exe> [args...] -> prints "<child_pid> <session_pid>"
# The REAL-WORLD session shape, and the one the old regex could not see: the agent process is a
# bare version-binary PATH (`.../share/claude/versions/2.1.207`) with no `claude` word boundary
# after it. On a swarm/subagent session this is the ONLY claude process in the chain — its parent
# is tmux — so if the walk misses it, the session axis is dead. Deliberately NOT named `claude`.
spawn_attached_versioned() {
  spawn_parented "share/claude/versions/2.1.207" "$@"
}

# spawn_attached_plain <cwd> <exe> [args...] -> prints "<child_pid> <parent_pid>"
# A live parent that is NOT a claude session at all (a supervisor, a shell). The child is attached
# with NO owning session — the case where the worktree axis is all we have, and the only shape that
# should still reach `consent_required` inside my own worktree.
spawn_attached_plain() {
  spawn_parented "supervisor" "$@"
}
