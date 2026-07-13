#!/bin/bash

# ClawCrush Scanner Engine
# Outputs JSON for process zombies and repo slop.
# The Claude agent handles UX — this script is a pure data source + executor.
#
# Usage:
#   crush.sh scan [--global]                  — scan CWD (or global) for zombies + slop
#   crush.sh contention                       — READ-ONLY load-contention report
#   crush.sh classify <pid> [scan_root]       — report one pid's classification (read-only)
#   crush.sh kill [--consent <pid>]... <pid>… — kill processes, enforcing the kill matrix
#   crush.sh delete --root <path> <file>...   — delete files, contained under <root>
#   crush.sh setup-launchagent                — install/verify hourly LaunchAgent
#   crush.sh cron                             — REPORT-ONLY dry run: logs would-kill candidates
#
# CRON IS REPORT-ONLY. It kills nothing. Every line it emits is prefixed `Cron dry-run:`.
#
# SAFETY MODEL — age is never sufficient to call a process a zombie. Two axes decide:
#   liveness  — orphan <=> ppid == 1
#   ownership — owning worktree (lsof cwd -> git toplevel) + owning claude session
#
#                    | orphan (ppid=1)          | attached (live parent)
#   -----------------+--------------------------+------------------------------
#   my worktree      | safe_kill                | consent_required
#   another worktree | safe_kill (+ reported)   | protected — NEVER KILL
#   owner unknown    | safe_kill (orphan crisp) | consent_required (fail closed)
#
# `protected` is refused unconditionally — no flag, including --consent, unlocks it.

set -euo pipefail

ACTION="${1:-scan}"
shift 2>/dev/null || true

# ── Constants ──────────────────────────────────

MIN_AGE_MINUTES=${CRUSH_MIN_AGE_MINUTES:-60}
RECENT_MINUTES=10
LAUNCHAGENT_LABEL="com.clawcrush.zombie-killer"
LAUNCHAGENT_PLIST="$HOME/Library/LaunchAgents/${LAUNCHAGENT_LABEL}.plist"
CRUSH_LOG="$HOME/.claude/logs/clawcrush.log"

MCP_PATTERNS=(
  "mcp-remote"
  "mcp-gong-calls"
  "mcp-pointer"
  "task-master-ai"
  "playwright-mcp"
  "mcp-server-github"
  "gong-lite"
  "mcp-apple-calendars"
  "qmd mcp"
  "mcp-notion"
  "mcp-linear"
  "chrome-devtools-mcp"
  "context7"
)

# The Angular test/dev stack — the highest-frequency real toil (~100+ manual kills across
# dozens of worktrees). These are HARD-GATED on the classifier above: this is precisely the
# process class that is legitimately old-and-alive, so under the old age-alone predicate adding
# them would have meant killing the dev server you are actively using.
DEV_PATTERNS=(
  "karma"
  "ChromeHeadless"
  "Google Chrome for Testing"
  "ng serve"
  "ng test"
  "vite"
  "webpack"
  "esbuild"
)

# Generic runtimes: only ever candidates when ALREADY orphaned (ppid=1) AND old.
ORPHAN_RUNTIME_PATTERNS=("node" "bun" "chromium" "chrome")

# TERM-resistant browsers: karma/Chrome empirically survive SIGTERM and always needed -9, so
# waiting the full 5s on them just delays the SIGKILL that was always coming.
BROWSER_CLASS_PATTERNS=("ChromeHeadless" "Google Chrome for Testing" "Chromium" "chromium" "Chrome" "chrome")
BROWSER_GRACE_SECONDS=2
DEFAULT_GRACE_SECONDS=5

# Dev-server ports worth reclaiming: the Angular range, plus Chrome's CDP port.
PORT_RANGE_LO=4200
PORT_RANGE_HI=4299
PORT_EXTRA=9222

# Which ancestor command shapes count as a LIVE Claude session. This is the one fuzzy seam in
# the model — the crisp decision (the kill matrix) is fully deterministic downstream.
# Verified live shapes: ".../ClaudeCode.app/Contents/MacOS/claude --bg-pty-host …".
# Drift shows up as attached processes classifying consent_required (fail closed), never as a
# false safe_kill.
CRUSH_SESSION_RE=${CRUSH_SESSION_RE:-'(^|[/[:space:]])claude([[:space:]]|$)'}

# Never killed, at any classification, orphaned or not.
#
# The bar is narrow and specific: killing a mid-flight INSTALL corrupts node_modules and the
# lockfile, and killing a language server takes the editor down with it. Nothing else qualifies.
#
# `npm exec` (i.e. npx) deliberately does NOT belong here, even though it is an npm subcommand:
# it is how most MCP servers are launched (`npm exec mcp-remote …`), so allowlisting it would make
# every npx-launched MCP server permanently unkillable — including genuinely orphaned ones, which
# are exactly what clawcrush exists to reclaim. An over-broad allowlist entry is a precision leak
# that hides as a safety feature.
NEVER_KILL_PATTERNS=(
  "npm install"
  "npm ci"
  "pnpm install"
  "pnpm add"
  "yarn install"
  "yarn add"
  "tsserver"
  "typescript-language-server"
  "language-server"
)

SLOP_EXTENSIONS=("log" "bak" "orig" "backup")
SLOP_PREFIXES=("temp-" "scratch-" "debug-" "untitled")
SLOP_DIRS=("test-results" "playwright-report" ".playwright-mcp")
SLOP_MEDIA=("mp4" "mp3" "wav" "avi" "mov")

# Files and dirs that are ALWAYS safe (never crushed)
SAFE_PATTERNS=("node_modules" ".git" ".env" "package-lock.json" "yarn.lock" "pnpm-lock.yaml" "bun.lockb")

# ── Helpers ────────────────────────────────────

log() {
  mkdir -p "$(dirname "$CRUSH_LOG")"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$CRUSH_LOG"
}

# JSON string escaping: backslashes FIRST, then quotes (F7).
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'
}

# Join pre-built JSON object strings into an array. Safe with ZERO args — this is the
# bash-3.2 `set -u` empty-array abort (F6) that silently emptied every automated scan.
json_array() {
  local out="[" first="true" item
  for item in "$@"; do
    if [[ "$first" == "true" ]]; then first="false"; else out="$out,"; fi
    out="$out$item"
  done
  printf '%s]' "$out"
}

# Fully resolve a path (following symlinks) without relying on GNU `readlink -f`.
canonical_path() {
  local p="$1" n=0 link d b rd
  while [[ -L "$p" ]] && (( n < 40 )); do
    link=$(readlink "$p") || return 1
    if [[ "$link" == /* ]]; then p="$link"; else p="$(dirname "$p")/$link"; fi
    n=$((n + 1))
  done
  d=$(dirname "$p")
  b=$(basename "$p")
  rd=$(cd "$d" 2>/dev/null && pwd -P) || return 1
  if [[ "$rd" == "/" ]]; then printf '/%s' "$b"; else printf '%s/%s' "$rd" "$b"; fi
}

# Parse a ps etime into _AGE_MINS / _AGE_FMT.
#
# Deliberately sets globals instead of echoing: the scan walks every process on the machine,
# and a command substitution forks a subshell per call. On a contended box (the exact condition
# clawcrush exists to clean up — load 97 on 10 cores was measured during the audit) per-line
# forks make a scan take minutes. Builtins only, no forks on the hot path.
_AGE_MINS=0
_AGE_FMT=""
set_age() {
  local etime="$1" days=0 hours=0 mins=0

  if [[ "$etime" =~ ^([0-9]+)-([0-9]+):([0-9]+):([0-9]+)$ ]]; then
    days="${BASH_REMATCH[1]}"; hours="${BASH_REMATCH[2]}"; mins="${BASH_REMATCH[3]}"
  elif [[ "$etime" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
    hours="${BASH_REMATCH[1]}"; mins="${BASH_REMATCH[2]}"
  elif [[ "$etime" =~ ^([0-9]+):([0-9]+)$ ]]; then
    mins="${BASH_REMATCH[1]}"
  fi

  _AGE_MINS=$(( 10#$days * 1440 + 10#$hours * 60 + 10#$mins ))

  if (( _AGE_MINS >= 1440 )); then
    _AGE_FMT="$((_AGE_MINS / 1440))d $((_AGE_MINS % 1440 / 60))h"
  elif (( _AGE_MINS >= 60 )); then
    _AGE_FMT="$((_AGE_MINS / 60))h $((_AGE_MINS % 60))m"
  else
    _AGE_FMT="${_AGE_MINS}m"
  fi
}

# Check if a file matches safe patterns
is_safe() {
  local filepath="$1" pat
  for pat in "${SAFE_PATTERNS[@]}"; do
    if [[ "$filepath" == *"$pat"* ]]; then
      return 0
    fi
  done
  return 1
}

# Was this path modified in the last N minutes?
# For DIRECTORIES, judge by the newest CONTENT mtime. SLOP_DIRS are all directories and their
# deletion is recursive, so the directory inode's own mtime is the wrong signal (F7).
is_recent() {
  local filepath="$1"
  local mins="${2:-$RECENT_MINUTES}"

  if [[ -d "$filepath" ]]; then
    find "$filepath" -mmin "-${mins}" -print -quit 2>/dev/null | grep -q .
    return $?
  fi

  if [[ "$(uname)" == "Darwin" ]]; then
    local mod_epoch now_epoch age_mins
    mod_epoch=$(stat -f %m "$filepath" 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    age_mins=$(( (now_epoch - mod_epoch) / 60 ))
    (( age_mins < mins ))
  else
    find "$filepath" -maxdepth 0 -mmin "-${mins}" 2>/dev/null | grep -q .
  fi
}

# Check if a file matches any crushignore pattern
matches_crushignore() {
  local filepath="$1"
  local ignorefile="$2"
  [[ ! -f "$ignorefile" ]] && return 1

  local basename
  basename=$(basename "$filepath")

  while IFS= read -r pattern; do
    [[ -z "$pattern" || "$pattern" =~ ^# ]] && continue

    # Direct match
    if [[ "$filepath" == $pattern || "$basename" == $pattern ]]; then
      return 0
    fi

    # Directory match (pattern ends with /)
    if [[ "$pattern" == */ && "$filepath" == ${pattern}* ]]; then
      return 0
    fi

    # Extension match (*.ext)
    if [[ "$pattern" == \*.* ]]; then
      local ext="${pattern#\*.}"
      if [[ "$filepath" == *."$ext" ]]; then
        return 0
      fi
    fi
  done < "$ignorefile"

  return 1
}

# ── Process attribution: the two-axis model ────
#
#   LIVENESS  — orphan <=> ppid == 1. Reparenting to launchd is immediate on parent death, so
#               "no live parent" is exactly ppid==1. Crisp; not a heuristic.
#   OWNERSHIP — which worktree owns the process (lsof cwd -> git toplevel), and which live
#               claude session, if any, is its ancestor.
#
# Age is NOT an axis. It is metadata and the cron gate. A long-running `ng serve` is by
# definition old and by definition alive — that is the whole point.

# Window a ps command line to its command HEAD: argv[0] plus following non-flag words, stopping
# at the first flag. Without this, `grep -F` matched the whole ps line including arguments, so
# `tail -f /tmp/x-playwright-mcp.log` read as an MCP server (F7).
command_window() {
  local cmd="$1" out="" tok count=0
  set -f
  for tok in $cmd; do
    case "$tok" in
      -*) break ;;
    esac
    if [[ -z "$out" ]]; then out="$tok"; else out="$out $tok"; fi
    count=$((count + 1))
    if (( count >= 8 )); then break; fi
  done
  set +f
  printf '%s' "$out"
}

pid_command() {
  local line
  line=$(ps -o command= -p "$1" 2>/dev/null) || return 1
  [[ -n "$line" ]] || return 1
  printf '%s' "$line"
}

pid_ppid() {
  local v
  v=$(ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ') || return 1
  [[ -n "$v" ]] || return 1
  printf '%s' "$v"
}

# This script's own ancestor chain. Anything in it is PROTECTED — clawcrush must never kill its
# own host (the `node`/`chrome` patterns could otherwise match the session running it).
OWN_ANCESTORS=""
compute_own_ancestors() {
  local p="$$" guard=0
  while [[ -n "$p" && "$p" != "0" && "$p" != "1" ]] && (( guard < 64 )); do
    OWN_ANCESTORS="$OWN_ANCESTORS $p "
    p=$(pid_ppid "$p" 2>/dev/null) || p=""
    guard=$((guard + 1))
  done
}
compute_own_ancestors

in_own_tree() {
  [[ "$OWN_ANCESTORS" == *" $1 "* ]]
}

matches_never_kill() {
  local window="$1" pat
  for pat in "${NEVER_KILL_PATTERNS[@]}"; do
    if [[ "$window" == *"$pat"* ]]; then
      return 0
    fi
  done
  return 1
}

# The git worktree containing a directory.
worktree_of() {
  local dir="$1" top
  [[ -d "$dir" ]] || return 1
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ -n "$top" ]] || return 1
  printf '%s' "$top"
}

current_scan_root() {
  local top
  if top=$(worktree_of "$PWD"); then
    printf '%s' "$top"
  else
    printf '%s' "$PWD"
  fi
}

# Walk ancestors for a live Claude session. Prints its pid, or fails.
owning_session_of() {
  local p guard=0 cmd win
  p=$(pid_ppid "$1" 2>/dev/null) || return 1
  while [[ -n "$p" && "$p" != "0" && "$p" != "1" ]] && (( guard < 64 )); do
    cmd=$(pid_command "$p" 2>/dev/null) || cmd=""
    if [[ -n "$cmd" ]]; then
      win=$(command_window "$cmd")
      if [[ "$win" =~ $CRUSH_SESSION_RE ]]; then
        printf '%s' "$p"
        return 0
      fi
    fi
    p=$(pid_ppid "$p" 2>/dev/null) || p=""
    guard=$((guard + 1))
  done
  return 1
}

# The worktree that owns a process, via its cwd. Fails when unresolvable — and unresolvable
# always means "fail closed", never "assume mine".
owner_worktree_of() {
  local cwd top
  cwd=$(lsof -a -p "$1" -d cwd -Fn 2>/dev/null | grep '^n' | head -1 | sed 's/^n//') || return 1
  [[ -n "$cwd" && -d "$cwd" ]] || return 1
  top=$(worktree_of "$cwd") || return 1
  printf '%s' "$top"
}

# classify_pid <pid> [scan_root] -> classification|orphan|owner_worktree|owning_session|reason
#
# The kill matrix, in one place, computed at scan time AND re-derived at act time:
#
#                    | orphan (ppid=1)          | attached (live parent)
#   -----------------+--------------------------+------------------------------
#   my worktree      | safe_kill                | consent_required
#   another worktree | safe_kill (+ reported)   | protected — NEVER KILL
#   owner unknown    | safe_kill (orphan crisp) | consent_required (fail closed)
#
# Own process tree and the never-kill allowlist are not separate features — they are the same
# predicate, short-circuiting to protected.
classify_pid() {
  local pid="$1"
  local scan_root="${2:-}"
  local cmd win ppid orphan owner session reason

  cmd=$(pid_command "$pid" 2>/dev/null) || { printf 'gone|false|||process no longer exists'; return 0; }
  win=$(command_window "$cmd")

  if in_own_tree "$pid"; then
    printf 'protected|false|||in clawcrush own process tree'
    return 0
  fi

  if matches_never_kill "$win"; then
    printf 'protected|false|||never-kill allowlist'
    return 0
  fi

  ppid=$(pid_ppid "$pid" 2>/dev/null) || ppid=""
  if [[ "$ppid" == "1" ]]; then orphan="true"; else orphan="false"; fi

  owner=$(owner_worktree_of "$pid" 2>/dev/null) || owner=""
  session=$(owning_session_of "$pid" 2>/dev/null) || session=""

  if [[ "$orphan" == "true" ]]; then
    reason="ppid=1 (orphaned)"
    [[ -n "$owner" ]] && reason="ppid=1 (orphaned), owner: $owner"
    printf 'safe_kill|true|%s|%s|%s' "$owner" "$session" "$reason"
    return 0
  fi

  if [[ -z "$owner" ]]; then
    printf 'consent_required|false||%s|attached (ppid=%s), owner unresolvable — fail closed' "$session" "$ppid"
    return 0
  fi

  if [[ -n "$scan_root" && "$owner" == "$scan_root" ]]; then
    reason="attached (ppid=$ppid) in this worktree"
    [[ -n "$session" ]] && reason="attached to live claude (pid $session), owner: $owner"
    printf 'consent_required|false|%s|%s|%s' "$owner" "$session" "$reason"
    return 0
  fi

  reason="attached (ppid=$ppid), owner: $owner (another worktree)"
  [[ -n "$session" ]] && reason="attached to live claude (pid $session), owner: $owner (another worktree)"
  printf 'protected|false|%s|%s|%s' "$owner" "$session" "$reason"
}

# ── Scan: Processes ────────────────────────────

# Emit one row per process candidate:
#   pid|ppid|age_mins|age_fmt|name|pattern|classification|orphan|owner|session|reason
# Single source of truth for both `scan` (JSON) and `cron` (dry-run log).
zombie_rows() {
  local scan_root="${1:-}"
  local seen=" "
  local pid ppid etime cmd win p

  # The pattern list. CRUSH_EXTRA_PATTERNS is a harness-only seam for smoke patterns that
  # should not ship as real detection rules.
  local patterns=()
  for p in "${MCP_PATTERNS[@]}"; do patterns+=("$p"); done
  for p in "${DEV_PATTERNS[@]}"; do patterns+=("$p"); done
  if [[ -n "${CRUSH_EXTRA_PATTERNS:-}" ]]; then
    local oldifs="$IFS"
    IFS=':'
    for p in $CRUSH_EXTRA_PATTERNS; do
      [[ -n "$p" ]] && patterns+=("$p")
    done
    IFS="$oldifs"
  fi

  # ONE ps call, matched in-process. The old code ran `ps | grep | awk` once per pattern and
  # then forked three more subshells per matched line to split the fields.
  while read -r pid ppid etime cmd; do
    [[ -z "${pid:-}" || -z "${cmd:-}" ]] && continue
    [[ "$pid" == "$$" ]] && continue
    case "$cmd" in
      *crush.sh*) continue ;;
    esac
    [[ "$seen" == *" $pid "* ]] && continue

    # Match on the command HEAD, not the whole ps line (F7).
    win=$(command_window "$cmd")

    local name="" pattern=""

    for p in ${patterns[@]+"${patterns[@]}"}; do
      if [[ "$win" == *"$p"* ]]; then
        pattern="$p"
        name="${p#mcp-}"
        name="${name%% *}"
        break
      fi
    done

    if [[ -z "$pattern" ]]; then
      # Generic runtimes are too broad to report while attached — they'd list every node
      # process on the machine. They stay gated on orphan AND age.
      [[ "$ppid" != "1" ]] && continue
      for p in "${ORPHAN_RUNTIME_PATTERNS[@]}"; do
        if [[ "$win" =~ (^|[/[:space:]])"$p"([[:space:]]|$) ]]; then
          pattern="$p (orphaned)"
          name="$p"
          break
        fi
      done
      [[ -z "$pattern" ]] && continue
      set_age "$etime"
      (( _AGE_MINS < MIN_AGE_MINUTES )) && continue
    else
      set_age "$etime"
    fi

    # EVERY candidate is reported and carries a classification. Age no longer decides anything:
    # the old `elif age >= 60` made a live, actively-used MCP server a "zombie" at 61 minutes
    # and clean at 59 — a detector whose output was a pure function of session age (F1).
    local cls classification orphan owner session reason
    cls=$(classify_pid "$pid" "$scan_root")
    IFS='|' read -r classification orphan owner session reason <<< "$cls"

    # Vanished between ps and classify — not reportable.
    [[ "$classification" == "gone" ]] && continue

    seen="$seen$pid "
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$pid" "$ppid" "$_AGE_MINS" "$_AGE_FMT" "$name" "$pattern" \
      "$classification" "$orphan" "$owner" "$session" "$reason"
  done < <(ps -eo pid=,ppid=,etime=,command= 2>/dev/null)
}

scan_zombies() {
  local scan_root="${1:-}"
  local json_items=()
  local row pid ppid age_mins age_fmt name pattern classification orphan owner session reason

  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    IFS='|' read -r pid ppid age_mins age_fmt name pattern classification orphan owner session reason <<< "$row"

    local owner_json="null"
    [[ -n "$owner" ]] && owner_json="\"$(json_escape "$owner")\""
    local session_json="null"
    [[ -n "$session" ]] && session_json="$session"

    json_items+=("{\"pid\":$pid,\"name\":\"$(json_escape "$name")\",\"pattern\":\"$(json_escape "$pattern")\",\"age\":\"$age_fmt\",\"age_mins\":$age_mins,\"ppid\":$ppid,\"orphan\":$orphan,\"owner_worktree\":$owner_json,\"owning_session\":$session_json,\"classification\":\"$classification\",\"reason\":\"$(json_escape "$reason")\"}")
  done < <(zombie_rows "$scan_root")

  json_array ${json_items[@]+"${json_items[@]}"}
}

# ── Scan: Port squatters ───────────────────────

# Pattern+ppid matching misses port-squatters: a dead-parent listener still holding 4200 blocks
# the next `ng serve`, and the manual fix was always `lsof -ti:PORT | kill -9`. Listeners run
# through the SAME classifier — an attached listener in another worktree is reported (it
# explains "port already in use") but is never killable.
port_in_range() {
  local port="$1"
  if (( port >= PORT_RANGE_LO && port <= PORT_RANGE_HI )); then return 0; fi
  if (( port == PORT_EXTRA )); then return 0; fi
  return 1
}

scan_ports() {
  local scan_root="${1:-}"
  local json_items=()
  local seen=" "
  local pid addr port

  while read -r pid addr; do
    [[ -z "${pid:-}" || -z "${addr:-}" ]] && continue
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" == "$$" ]] && continue
    port="${addr##*:}"
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    port_in_range "$port" || continue
    [[ "$seen" == *" $pid:$port "* ]] && continue
    seen="$seen$pid:$port "

    local cmd win cls classification orphan owner session reason
    cmd=$(pid_command "$pid" 2>/dev/null) || continue
    win=$(command_window "$cmd")
    cls=$(classify_pid "$pid" "$scan_root")
    IFS='|' read -r classification orphan owner session reason <<< "$cls"
    [[ "$classification" == "gone" ]] && continue

    local owner_json="null"
    [[ -n "$owner" ]] && owner_json="\"$(json_escape "$owner")\""

    json_items+=("{\"port\":$port,\"pid\":$pid,\"command\":\"$(json_escape "$win")\",\"orphan\":$orphan,\"owner_worktree\":$owner_json,\"classification\":\"$classification\",\"reason\":\"$(json_escape "$reason")\"}")
  done < <(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2, $9}')

  json_array ${json_items[@]+"${json_items[@]}"}
}

# ── Scan: Slop Files ───────────────────────────

scan_slop() {
  local target_dir="${1:-.}"
  local crushignore="${target_dir}/.crushignore"
  local json_items=()

  # Must be a git repo
  if ! git -C "$target_dir" rev-parse --is-inside-work-tree &>/dev/null; then
    echo "[]"
    return
  fi

  local root_real
  root_real=$(cd "$target_dir" 2>/dev/null && pwd -P) || root_real="$target_dir"

  local filepath
  while IFS= read -r -d '' filepath; do
    [[ -z "$filepath" ]] && continue

    local fullpath="${target_dir}/${filepath}"
    local basename
    basename=$(basename "$filepath")
    local ext="${basename##*.}"
    local dir
    dir=$(dirname "$filepath")
    local slop_type=""
    local size="0"

    is_safe "$filepath" && continue
    [[ -e "$fullpath" ]] && is_recent "$fullpath" && continue
    matches_crushignore "$filepath" "$crushignore" && continue

    local slop_ext
    for slop_ext in "${SLOP_EXTENSIONS[@]}"; do
      if [[ "$ext" == "$slop_ext" ]]; then
        slop_type="$slop_ext"
        break
      fi
    done

    if [[ -z "$slop_type" ]]; then
      local prefix
      for prefix in "${SLOP_PREFIXES[@]}"; do
        if [[ "$basename" == ${prefix}* ]]; then
          slop_type="temp"
          break
        fi
      done
    fi

    if [[ -z "$slop_type" && "$dir" == "." ]]; then
      local media_ext
      for media_ext in "${SLOP_MEDIA[@]}"; do
        if [[ "$ext" == "$media_ext" ]]; then
          slop_type="media"
          break
        fi
      done
    fi

    if [[ -z "$slop_type" ]]; then
      if [[ "$basename" =~ ^(.+)[-_]v?[0-9]+\.[a-z]+$ ]]; then
        local base_name="${BASH_REMATCH[1]}"
        local base_file="${dir}/${base_name}.${ext}"
        if [[ -e "${target_dir}/${base_file}" ]] || git -C "$target_dir" ls-files --error-unmatch "$base_file" &>/dev/null; then
          slop_type="dupe"
        fi
      fi
    fi

    if [[ -z "$slop_type" ]]; then
      local slop_dir
      for slop_dir in "${SLOP_DIRS[@]}"; do
        if [[ "$filepath" == ${slop_dir}/* || "$filepath" == "$slop_dir" ]]; then
          slop_type="test-artifact"
          break
        fi
      done
    fi

    [[ -z "$slop_type" ]] && continue

    if [[ -f "$fullpath" ]]; then
      size=$(stat -f %z "$fullpath" 2>/dev/null || stat -c %s "$fullpath" 2>/dev/null || echo "0")
    elif [[ -d "$fullpath" ]]; then
      size=$(du -sk "$fullpath" 2>/dev/null | awk '{print $1 * 1024}' || echo "0")
    fi
    [[ -z "$size" ]] && size=0

    local size_fmt
    if (( size >= 1048576 )); then
      size_fmt="$(( size / 1048576 ))M"
    elif (( size >= 1024 )); then
      size_fmt="$(( size / 1024 ))K"
    else
      size_fmt="${size}B"
    fi

    json_items+=("{\"path\":\"$(json_escape "$filepath")\",\"type\":\"$slop_type\",\"size\":$size,\"size_fmt\":\"$size_fmt\",\"tracked\":false,\"root\":\"$(json_escape "$root_real")\"}")
  done < <(git -C "$target_dir" ls-files --others --exclude-standard -z 2>/dev/null || true)

  # Tracked slop: reported, never deleted.
  while IFS= read -r -d '' filepath; do
    [[ -z "$filepath" ]] && continue
    local basename
    basename=$(basename "$filepath")
    local ext="${basename##*.}"
    local dir
    dir=$(dirname "$filepath")
    local slop_type=""
    local fullpath="${target_dir}/${filepath}"

    is_safe "$filepath" && continue
    matches_crushignore "$filepath" "$crushignore" && continue
    [[ "$dir" != "." ]] && continue

    if [[ "$ext" == "log" ]]; then
      slop_type="log"
    fi

    if [[ -z "$slop_type" ]]; then
      local prefix
      for prefix in "${SLOP_PREFIXES[@]}"; do
        if [[ "$basename" == ${prefix}* ]]; then
          slop_type="temp"
          break
        fi
      done
    fi

    [[ -z "$slop_type" ]] && continue

    local size=0
    if [[ -f "$fullpath" ]]; then
      size=$(stat -f %z "$fullpath" 2>/dev/null || stat -c %s "$fullpath" 2>/dev/null || echo "0")
    fi
    [[ -z "$size" ]] && size=0

    local size_fmt
    if (( size >= 1048576 )); then
      size_fmt="$(( size / 1048576 ))M"
    elif (( size >= 1024 )); then
      size_fmt="$(( size / 1024 ))K"
    else
      size_fmt="${size}B"
    fi

    json_items+=("{\"path\":\"$(json_escape "$filepath")\",\"type\":\"$slop_type\",\"size\":$size,\"size_fmt\":\"$size_fmt\",\"tracked\":true}")
  done < <(git -C "$target_dir" ls-files -z 2>/dev/null || true)

  json_array ${json_items[@]+"${json_items[@]}"}
}

# ── Scan: Global ───────────────────────────────

# Resolve a ~/.claude/projects/<dir>'s REAL cwd from its newest session JSONL.
# The dash-encoding is NOT invertible (F5: 138/145 live dirs decoded to nonexistent paths and
# were offered for deletion). Never guess — no parseable cwd means fail closed.
resolve_project_cwd() {
  local ref_dir="$1" newest cwd
  newest=$(ls -t "${ref_dir%/}"/*.jsonl 2>/dev/null | head -1) || true
  [[ -n "$newest" && -f "$newest" ]] || return 1
  cwd=$(grep -o '"cwd":"[^"]*"' "$newest" 2>/dev/null | head -1 | sed 's/^"cwd":"//; s/"$//') || true
  [[ -n "$cwd" ]] || return 1
  printf '%s' "$cwd"
}

scan_global() {
  local projects_root="$HOME/.claude/projects"
  local claude_root="$HOME/.claude"

  # 1. Orphaned refs — ONLY when the real cwd was positively resolved AND is gone (R9).
  local orphaned_refs=()
  if [[ -d "$projects_root" ]]; then
    local ref_dir
    for ref_dir in "$projects_root"/*/; do
      [[ -d "$ref_dir" ]] || continue
      local dir_name real_cwd
      dir_name=$(basename "$ref_dir")
      real_cwd=$(resolve_project_cwd "$ref_dir" 2>/dev/null) || real_cwd=""
      [[ -z "$real_cwd" ]] && continue
      [[ -d "$real_cwd" ]] && continue

      local ref_size size_fmt
      ref_size=$(du -sk "$ref_dir" 2>/dev/null | awk '{print $1 * 1024}' || echo "0")
      [[ -z "$ref_size" ]] && ref_size=0
      if (( ref_size >= 1024 )); then
        size_fmt="$(( ref_size / 1024 ))K"
      else
        size_fmt="${ref_size}B"
      fi
      orphaned_refs+=("{\"name\":\"$(json_escape "$dir_name")\",\"path\":\"$(json_escape "${ref_dir%/}")\",\"cwd\":\"$(json_escape "$real_cwd")\",\"root\":\"$(json_escape "$projects_root")\",\"size\":$ref_size,\"size_fmt\":\"$size_fmt\"}")
    done
  fi

  # 2. Config backups in ~/.claude/ — a DIFFERENT authorized root, depth-1 only (KTD6).
  local config_backups=()
  local backup_file
  while IFS= read -r backup_file; do
    [[ -z "$backup_file" ]] && continue
    local bname bsize size_fmt
    bname=$(basename "$backup_file")
    bsize=$(stat -f %z "$backup_file" 2>/dev/null || echo "0")
    [[ -z "$bsize" ]] && bsize=0
    if (( bsize >= 1024 )); then
      size_fmt="$(( bsize / 1024 ))K"
    else
      size_fmt="${bsize}B"
    fi
    config_backups+=("{\"name\":\"$(json_escape "$bname")\",\"path\":\"$(json_escape "$backup_file")\",\"root\":\"$(json_escape "$claude_root")\",\"size\":$bsize,\"size_fmt\":\"$size_fmt\"}")
  done < <(find "$claude_root" -maxdepth 1 \( -name "*.backup*" -o -name "*.bak" \) 2>/dev/null || true)

  # 3. Plugin cache stats (report only — no delete surface)
  local cache_size="0" cache_size_fmt="0B" cache_count=0
  if [[ -d "$HOME/.claude/plugins/cache" ]]; then
    cache_size=$(du -sk "$HOME/.claude/plugins/cache" 2>/dev/null | awk '{print $1 * 1024}' || echo "0")
    [[ -z "$cache_size" ]] && cache_size=0
    cache_count=$(find "$HOME/.claude/plugins/cache" -maxdepth 2 -type d 2>/dev/null | wc -l | tr -d ' ')
    if (( cache_size >= 1048576 )); then
      cache_size_fmt="$(( cache_size / 1048576 ))M"
    elif (( cache_size >= 1024 )); then
      cache_size_fmt="$(( cache_size / 1024 ))K"
    fi
  fi

  local refs_json backups_json
  refs_json=$(json_array ${orphaned_refs[@]+"${orphaned_refs[@]}"})
  backups_json=$(json_array ${config_backups[@]+"${config_backups[@]}"})

  echo "{\"orphaned_refs\":$refs_json,\"config_backups\":$backups_json,\"plugin_cache\":{\"size\":$cache_size,\"size_fmt\":\"$cache_size_fmt\",\"count\":$cache_count}}"
}

# ── Scan: Load contention (READ-ONLY) ──────────

# When `ng test` times out at 3 minutes with 0/0 coverage and Chrome disconnects, the cause is
# usually not the diff — it's N concurrent test runs in SIBLING worktrees. Measured during the
# audit: load 97.79 on 10 cores.
#
# The field-correct action there was to reroute spec validation to CI, NOT to kill the siblings.
# So this mode diagnoses and attributes; it never acts. Its body contains no kill, no rm, and no
# state-changing call of any kind — the read-only property is structural, not a promise.
# It is the natural partner of the ownership guardrail: it tells you the contention is the
# siblings', and that the answer is CI rather than crushing them.
scan_contention() {
  local scan_root="${1:-}"
  local cores load1 load5 load15 ratio raw p

  cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 0)
  [[ "$cores" =~ ^[0-9]+$ ]] || cores=0

  raw=$(sysctl -n vm.loadavg 2>/dev/null || echo "{ 0.00 0.00 0.00 }")
  load1=$(printf '%s' "$raw" | awk '{print $2}')
  load5=$(printf '%s' "$raw" | awk '{print $3}')
  load15=$(printf '%s' "$raw" | awk '{print $4}')
  [[ "$load1" =~ ^[0-9.]+$ ]] || load1="0.00"
  [[ "$load5" =~ ^[0-9.]+$ ]] || load5="0.00"
  [[ "$load15" =~ ^[0-9.]+$ ]] || load15="0.00"

  if (( cores > 0 )); then
    ratio=$(awk -v l="$load1" -v c="$cores" 'BEGIN { printf "%.2f", l / c }')
  else
    ratio="0.00"
  fi

  local contend_patterns=()
  for p in "${DEV_PATTERNS[@]}"; do contend_patterns+=("$p"); done
  contend_patterns+=("tsc")
  if [[ -n "${CRUSH_EXTRA_PATTERNS:-}" ]]; then
    local oldifs="$IFS"
    IFS=':'
    for p in $CRUSH_EXTRA_PATTERNS; do
      [[ -n "$p" ]] && contend_patterns+=("$p")
    done
    IFS="$oldifs"
  fi

  # Collect "owner<TAB>json" rows, then group by owner (bash 3.2: no associative arrays).
  local rows=()
  local pid cpu cmd win hit owner
  while read -r pid cpu cmd; do
    [[ -z "${pid:-}" || -z "${cmd:-}" ]] && continue
    [[ "$pid" == "$$" ]] && continue
    case "$cmd" in
      *crush.sh*) continue ;;
    esac

    win=$(command_window "$cmd")
    hit=""
    for p in ${contend_patterns[@]+"${contend_patterns[@]}"}; do
      if [[ "$win" == *"$p"* ]]; then hit="$p"; break; fi
    done
    [[ -z "$hit" ]] && continue

    owner=$(owner_worktree_of "$pid" 2>/dev/null) || owner="unknown"
    [[ -z "$owner" ]] && owner="unknown"
    [[ "$cpu" =~ ^[0-9.]+$ ]] || cpu="0.0"

    rows+=("${owner}	{\"pid\":$pid,\"command\":\"$(json_escape "$win")\",\"cpu\":$cpu,\"pattern\":\"$(json_escape "$hit")\"}")
  done < <(ps -eo pid=,%cpu=,command= 2>/dev/null)

  local groups_json=()
  if (( ${#rows[@]} > 0 )); then
    local owners owner_key r o procs
    owners=$(printf '%s\n' "${rows[@]}" | cut -f1 | sort -u)
    while IFS= read -r owner_key; do
      [[ -z "$owner_key" ]] && continue
      procs=()
      for r in "${rows[@]}"; do
        o="${r%%	*}"
        if [[ "$o" == "$owner_key" ]]; then
          procs+=("${r#*	}")
        fi
      done
      local procs_json
      procs_json=$(json_array ${procs[@]+"${procs[@]}"})
      groups_json+=("{\"worktree\":\"$(json_escape "$owner_key")\",\"count\":${#procs[@]},\"procs\":$procs_json}")
    done <<< "$owners"
  fi

  # Karma's default port range: more than one listener there is a clash.
  local karma_clashes
  karma_clashes=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
    | awk 'NR>1 {n=$9; sub(/.*:/, "", n); if (n+0 >= 9876 && n+0 <= 9885) print $2}' \
    | sort -u | wc -l | tr -d ' ')
  [[ "$karma_clashes" =~ ^[0-9]+$ ]] || karma_clashes=0
  if (( karma_clashes > 0 )); then karma_clashes=$(( karma_clashes - 1 )); fi

  local groups
  groups=$(json_array ${groups_json[@]+"${groups_json[@]}"})

  echo "{\"cores\":$cores,\"load\":{\"1\":$load1,\"5\":$load5,\"15\":$load15},\"ratio\":$ratio,\"groups\":$groups,\"karma_port_clashes\":$karma_clashes,\"scan_root\":\"$(json_escape "$scan_root")\"}"
}

# ── Actions ────────────────────────────────────

# SIGTERM grace, by process class.
grace_for_window() {
  local window="$1" pat
  for pat in "${BROWSER_CLASS_PATTERNS[@]}"; do
    if [[ "$window" == *"$pat"* ]]; then
      printf '%s' "$BROWSER_GRACE_SECONDS"
      return 0
    fi
  done
  printf '%s' "$DEFAULT_GRACE_SECONDS"
}

# do_kill [--consent <pid>]... <pid>...
#
#   safe_kill        -> killed unconditionally
#   consent_required -> killed ONLY with an explicit per-pid --consent
#   protected        -> REFUSED unconditionally. No flag, including --consent, unlocks it.
#                       There is no caller-reachable path to kill a protected pid.
#
# The classification is re-derived here, immediately before signalling, not trusted from the
# scan — lowfat scans, renders a table, and waits on a human, and macOS recycles pids.
#
# --consent may only ever be constructed from an explicit per-item human selection (lowfat's
# AskUserQuestion). fullcream never passes it. The engine cannot verify a flag's provenance,
# so that rule is enforced by review at the command layer, not here.
do_kill() {
  local scan_root
  scan_root=$(current_scan_root)

  local consent=" "
  local listed=" "
  local pids=()

  # `--consent <pid>` BOTH names the pid and consents to it. It never merely annotates a pid
  # supplied elsewhere, so a caller cannot accidentally consent to something it did not list.
  while (( $# > 0 )); do
    case "$1" in
      --consent)
        local c="${2:-}"
        if [[ ! "$c" =~ ^[0-9]+$ ]]; then
          log "BLOCKED invalid --consent value: '${c}'"
          echo "{\"killed\":0,\"failed\":0,\"refused\":0,\"error\":\"invalid --consent value\"}" >&2
          return 2
        fi
        consent="$consent$c "
        if [[ "$listed" != *" $c "* ]]; then
          listed="$listed$c "
          pids+=("$c")
        fi
        shift 2
        ;;
      *)
        # Positive integers only. A negative arg is a process-GROUP kill (F7).
        if [[ ! "$1" =~ ^[0-9]+$ ]]; then
          log "BLOCKED invalid pid argument: '$1'"
          echo "{\"killed\":0,\"failed\":0,\"refused\":0,\"error\":\"invalid pid argument\"}" >&2
          return 2
        fi
        if [[ "$listed" != *" $1 "* ]]; then
          listed="$listed$1 "
          pids+=("$1")
        fi
        shift
        ;;
    esac
  done

  if (( ${#pids[@]} == 0 )); then
    echo "{\"killed\":0,\"failed\":0,\"refused\":0,\"error\":\"no pids\"}" >&2
    return 2
  fi

  local killed=0 failed=0 refused=0
  local pid

  for pid in "${pids[@]}"; do
    local cls classification orphan owner session reason
    cls=$(classify_pid "$pid" "$scan_root")
    IFS='|' read -r classification orphan owner session reason <<< "$cls"

    if [[ "$classification" == "gone" ]]; then
      failed=$((failed + 1))
      log "Skipped PID $pid (no longer exists)"
      continue
    fi

    if [[ "$classification" == "protected" ]]; then
      refused=$((refused + 1))
      log "REFUSED PID $pid — protected ($reason)"
      continue
    fi

    if [[ "$classification" == "consent_required" ]]; then
      if [[ "$consent" != *" $pid "* ]]; then
        refused=$((refused + 1))
        log "REFUSED PID $pid — consent_required, no --consent given ($reason)"
        continue
      fi
      log "CONSENTED PID $pid ($reason)"
    fi

    local cmd win grace
    cmd=$(pid_command "$pid" 2>/dev/null) || cmd=""
    win=$(command_window "$cmd")
    grace=$(grace_for_window "$win")

    if kill "$pid" 2>/dev/null; then
      local waited=0
      while (( waited < grace )) && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        log "SIGKILL PID $pid (SIGTERM ignored after ${grace}s)"
      else
        log "Killed PID $pid"
      fi
      killed=$((killed + 1))
    else
      failed=$((failed + 1))
      log "Failed to kill PID $pid"
    fi
  done

  echo "{\"killed\":$killed,\"failed\":$failed,\"refused\":$refused}"
  if (( refused > 0 )); then
    return 3
  fi
  return 0
}

# do_delete --root <path> <target>...
#   Every target must realpath-resolve STRICTLY under <root>. No root, no delete (R3/KTD6).
#   Nothing ties a delete target to the scanned repo without this (F4: proven arbitrary rm -rf).
do_delete() {
  local root=""
  if [[ "${1:-}" == "--root" ]]; then
    root="${2:-}"
    shift 2 2>/dev/null || true
  fi

  if [[ -z "$root" ]]; then
    log "BLOCKED no --root given: refusing to delete $*"
    echo "{\"deleted\":0,\"failed\":0,\"bytes_freed\":0,\"freed_fmt\":\"0B\",\"error\":\"missing --root\"}" >&2
    return 2
  fi

  local root_real
  root_real=$(canonical_path "$root" 2>/dev/null) || root_real=""
  if [[ -z "$root_real" || ! -d "$root_real" ]]; then
    log "BLOCKED unusable --root: $root"
    echo "{\"deleted\":0,\"failed\":0,\"bytes_freed\":0,\"freed_fmt\":\"0B\",\"error\":\"unusable --root\"}" >&2
    return 2
  fi

  # ~/.claude is authorized ONLY for depth-1 config backups (KTD6). It must never become a
  # recursive delete license over ~/.claude/logs, settings.json, or projects/.
  local backup_only="false"
  local claude_real
  claude_real=$(canonical_path "$HOME/.claude" 2>/dev/null) || claude_real=""
  if [[ -n "$claude_real" && "$root_real" == "$claude_real" ]]; then
    backup_only="true"
  fi

  local deleted=0 failed=0 bytes_freed=0
  local filepath

  for filepath in "$@"; do
    [[ -z "$filepath" ]] && continue

    if [[ ! -e "$filepath" && ! -L "$filepath" ]]; then
      failed=$((failed + 1))
      log "Failed to delete (missing): $filepath"
      continue
    fi

    local real
    real=$(canonical_path "$filepath" 2>/dev/null) || real=""
    if [[ -z "$real" ]]; then
      log "BLOCKED unresolvable path: $filepath"
      failed=$((failed + 1))
      continue
    fi

    # Strictly UNDER root. A symlink that resolves outside root is refused here.
    if [[ "$real" != "$root_real"/* ]]; then
      log "BLOCKED out-of-root: $filepath (resolves to $real, root $root_real)"
      failed=$((failed + 1))
      continue
    fi

    if [[ "$backup_only" == "true" ]]; then
      local parent base
      parent=$(dirname "$real")
      base=$(basename "$real")
      if [[ "$parent" != "$root_real" ]]; then
        log "BLOCKED not a direct child of root: $filepath"
        failed=$((failed + 1))
        continue
      fi
      case "$base" in
        *.backup*|*.bak) : ;;
        *)
          log "BLOCKED not a config backup: $filepath"
          failed=$((failed + 1))
          continue
          ;;
      esac
    fi

    if is_safe "$filepath"; then
      log "BLOCKED safe pattern: $filepath"
      failed=$((failed + 1))
      continue
    fi

    if is_recent "$filepath"; then
      log "BLOCKED recent file: $filepath"
      failed=$((failed + 1))
      continue
    fi

    local fsize=0
    if [[ -f "$filepath" && ! -L "$filepath" ]]; then
      fsize=$(stat -f %z "$filepath" 2>/dev/null || echo "0")
    elif [[ -d "$filepath" ]]; then
      fsize=$(du -sk "$filepath" 2>/dev/null | awk '{print $1 * 1024}' || echo "0")
    fi
    [[ -z "$fsize" ]] && fsize=0

    if rm -rf "$filepath" 2>/dev/null; then
      deleted=$((deleted + 1))
      bytes_freed=$((bytes_freed + fsize))
      log "Deleted: $filepath ($fsize bytes)"
    else
      failed=$((failed + 1))
      log "Failed to delete: $filepath"
    fi
  done

  local freed_fmt
  if (( bytes_freed >= 1048576 )); then
    freed_fmt="$(( bytes_freed / 1048576 ))M"
  elif (( bytes_freed >= 1024 )); then
    freed_fmt="$(( bytes_freed / 1024 ))K"
  else
    freed_fmt="${bytes_freed}B"
  fi

  echo "{\"deleted\":$deleted,\"failed\":$failed,\"bytes_freed\":$bytes_freed,\"freed_fmt\":\"$freed_fmt\"}"
}

setup_launchagent() {
  local script_path
  script_path="$(cd "$(dirname "$0")" && pwd)/crush.sh"

  cat > "$LAUNCHAGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCHAGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${script_path}</string>
        <string>cron</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>StandardOutPath</key>
    <string>${HOME}/.claude/logs/clawcrush-launchd.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/.claude/logs/clawcrush-launchd.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST

  launchctl bootstrap "gui/$(id -u)" "$LAUNCHAGENT_PLIST" 2>/dev/null || launchctl load "$LAUNCHAGENT_PLIST" 2>/dev/null || true
  echo "{\"status\":\"installed\",\"plist\":\"$LAUNCHAGENT_PLIST\",\"interval\":3600,\"mode\":\"report-only\"}"
}

# ── Cron mode (REPORT-ONLY dry run) ────────────

# This used to SIGTERM every scanned pid with no confirmation and errors swallowed by `|| true`
# (F2). Combined with the age-alone predicate (F1) that was an hourly mass-kill of every live
# session's MCP servers. It is now report-only and kills nothing. Re-arming is out of scope.
do_cron() {
  local count=0
  local row pid ppid age_mins age_fmt name pattern classification orphan owner session reason

  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    IFS='|' read -r pid ppid age_mins age_fmt name pattern classification orphan owner session reason <<< "$row"

    # Cron is unattended and has no consent path, so it may only ever consider genuine orphans
    # past the age gate — the same posture fullcream has. consent_required and protected
    # candidates are dropped from the log entirely, not merely left unkilled.
    [[ "$classification" != "safe_kill" ]] && continue
    (( age_mins < MIN_AGE_MINUTES )) && continue

    log "Cron dry-run: would-kill pid $pid name=$name age=$age_fmt owner=${owner:-unknown} reason=$reason"
    count=$((count + 1))
  done < <(zombie_rows "")

  log "Cron dry-run: $count safe_kill candidate(s) past the age gate; killed 0 (report-only)"
}

# ── Main dispatch ──────────────────────────────

case "$ACTION" in
  scan)
    flag="${1:-}"
    scan_root=$(current_scan_root)
    if [[ "$flag" == "--global" ]]; then
      zombies=$(scan_zombies "$scan_root")
      ports=$(scan_ports "$scan_root")
      global=$(scan_global)
      echo "{\"scan_root\":\"$(json_escape "$scan_root")\",\"zombies\":$zombies,\"ports\":$ports,\"global\":$global}"
    else
      zombies=$(scan_zombies "$scan_root")
      ports=$(scan_ports "$scan_root")
      slop=$(scan_slop ".")
      echo "{\"scan_root\":\"$(json_escape "$scan_root")\",\"zombies\":$zombies,\"ports\":$ports,\"slop\":$slop}"
    fi
    ;;
  contention)
    scan_root=$(current_scan_root)
    scan_contention "$scan_root"
    ;;
  grace-for)
    # Seam: the class->grace selection, testable without killing anything.
    grace_for_window "${1:-}"
    echo ""
    ;;
  classify)
    # Read-only introspection seam: exposes the classifier for any pid, so the kill matrix is
    # directly testable rather than only observable through a scan's pattern list.
    pid="${1:-}"
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
      echo "Usage: crush.sh classify <pid> [scan_root]" >&2
      exit 1
    fi
    root="${2:-$(current_scan_root)}"
    cls=$(classify_pid "$pid" "$root")
    IFS='|' read -r classification orphan owner session reason <<< "$cls"
    owner_json="null"; [[ -n "$owner" ]] && owner_json="\"$(json_escape "$owner")\""
    session_json="null"; [[ -n "$session" ]] && session_json="$session"
    [[ -z "$orphan" ]] && orphan="false"
    echo "{\"pid\":$pid,\"classification\":\"$classification\",\"orphan\":$orphan,\"owner_worktree\":$owner_json,\"owning_session\":$session_json,\"reason\":\"$(json_escape "$reason")\"}"
    ;;
  kill)
    do_kill "$@"
    ;;
  delete)
    do_delete "$@"
    ;;
  setup-launchagent)
    setup_launchagent
    ;;
  cron)
    do_cron
    ;;
  *)
    echo "Usage: crush.sh {scan [--global] | contention | classify <pid> | kill [--consent <pid>]... <pids...> | delete --root <path> <files...> | setup-launchagent | cron}" >&2
    exit 1
    ;;
esac
