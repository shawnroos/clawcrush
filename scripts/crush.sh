#!/bin/bash

# ClawCrush Scanner Engine
# Outputs JSON for process zombies and repo slop.
# The Claude agent handles UX — this script is a pure data source + executor.
#
# Usage:
#   crush.sh scan [--global]                  — scan CWD (or global) for zombies + slop
#   crush.sh contention                       — READ-ONLY load-contention report
#   crush.sh classify <pid> [scan_root]       — report one pid's classification (read-only)
#   crush.sh session-re <command line>        — is this a live-claude session shape? (read-only)
#   crush.sh kill [--consent <pid>]... <pid>… — kill processes, enforcing the kill matrix
#   crush.sh delete --root <path> <file>...   — delete files, contained under <root>
#   crush.sh setup-launchagent                — install/verify hourly LaunchAgent
#   crush.sh cron                             — REPORT-ONLY dry run: logs would-kill candidates
#
# CRON IS REPORT-ONLY. It kills nothing. Every line it emits is prefixed `Cron dry-run:`.
#
# SAFETY MODEL — age is never sufficient to call a process a zombie. Two axes decide:
#   liveness  — ppid == 1 AND NOT a daemon. ppid==1 alone is NOT orphanhood: launchd-managed jobs
#               and self-daemonizing session hosts (tmux, screen, pm2) are ppid==1 for their whole
#               life. Daemonhood is decided by POSITIVE signals (launchctl membership, a session-
#               host name, a live-claude command shape) — never by inferring it from the cwd.
#   ownership — owning worktree (lsof cwd -> git toplevel) AND owning claude session. A live
#               session that is not MINE outranks the worktree — sessions share repo roots.
#
#                        | orphan (ppid=1)        | attached (live parent)
#   ---------------------+------------------------+------------------------------
#   my worktree          | safe_kill              | consent_required
#   another worktree     | safe_kill (+ reported) | protected — NEVER KILL
#   another live session | safe_kill              | protected — NEVER KILL (any worktree)
#   owner unknown        | see below              | consent_required (fail closed)
#
# "owner unknown + orphan" splits on the session-child signature:
#   named MCP server / dev-stack process  -> safe_kill (its session is provably gone)
#   cwd was resolved but has been DELETED -> safe_kill (the worktree it lived in is gone)
#   generic runtime, cwd exists, no owner -> protected (launchd/daemon shape; never killed)
#   cwd unreadable at all                 -> protected (fail closed)
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

# Generic runtimes: only ever candidates when ALREADY orphaned (ppid=1) AND old AND owned by a
# resolvable worktree (see classify_pid's daemon guard). They carry NO session-child signature, so
# ppid==1 on one of them is not evidence of abandonment on its own.
#
# The capitalized entries are the REAL macOS executable names — `/Applications/Google Chrome.app/
# Contents/MacOS/Google Chrome`, not `chrome`. Matching is case-sensitive (window_matches_pattern),
# so the lowercase entries alone made the single most common leaked-browser shape on macOS
# invisible to the scanner, while BROWSER_CLASS_PATTERNS below already used the real names — the
# two lists disagreed about what a browser is called, and the one gating KILL CANDIDACY had it
# wrong. The lowercase forms are kept for Linux/CI shapes.
#
# These names are only safe to carry here BECAUSE of the daemon guard: a Dock-launched Google
# Chrome is ppid==1 for its entire life. Under a bare `orphan <=> ppid==1` rule, listing it here
# would make the user's actual browser safe_kill and fullcream would close it.
ORPHAN_RUNTIME_PATTERNS=(
  "node"
  "bun"
  "chromium"
  "chrome"
  "Chromium"
  "Google Chrome"
  "Google Chrome Helper"
)

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
#
# The previous pattern required `claude` to be followed by whitespace or end-of-string, so it
# matched the pty-host WRAPPER (".../MacOS/claude --bg-pty-host …") but NOT the agent process that
# actually spawns MCP servers, whose command window is a bare PATH:
#
#   /Users/x/.local/share/claude/versions/2.1.207     ← `claude` is followed by `/`. NO MATCH.
#
# For an interactive session that was survivable — the walk continued past the agent and hit the
# wrapper. But a swarm/subagent session (`versions/2.1.207 --agent-id …`) is parented by tmux, so
# the version binary is the ONLY claude process in the chain and the walk fell through to ppid 1.
# Measured on this machine: 46 of 76 live MCP servers reported owning_session:null. The session
# axis was dead for exactly the processes it exists to attribute.
#
# So: match `claude` as a path COMPONENT (allowing a trailing `/`), plus the version-binary shape.
# Over-matching here is safe by construction — a spurious session hit only ever moves a process
# toward `protected` (see classify_pid), never toward safe_kill.
#
# Verified live shapes (all four are pinned by a table-driven runtime test):
#   /Users/x/.local/share/claude/versions/2.1.207
#   /Users/x/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude --bg-pty-host …
#   /Users/x/.local/bin/claude daemon run …
#   claude bg-pty-host …
CRUSH_SESSION_RE=${CRUSH_SESSION_RE:-'(^|[/[:space:]])claude([/[:space:]]|$)|/share/claude/versions/'}

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

# SESSION HOSTS — process supervisors that HOST other people's live work. Refused unconditionally,
# exactly like NEVER_KILL_PATTERNS, and for a stronger reason: killing one takes down every session
# inside it.
#
# These exist because ppid==1 is a LIFECYCLE fact, not an abandonment fact, and the previous
# discriminator ("a daemon's cwd is never a git worktree") is simply false for this class. Verified
# live on this machine: the claude-swarm tmux servers (`tmux -L claude-swarm-… new-session …`) are
# ppid==1 for their entire life — tmux daemonizes by design, so launchd is their INTENDED parent —
# and their cwd resolves to the worktree the swarm was launched from. That satisfied
# `orphan && owner != ""`, so classify_pid returned safe_kill and `crush.sh kill <pid>` would have
# SIGTERMed a tmux server with live Claude sessions inside it.
#
# Membership is by NAME, checked on the command window, and it short-circuits BEFORE any cwd is
# consulted. That is the point: cwd is not a sound liveness discriminator, so the fix cannot be
# another cwd rule. `screen`, `pm2` and `sshd` are the same shape (self-daemonizing supervisors of
# other people's sessions); `launchd` itself is here so pid 1 can never be named.
#
# CRUSH_EXTRA_PATTERNS cannot unlock these — the denylist is checked before the pattern lists, so
# putting `tmux` in the scan's pattern list makes it VISIBLE, never killable.
SESSION_HOST_PATTERNS=(
  "tmux"
  "tmux-server"
  "screen"
  "zellij"
  "sshd"
  "pm2"
  "PM2"
  "launchd"
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

# JSON string escaping: backslashes FIRST, then quotes (F7), then the C0 control range.
#
# The old form ended in `tr -d '\n'`, which STRIPPED newlines instead of escaping them, and passed
# every other control character through raw. Both are corruption, not cosmetics:
#   - a raw control char in ONE filename makes the ENTIRE scan document invalid JSON, and every
#     command mode that parses it goes blind;
#   - a stripped newline means the emitted path is a DIFFERENT STRING than the real filename — a
#     delete target that no longer names the file that was scanned.
# `git ls-files -z` hands us both shapes verbatim, so neither is hypothetical.
#
# Builtins only, no forks. The old version forked sed AND tr on every call, and this is the hot
# path (several calls per process row, on a box whose defining condition is that it is contended).
# The fast path — no backslash, no quote, no control char — is the overwhelming majority and now
# costs zero subshells.
json_escape() {
  local s="$1"
  if [[ "$s" != *\\* && "$s" != *\"* && ! "$s" =~ [[:cntrl:]] ]]; then
    printf '%s' "$s"
    return 0
  fi

  local out="" i c esc n=${#s}
  for (( i = 0; i < n; i++ )); do
    c="${s:i:1}"
    case "$c" in
      '\')      out="$out\\\\" ;;
      '"')      out="$out\\\"" ;;
      $'\t')    out="$out\\t" ;;
      $'\n')    out="$out\\n" ;;
      $'\r')    out="$out\\r" ;;
      $'\b')    out="$out\\b" ;;
      $'\f')    out="$out\\f" ;;
      *)
        if [[ "$c" =~ [[:cntrl:]] ]]; then
          # Any remaining C0 char: \u00XX. JSON forbids these raw inside a string.
          printf -v esc '\\u%04x' "'$c"
          out="$out$esc"
        else
          out="$out$c"
        fi
        ;;
    esac
  done
  printf '%s' "$out"
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
# ── POLARITY (same rule as holds_listening_socket). ──
# This predicate's job is to PREVENT a deletion, so returning 0 ("recent") is the SAFE answer and
# every uncertain path must take it. It used to do the opposite, in both branches:
#   - `stat -f %m … || echo 0` turned a stat FAILURE into epoch 0, i.e. "modified in 1970", i.e.
#     maximally old, i.e. DELETE IT. An unreadable mtime is the one case where you least want that.
#   - `find … | grep -q .` cannot distinguish "find errored" from "nothing recent", so a permission
#     error read as "not recent" -> DELETE IT.
# Unknowns must fail closed (CLAUDE.md, hardcoded). An unknown mtime is not evidence of age.
is_recent() {
  local filepath="$1"
  local mins="${2:-$RECENT_MINUTES}"

  # A directory is judged by its NEWEST CONTENT, not its own mtime (F7: a dir's mtime does not move
  # when a file inside it is written, and every SLOP_DIRS entry is a directory — the guard was
  # weakest exactly where deletion is recursive).
  if [[ -d "$filepath" ]]; then
    local found rc=0
    found=$(find "$filepath" -mmin "-${mins}" -print 2>/dev/null | head -1) || rc=$?
    [[ -n "$found" ]] && return 0          # something recent inside -> recent
    (( rc != 0 )) && return 0              # find errored -> unknown -> assume recent
    return 1                               # clean walk, nothing recent
  fi

  local mod_epoch="" now_epoch age_mins
  if [[ "$(uname)" == "Darwin" ]]; then
    mod_epoch=$(stat -f %m "$filepath" 2>/dev/null) || mod_epoch=""
  else
    mod_epoch=$(stat -c %Y "$filepath" 2>/dev/null) || mod_epoch=""
  fi

  # Unreadable/absent mtime -> the question was not answered -> assume recent, refuse the delete.
  [[ "$mod_epoch" =~ ^[0-9]+$ ]] || return 0

  now_epoch=$(date +%s)
  age_mins=$(( (now_epoch - mod_epoch) / 60 ))

  # A future mtime (clock skew, a touched-forward file) is not evidence of age either.
  (( age_mins < 0 )) && return 0

  (( age_mins < mins ))
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

# Does the command window contain PATTERN as a whole command/path COMPONENT?
#
# SINGLE source of truth for every pattern -> KILL-CANDIDACY decision (zombie_rows, both its
# pattern lists, and scan_contention). Bare substring matching inside the window is a
# kill-candidacy bug, not a cosmetic one: an orphaned `/bin/bash /tmp/invitee-app/start.sh` — a
# path that merely CONTAINS the letters of `vite` — matched the DEV pattern and classified
# safe_kill, which fullcream then kills with no human in the loop. That is the same defect class
# as F7 ("the command line merely contains playwright-mcp"), one level in: F7 windowed the match
# to the command HEAD, but within the head it was still a substring.
#
# A boundary here is any character that cannot be part of an identifier: [^[:alnum:]_-]. Slashes,
# spaces, dots, '@' and ':' all qualify, so real invocations still hit —
#   /x/node_modules/vite/bin/vite.js   ✓ vite
#   npx chrome-devtools-mcp@latest     ✓ chrome-devtools-mcp
#   /x/.bin/ng serve                   ✓ ng serve
#   /Applications/…/Google Chrome for Testing   ✓ Google Chrome for Testing
# while a word that merely contains the pattern does not —
#   /tmp/invitee-app/start.sh          ✗ vite      (preceded by 'n')
#   /x/bin/vitest                      ✗ vite      (followed by 't')
#   /x/runner /tmp/invite_tool.py      ✗ vite
#
# `-` and `_` are deliberately identifier chars, NOT boundaries. Without that, `node` would match
# `node_modules` in essentially every JS command line on the machine, and `chrome` would match
# `chrome-devtools-mcp`. This is why the boundary class is not simply [^[:alnum:]].
#
# The pattern is QUOTED inside the =~, so bash 3.2 treats it as a literal string: patterns may
# contain regex metacharacters and spaces without any escaping.
window_matches_pattern() {
  local win="$1" p="$2"
  [[ -n "$p" ]] || return 1
  [[ "$win" =~ (^|[^[:alnum:]_-])"$p"([^[:alnum:]_-]|$) ]]
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

# Deliberately a bare SUBSTRING match, unlike window_matches_pattern. The boundary rule exists to
# stop a loose match from widening the KILL surface; here a loose match only ever widens the
# PROTECT surface. Over-matching costs a missed reclaim; under-matching corrupts a node_modules
# mid-install. Narrowing this to word boundaries would be a safety regression, not a cleanup.
matches_never_kill() {
  local window="$1" pat
  for pat in "${NEVER_KILL_PATTERNS[@]}"; do
    if [[ "$window" == *"$pat"* ]]; then
      return 0
    fi
  done
  return 1
}

# Is this command window a SESSION HOST (tmux/screen/pm2/sshd/launchd)? Boundary-matched, so
# `tmux` hits `/opt/homebrew/bin/tmux -L …` and `screen` does not hit `screencapture`. Widening
# this only ever widens the PROTECT surface, so it is the safe direction to err in.
matches_session_host() {
  local win="$1" p
  for p in "${SESSION_HOST_PATTERNS[@]}"; do
    if window_matches_pattern "$win" "$p"; then return 0; fi
  done
  return 1
}

# THE PATTERN SPLIT. `matches_specific_pattern` lumped MCP_PATTERNS and DEV_PATTERNS together and
# read a hit as "this can only be a session's child, so ppid==1 proves the session died". That
# premise is true for ONE of the two lists and false for the other:
#
#   MCP_PATTERNS — an MCP server exists only ever as a claude session's child. Nobody launches one
#                  detached. ppid==1 really does mean the session that owned it is gone.
#   DEV_PATTERNS — `nohup npm run start:dev1 > log 2>&1 < /dev/null & disown` is the DOCUMENTED way
#                  dev servers are launched in these worktrees (the harness reaps non-detached
#                  ones). So a dev server is ppid==1 FROM BIRTH, and the premise is simply false.
#
# Verified live: pid 23675 `npm exec ng serve --configuration=dev --port 3007`, ppid==1, 4h15m old,
# child 23709 holding `127.0.0.1:3007 (LISTEN)` — classified safe_kill off the shared premise.
matches_mcp_pattern() {
  local win="$1" p
  for p in "${MCP_PATTERNS[@]}"; do
    if window_matches_pattern "$win" "$p"; then return 0; fi
  done
  return 1
}

# CRUSH_EXTRA_PATTERNS is a harness seam, and its fixtures are dev-stack shaped — so it lands in the
# dev bucket, behind the veto, rather than inheriting the MCP list's stronger premise.
matches_dev_pattern() {
  local win="$1" p
  for p in "${DEV_PATTERNS[@]}"; do
    if window_matches_pattern "$win" "$p"; then return 0; fi
  done
  if [[ -n "${CRUSH_EXTRA_PATTERNS:-}" ]]; then
    local oldifs="$IFS"
    IFS=':'
    for p in $CRUSH_EXTRA_PATTERNS; do
      if [[ -n "$p" ]] && window_matches_pattern "$win" "$p"; then
        IFS="$oldifs"
        return 0
      fi
    done
    IFS="$oldifs"
  fi
  return 1
}

# AUTOMATION BROWSER — a CONJUNCTION over the raw command, and the only place in this file that is
# allowed to read flags.
#
# The generic-runtime category (`chrome`, `node`, `bun`) cannot authorize a kill: a bare `chrome` at
# ppid==1 is indistinguishable from the user's Dock-launched browser, and a bare `node` could be a
# build watcher, an MCP server, or agent-browser. But a LEAKED automation browser is real toil, and
# dropping it entirely would leave U2 unable to see the thing it was built for.
#
# `command_window` stops at the first `-` token by design (F7: matching on the full ps line lets any
# process whose ARGS merely mention a pattern get flagged), so `--headless` is invisible to every
# pattern list — putting it in DEV_PATTERNS is dead code, which is exactly the trap this comment
# exists to stop the next person falling into. It has to be read off the raw command.
#
# Why this conjunction is sound where a bare flag match would not be:
#   - The window must ALREADY be a browser, so `nvim --headless` (a real scripting idiom) cannot hit.
#   - `--headless` specifically. NOT `--remote-debugging-port`: the user's own Chrome carries that
#     one, so keying on it would classify their real browser safe_kill.
#   - A Dock-launched browser is never headless. There is no path from this predicate to the user's
#     actual browsing session.
matches_automation_browser() {
  local win="$1" raw="$2" p
  local is_browser=1
  for p in "chromium" "Chromium" "chrome" "Google Chrome"; do
    if window_matches_pattern "$win" "$p"; then is_browser=0; break; fi
  done
  (( is_browser == 0 )) || return 1
  [[ "$raw" == *"--headless"* ]]
}

# pid_tree_of <pid> -> "<pid> <child> <grandchild> …"
#
# The veto below MUST look at descendants, not just the subject. The live counterexample is exactly
# this shape: pid 23675 is the `npm exec` wrapper and holds no socket at all — its child 23709 is
# the node process holding 127.0.0.1:3007. Vetoing on the subject alone would have missed it and
# killed the wrapper, taking the server with it.
#
# bash 3.2: no associative arrays, so this walks one `ps` snapshot breadth-first with space-padded
# string membership. Depth-bounded against a pid-reuse cycle.
pid_tree_of() {
  local root="$1"
  local snapshot frontier=" $root " all=" $root " next child parent depth=0
  snapshot=$(ps -o pid=,ppid= -ax 2>/dev/null || true)
  while [[ -n "${frontier// /}" ]] && (( depth < 12 )); do
    next=""
    while read -r child parent; do
      [[ -z "$child" || -z "$parent" ]] && continue
      case "$frontier" in
        *" $parent "*)
          case "$all" in
            *" $child "*) ;;
            *) all="$all$child "; next="$next$child " ;;
          esac
          ;;
      esac
    done <<< "$snapshot"
    frontier=" $next"
    depth=$((depth + 1))
  done
  printf '%s' "$all"
}

# THE LIVENESS VETO. A process (or any descendant) holding a LISTENING TCP socket is, by definition,
# serving someone — so it is not abandoned, whatever its ppid says.
#
# This is a BEHAVIOURAL signal, and that is the whole point. Rounds 2 and 3 both tried to carve out
# daemons by NAME (a cwd rule, then a session-host list), and both failed on the first daemon nobody
# had thought to enumerate. "Is it serving traffic right now?" is a question about the process
# itself, so it holds for daemons that are not on any list — including ones that do not exist yet.
#
# Only consulted for orphaned dev-stack candidates, so the lsof cost is bounded to a handful of pids
# on a box whose defining condition is that it is already contended.
#
# ── POLARITY. Read this before touching anything below. ──
# This predicate's job is to PREVENT a kill, so its uncertain paths must resolve to "assume it is
# serving" (return 0). Every `return 1` is a claim of PROOF that nothing is listening. Getting this
# backwards does not make the veto weaker — it silently deletes it.
#
# It was backwards on arrival, and it undid the entire commit it shipped in:
#
#   lsof -nP … -p "$plist" | grep -q LISTEN
#
# `lsof` exits 1 if ANY pid in -p is not found — EVEN WHEN it successfully printed the LISTEN lines.
# Under this file's `set -o pipefail` (line 42), the pipeline takes lsof's status, not grep's, so the
# LISTEN line is found and then thrown away. Reproduced against a real listener (pid 747):
#   lsof PRINTED a LISTEN line? YES     lsof EXIT status: 1
#   veto as written (pipefail on)  -> FAILS OPEN -> safe_kill
#   identical call, pipefail off   -> fires      -> protected
# Two triggers, one root cause: (a) an unreaped zombie child, and (b) a pid_tree_of snapshot race —
# `ps` snapshots the tree, `lsof` runs later, and any descendant exiting in that window is enough. A
# dev-server tree spawns short-lived children constantly, so (b) is an intermittent SIGTERM of a live
# server that no deterministic test would ever reproduce.
#
# So: trust what lsof PRINTED, never its exit status, and fail closed on every ambiguity.
holds_listening_socket() {
  local tree plist out rc=0
  tree=$(pid_tree_of "$1")
  plist=$(printf '%s' "$tree" | sed 's/^ *//; s/ *$//; s/  */,/g')

  # Unknown tree — cannot prove abandonment, so assume it is serving.
  [[ -z "$plist" ]] && return 0

  # No lsof — cannot prove abandonment. Not a live defect under the shipped LaunchAgent (launchd's
  # default PATH is /usr/bin:/bin:/usr/sbin:/sbin and lsof is /usr/sbin/lsof), but the blast radius
  # if it ever went missing is total: set_pid_cwd would fail too, every dev-pattern orphan would
  # reach this veto with no owner, and a fail-open veto turns that into a mass safe_kill.
  command -v lsof >/dev/null 2>&1 || return 0

  # DO NOT reintroduce `-p "$plist"`. `lsof` exits 1 for BOTH "a pid in -p was not found" AND "no
  # matching open files", and those two are indistinguishable from the exit status alone. That
  # ambiguity has no safe resolution: treating rc!=0 as "not listening" fails OPEN and kills a live
  # server (the pipefail bug); treating it as "serving" fails CLOSED on every socket-less process
  # and silently drops recall to zero — a veto that protects everything is a feature that does
  # nothing. The recall control in u2 catches the second, which is how this was found.
  #
  # So never ask lsof about specific pids. Ask it for ALL listeners — a query that does not depend
  # on any pid still existing — and look our tree up in the answer. A descendant exiting mid-flight
  # cannot make this call error, which also closes the pid_tree_of snapshot race at the source.
  out=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null) || rc=$?

  # No output at all means lsof failed or is lying (a box with zero listeners is implausible here).
  # Unanswered question -> assume serving.
  if [[ -z "$out" ]]; then
    return 0
  fi

  # lsof's own COMMAND column can contain spaces ("Google Chrome"), so this reads the PID by field
  # position off a known-good header, not by parsing the command.
  local listeners lp
  listeners=$(printf '%s\n' "$out" | awk 'NR > 1 { print $2 }' | sort -u)
  for lp in $listeners; do
    case "$plist" in
      "$lp"|"$lp,"*|*",$lp"|*",$lp,"*) return 0 ;;
    esac
  done

  # lsof answered, and nothing in our tree is in it. The only path that has proven a negative.
  return 1
}

# LAUNCHD MEMBERSHIP — the positive signal the old daemon guard was trying to INFER from the cwd.
#
# `launchctl list` prints `PID<TAB>Status<TAB>Label` for every job launchd manages in this user's
# domain — brew services, user LaunchAgents, login items. A pid in that list has launchd as its
# LIVE, MANAGING parent; its ppid==1 is its steady state, not the residue of a dead session. That
# is precisely the property the guard needs, read directly instead of guessed.
#
# (`launchctl procinfo <pid>` would be the more direct query but it requires root, so it is
# unusable from a user-context LaunchAgent — which is the exact context that matters here.)
#
# Computed ONCE, EAGERLY, at load — deliberately not lazily inside is_launchd_managed. classify_pid
# runs inside a `$( )` command substitution (zombie_rows, scan_ports, do_kill all call it that way),
# so a lazy cache would live in a subshell and die with it: launchctl would be re-forked for EVERY
# candidate on a box whose defining condition is that it is already contended. Same reason
# OWN_ANCESTORS is computed here. ~60ms, once.
#
# Failure (no launchctl, empty domain, Linux) leaves the set empty — the session-host denylist and
# the daemon guard still stand behind it.
LAUNCHD_PIDS=""
compute_launchd_pids() {
  LAUNCHD_PIDS=" $(launchctl list 2>/dev/null | awk '$1 ~ /^[0-9]+$/ { printf "%s ", $1 }' 2>/dev/null || true)"
}
compute_launchd_pids

is_launchd_managed() {
  [[ "$LAUNCHD_PIDS" == *" $1 "* ]]
}

# Does this window carry a SESSION-CHILD signature — a named MCP server, or a dev-stack process?
#
# This is the discriminator the daemon guard in classify_pid turns on. A named MCP server or an
# `ng test` is, by construction, spawned BY a Claude session and inherits its cwd; ppid==1 on one
# of those really does mean the session that owned it is gone. A generic runtime (node, bun, a
# browser) carries no such signature — it is equally likely to be a launchd-managed service that
# has had ppid==1 since boot.
matches_specific_pattern() {
  local win="$1" p
  for p in "${MCP_PATTERNS[@]}"; do
    if window_matches_pattern "$win" "$p"; then return 0; fi
  done
  for p in "${DEV_PATTERNS[@]}"; do
    if window_matches_pattern "$win" "$p"; then return 0; fi
  done
  if [[ -n "${CRUSH_EXTRA_PATTERNS:-}" ]]; then
    local oldifs="$IFS"
    IFS=':'
    for p in $CRUSH_EXTRA_PATTERNS; do
      if [[ -n "$p" ]] && window_matches_pattern "$win" "$p"; then
        IFS="$oldifs"
        return 0
      fi
    done
    IFS="$oldifs"
  fi
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

# A process's cwd, and — critically — WHICH KIND of failure we got when it does not resolve.
#
# The old code collapsed three distinct states into one "owner unknown", and that conflation is
# what made the daemon guard both over- and under-shoot:
#
#   ok      — lsof gave a path and it EXISTS. Ownership is knowable.
#   gone    — lsof gave a path and it NO LONGER EXISTS on disk. That is ABANDONMENT evidence, not
#             daemon evidence: a daemon's cwd is `/` or its install dir and those do not get
#             deleted, whereas an MCP server whose worktree was removed by `wtc` after a PR merged
#             is left holding a dangling cwd. That is the single most common leak shape on this
#             machine, and the old guard classified it `protected` — permanently unkillable, the
#             exact target clawcrush exists to reclaim, made invisible by a safety-looking rule.
#   unknown — lsof gave nothing at all (permissions, a race, no lsof). Fail closed.
#
# (Verified on macOS: for a deleted cwd, lsof still prints the original path verbatim with no
# marker, so `-d` on the returned path is what separates `gone` from `ok`.)
_CWD_PATH=""
_CWD_STATE="unknown"
set_pid_cwd() {
  local cwd
  _CWD_PATH=""
  _CWD_STATE="unknown"
  cwd=$(lsof -a -p "$1" -d cwd -Fn 2>/dev/null | grep '^n' | head -1 | sed 's/^n//') || cwd=""
  [[ -n "$cwd" ]] || return 1
  _CWD_PATH="$cwd"
  if [[ -d "$cwd" ]]; then _CWD_STATE="ok"; else _CWD_STATE="gone"; fi
  return 0
}

# The worktree that owns a process, via its cwd. Fails when unresolvable — and unresolvable
# always means "fail closed", never "assume mine".
owner_worktree_of() {
  local top
  set_pid_cwd "$1" || return 1
  [[ "$_CWD_STATE" == "ok" ]] || return 1
  top=$(worktree_of "$_CWD_PATH") || return 1
  printf '%s' "$top"
}

# classify_pid <pid> [scan_root] -> classification|orphan|owner_worktree|owning_session|reason
#
# The kill matrix, in one place, computed at scan time AND re-derived at act time. Every guard
# below lives HERE and not in the callers, because `crush.sh kill <pid>` is reachable by the
# command layer with an arbitrary pid — a guard that only gates DETECTION (zombie_rows) leaves the
# act path wide open to a drifted or hallucinating caller.
#
#                        | orphan (ppid=1)        | attached (live parent)
#   ---------------------+------------------------+------------------------------
#   my worktree          | safe_kill              | consent_required
#   another worktree     | safe_kill (+ reported) | protected — NEVER KILL
#   another live session | safe_kill              | protected — NEVER KILL (any worktree)
#   owner unknown        | signature-dependent    | consent_required (fail closed)
#
# Own process tree, the never-kill allowlist, the daemon guard and the foreign-session guard are
# not four features — they are the same predicate, short-circuiting to protected.
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

  # SESSION HOSTS. A tmux/screen/pm2/sshd server hosts other people's live work, and it is ppid==1
  # for its entire life BY DESIGN. Refused unconditionally, before any cwd is consulted — because
  # cwd is exactly the signal that gets this class wrong (the claude-swarm tmux servers on this
  # machine have a cwd that IS a git worktree, which made them safe_kill).
  if matches_session_host "$win"; then
    printf 'protected|false|||session host (tmux/screen/pm2/sshd) — hosts live sessions, never killed'
    return 0
  fi

  # THE SUBJECT PID IS ITSELF A LIVE CLAUDE SESSION OR THE DAEMON.
  #
  # CRUSH_SESSION_RE was applied only to ANCESTORS (owning_session_of starts at the PARENT), so the
  # model had no rule at all about a process that IS a session. `claude daemon run` classified
  # protected only INCIDENTALLY, because its cwd happens not to resolve to a git repo — change that
  # accident (a session or daemon whose cwd is a worktree) and the process at the top of the session
  # tree came back safe_kill. The one signal that identifies these processes was never consulted
  # about the subject.
  #
  # Over-matching here is safe by the same argument the regex already makes for itself: a spurious
  # session hit only ever moves a process toward `protected`.
  if [[ "$win" =~ $CRUSH_SESSION_RE ]]; then
    printf 'protected|false|||is itself a live claude session/daemon — never killed'
    return 0
  fi

  ppid=$(pid_ppid "$pid" 2>/dev/null) || ppid=""
  if [[ "$ppid" == "1" ]]; then orphan="true"; else orphan="false"; fi

  # NOT in a subshell: classify_pid needs _CWD_STATE, and $( ) would discard it.
  set_pid_cwd "$pid" 2>/dev/null || true
  owner=""
  if [[ "$_CWD_STATE" == "ok" ]]; then
    owner=$(worktree_of "$_CWD_PATH" 2>/dev/null) || owner=""
  fi
  local cwd_state="$_CWD_STATE"
  session=$(owning_session_of "$pid" 2>/dev/null) || session=""

  if [[ "$orphan" == "true" ]]; then
    # THE DAEMON GUARD. ppid==1 is NECESSARY for orphanhood but never SUFFICIENT.
    #
    # launchd-managed jobs (brew services, user LaunchAgents) and self-daemonized processes run
    # with ppid==1 for their ENTIRE LIFE — launchd is their designed parent, not the residue of a
    # dead one. A bare `orphan <=> ppid==1` rule therefore reads a healthy system service as an
    # abandoned one, and it is the SAME defect shape as F1: a signal that is a pure function of
    # process lifecycle rather than of abandonment.
    #
    # The guard used to infer daemonhood from the cwd ("a daemon's cwd is never a git worktree").
    # That discriminator is FALSE — verified live on the tmux servers hosting this machine's Claude
    # swarm sessions — and it was unsound in BOTH directions:
    #   false positive: a daemon whose cwd IS a worktree (tmux, a nohup'd server)   -> safe_kill
    #   false negative: an abandoned MCP server whose worktree was DELETED          -> protected
    # So daemonhood is now decided by POSITIVE signals only, and the cwd is used for what it can
    # actually testify to — ownership, and whether the directory still exists.
    #
    # Verified on this machine: powerd, usbaudiod, containermanagerd and the user's Dock-launched
    # Google Chrome are all ppid==1, and all four classified safe_kill before this guard existed.

    # (1) launchd MANAGES this pid. The positive form of the signal the cwd rule was guessing at.
    if is_launchd_managed "$pid"; then
      printf 'protected|true|%s|%s|launchd-managed job (launchctl list) — ppid=1 is its steady state, never killed' "$owner" "$session"
      return 0
    fi

    # ppid==1 ALONE NEVER KILLS. It is necessary, never sufficient — a pid reaches this point only
    # by then producing a POSITIVE signal that it was abandoned.
    #
    # This inverted after the third consecutive review round found the same defect. The guard used
    # to end with `owner != "" -> safe_kill`: an orphan with a resolvable owning worktree was read
    # as "an abandoned child still sitting in its worktree". That infers ABANDONMENT from
    # OWNERSHIP, which is round 2's cwd rule wearing a different hat, and the asymmetry gave it
    # away — `owner == ""` fell through to protected while `owner != ""` became safe_kill, so
    # having an identifiable owner made a process MORE killable. A cwd can testify to who owns a
    # process. It can never testify to whether that process was abandoned.
    #
    # Verified live: a self-daemonized `agent-browser` (pid 82997 — LISTENING on localhost:54172,
    # ESTABLISHED to its Chrome, live child, cwd in a sibling worktree) took that branch and came
    # back safe_kill, together with its Chrome. It is ppid==1 by design, is not launchd-managed,
    # and carries no session-host name — so no enumeration of daemons saw it. Enumerating daemons
    # is unbounded and had failed once per round; asking for positive proof of abandonment is not.
    #
    # So exactly two signals prove abandonment, and nothing else does:

    # (1) Its cwd RESOLVED and has since been DELETED — the worktree it was spawned in is gone, so
    #     nothing can still want it. The one signal in this file that is unambiguously about
    #     abandonment rather than lifecycle. This is the `wtc`-after-merge leak.
    if [[ "$cwd_state" == "gone" ]]; then
      printf 'safe_kill|true||%s|ppid=1 (orphaned), its cwd (%s) has been deleted — abandoned' \
        "$session" "$_CWD_PATH"
      return 0
    fi

    # (2) An MCP-server signature. These exist ONLY as a claude session's child and are never
    #     launched detached, so ppid==1 does prove the owning session is gone. See matches_mcp_pattern.
    if matches_mcp_pattern "$win"; then
      reason="ppid=1 (orphaned), MCP-server signature — its session is gone"
      [[ -n "$owner" ]] && reason="$reason, owner: $owner"
      printf 'safe_kill|true|%s|%s|%s' "$owner" "$session" "$reason"
      return 0
    fi

    # (3) A dev-stack signature, gated by the LIVENESS VETO. ppid==1 does NOT prove abandonment here
    #     — nohup+disown is the documented launch path — so the name alone cannot authorize a kill.
    #     Ask the process what it is DOING instead: serving traffic, or not.
    if matches_dev_pattern "$win" || matches_automation_browser "$win" "$cmd"; then
      if holds_listening_socket "$pid"; then
        reason="ppid=1 but it (or a child) holds a LISTENING socket — serving, never killed"
        [[ -n "$owner" ]] && reason="$reason, owner: $owner"
        printf 'protected|true|%s|%s|%s' "$owner" "$session" "$reason"
        return 0
      fi
      reason="ppid=1 (orphaned), dev-stack signature, holds no listening socket — finished/abandoned"
      [[ -n "$owner" ]] && reason="$reason, owner: $owner"
      printf 'safe_kill|true|%s|%s|%s' "$owner" "$session" "$reason"
      return 0
    fi

    # No positive abandonment signal. FAIL CLOSED — and `protected`, not `consent_required`, because
    # consent_required would still let lowfat put a live daemon in a table and kill it on a stray
    # selection. The cost is a false negative: an abandoned process whose name is in no pattern list
    # and whose worktree still exists survives, and leaks until its cwd goes away. That is the right
    # trade — a missed zombie costs RAM, a false positive SIGTERMs live work.
    reason="ppid=1 with no positive abandonment signal (live cwd, no session-child signature) — daemon shape, never killed"
    [[ -n "$owner" ]] && reason="$reason, owner: $owner"
    printf 'protected|true|%s|%s|%s' "$owner" "$session" "$reason"
    return 0
  fi

  # SESSION-GRANULAR OWNERSHIP. Worktree granularity is too coarse: N Claude sessions routinely
  # share one repo root, so "attached, and its worktree happens to be the one I am scanning from"
  # does NOT mean the process is mine. If a live owning session exists and it is not in MY ancestor
  # chain, the process belongs to somebody else's live session — protected, whatever the worktree
  # says. Computing `session` and then using it only to decorate `reason` (as this did) is the
  # documented-not-wired failure: the axis exists in the output and not in the decision.
  if [[ -n "$session" ]] && ! in_own_tree "$session"; then
    reason="attached to ANOTHER live claude session (pid $session)"
    [[ -n "$owner" ]] && reason="$reason, owner: $owner"
    printf 'protected|false|%s|%s|%s' "$owner" "$session" "$reason"
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
      if window_matches_pattern "$win" "$p"; then
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
        if window_matches_pattern "$win" "$p"; then
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

# lsof listeners, read from -F FIELD output rather than scraped columns.
#
# The columnar form is a display format, not an interface: COMMAND is a fixed 9-wide left column
# holding a name that can contain spaces (`Google Chrome`, `Google Chrome for Testing` — both are
# real listeners, and Chrome is the process holding the CDP port 9222 this scan exists to find).
# Any parse keyed on positional fields ($2 for pid, $9 for the address) is one lsof rendering
# quirk away from reading a command FRAGMENT as a pid and silently dropping the listener.
#
# -F emits one field per line, tagged: `p<pid>` opens a process record, `n<addr>` is a file's
# name. No columns, no widths, no truncation, no escaping to undo.
scan_ports() {
  local scan_root="${1:-}"
  local json_items=()
  local seen=" "
  local line pid="" addr port

  while IFS= read -r line; do
    case "$line" in
      p*)
        pid="${line#p}"
        [[ "$pid" =~ ^[0-9]+$ ]] || pid=""
        continue
        ;;
      n*) addr="${line#n}" ;;
      *) continue ;;   # f<fd> and any other field: not needed
    esac

    [[ -n "$pid" ]] || continue
    [[ "$pid" == "$$" ]] && continue
    [[ -n "$addr" ]] || continue
    # host:port for every LISTEN shape lsof emits — 127.0.0.1:4200, *:9222, [::1]:4200.
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
  done < <(lsof -nP -iTCP -sTCP:LISTEN -Fpn 2>/dev/null)

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
#
# Parsed with a real JSON parser, NOT `grep -o '"cwd":"[^"]*"'`. That expression terminates at the
# first quote, so a cwd containing an ESCAPED quote is silently truncated to a prefix:
#   {"cwd":"/Users/shawnroos/projects/we\"ird/live"}  ->  /Users/shawnroos/projects/we\
# The truncated path does not exist, so a LIVE project reports as an orphaned ref and is offered for
# deletion. Worse, scan and the delete-side revalidation ran the SAME parse, so they agreed with each
# other and the containment check passed — two independent-looking guards sharing one bug.
#
# No python3, or a line that will not parse, means the question is unanswered: fail closed (return 1)
# so the dir is never treated as orphaned. Deleting a live session's transcript is unrecoverable.
resolve_project_cwd() {
  local ref_dir="$1" newest cwd
  newest=$(ls -t "${ref_dir%/}"/*.jsonl 2>/dev/null | head -1) || true
  [[ -n "$newest" && -f "$newest" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  cwd=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if isinstance(obj, dict):
                c = obj.get("cwd")
                if isinstance(c, str) and c:
                    sys.stdout.write(c)
                    break
except Exception:
    sys.exit(1)
' "$newest" 2>/dev/null) || return 1
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
      if window_matches_pattern "$win" "$p"; then hit="$p"; break; fi
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

  # Karma's default port range: more than one listener there is a clash. Counted from -F field
  # output for the same reason scan_ports uses it — never scrape lsof's display columns.
  local karma_clashes
  karma_clashes=$(lsof -nP -iTCP -sTCP:LISTEN -Fpn 2>/dev/null \
    | awk '
        /^p/ { pid = substr($0, 2); next }
        /^n/ {
          if (pid == "") next
          addr = substr($0, 2)
          sub(/.*:/, "", addr)
          if (addr + 0 >= 9876 && addr + 0 <= 9885 && !(pid in seen)) { seen[pid] = 1; n++ }
        }
        END { print n + 0 }')
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

    # DEFAULT DENY, expressed as a POSITIVE authorization rather than a re-check of the
    # classification string. Exactly two things authorize a kill, and nothing else does.
    #
    # Not `if [[ "$classification" != "safe_kill" ]]; then refuse; fi` placed after the consent
    # block: a consented pid is STILL classified consent_required at that point, so that form
    # refuses every consented kill and silently deletes the --consent feature. (Caught by the
    # "it IS killed with an explicit per-pid --consent" control, which exists because a
    # fail-closed fix that quietly disables the thing it guards is the standing hazard in this file.)
    local authorized=0

    if [[ "$classification" == "safe_kill" ]]; then
      authorized=1
    elif [[ "$classification" == "consent_required" ]]; then
      if [[ "$consent" != *" $pid "* ]]; then
        refused=$((refused + 1))
        log "REFUSED PID $pid — consent_required, no --consent given ($reason)"
        continue
      fi
      log "CONSENTED PID $pid ($reason)"
      authorized=1
    fi

    # Anything else — including the empty string — is unknown, and an unknown never kills. The
    # dispatch used to handle gone/protected/consent_required by name and let ANY other value fall
    # through to `kill "$pid"`. Not reachable today (classify_pid printf's one of four literals on
    # every path), so this is defense in depth, not a fix for a live defect. It earns its place
    # because this file's whole thesis is that unknowns fail closed, and this was the one place
    # where an unknown killed: a drifted caller, a new classification, or a truncated read.
    if (( authorized != 1 )); then
      refused=$((refused + 1))
      log "REFUSED PID $pid — unknown classification '$classification' (default deny)"
      continue
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

  # ~/.claude IS NOT A DELETE ROOT. Exactly two shapes under it are authorized, each with its own
  # content guard, and every other root under ~/.claude is refused outright.
  #
  #   mode=backup_only   --root ~/.claude            -> depth-1 *.bak / *.backup* ONLY (KTD6)
  #   mode=projects_only --root ~/.claude/projects   -> depth-1 dirs that the ENGINE re-derives as
  #                                                     orphaned refs (see below)
  #   (anything else under ~/.claude)                -> refused: unauthorized root
  #
  # `backup_only` keyed on exact string equality with ~/.claude, so passing the PROJECTS SUBDIR as
  # the root walked straight past the KTD6 restriction this block promises — and scan_global emits
  # `~/.claude/projects` as a root, and commands/crush-fullcream.md names it explicitly, so that is
  # a first-class path, not a hypothetical. Verified in a sandboxed HOME: a project dir whose newest
  # session JSONL points at a LIVE cwd — one scan_global correctly reports as NOT orphaned — was
  # still rm -rf'd. That is the same "documented, not wired" shape as the git-tracked rule below,
  # with a worse blast radius: a committed file is recoverable from git, a conversation transcript
  # is not. (F5 — 138/145 live project dirs offered for deletion — is the scan-side regression this
  # backstop has to survive.)
  local mode="repo"
  local claude_real projects_real
  claude_real=$(canonical_path "$HOME/.claude" 2>/dev/null) || claude_real=""
  projects_real=$(canonical_path "$HOME/.claude/projects" 2>/dev/null) || projects_real=""

  if [[ -n "$claude_real" && "$root_real" == "$claude_real" ]]; then
    mode="backup_only"
  elif [[ -n "$projects_real" && "$root_real" == "$projects_real" ]]; then
    mode="projects_only"
  elif [[ -n "$claude_real" && "$root_real" == "$claude_real"/* ]]; then
    log "BLOCKED unauthorized root under ~/.claude: $root_real"
    echo "{\"deleted\":0,\"failed\":0,\"bytes_freed\":0,\"freed_fmt\":\"0B\",\"error\":\"unauthorized root under ~/.claude\"}" >&2
    return 2
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

    if [[ "$mode" == "backup_only" ]]; then
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

    if [[ "$mode" == "projects_only" ]]; then
      # The engine RE-DERIVES the orphaned predicate for this exact target. Containment is not
      # enough here: an in-root project dir is by construction strictly under --root, so the only
      # thing standing between a live conversation transcript and `rm -rf` is that the engine
      # itself agrees the ref is dead. Nothing else ties a delete target under this root to what
      # scan_global actually reported.
      #
      # Same predicate scan_global uses (resolve_project_cwd + "that path is gone"), so the two can
      # never drift. FAIL CLOSED: no parseable cwd -> refuse. The dash-encoded directory NAME is
      # never trusted — it is not invertible, and trusting it is exactly F5.
      local pparent ref_cwd
      pparent=$(dirname "$real")
      if [[ "$pparent" != "$root_real" ]]; then
        log "BLOCKED not a direct child of root: $filepath"
        failed=$((failed + 1))
        continue
      fi
      if [[ ! -d "$real" ]]; then
        log "BLOCKED not an orphaned ref: $filepath (not a project directory)"
        failed=$((failed + 1))
        continue
      fi
      ref_cwd=$(resolve_project_cwd "$real" 2>/dev/null) || ref_cwd=""
      if [[ -z "$ref_cwd" ]]; then
        log "BLOCKED not an orphaned ref: $filepath (no cwd could be parsed from its session log — fail closed)"
        failed=$((failed + 1))
        continue
      fi
      if [[ -d "$ref_cwd" ]]; then
        log "BLOCKED not an orphaned ref: $filepath (its cwd $ref_cwd still exists — the session is LIVE)"
        failed=$((failed + 1))
        continue
      fi
    fi

    # NEVER DELETE GIT-TRACKED FILES — wired into the engine, not just written down.
    #
    # CLAUDE.md lists this under "Safety Rules (hardcoded, never overridden)", but it existed only
    # as prose plus an LLM command layer reading a `tracked` boolean out of the scan JSON. Both
    # slop lists are merged into ONE array distinguished by that flag, so a drifted or hallucinating
    # command layer that loses the distinction hands committed work to `rm -rf` — and containment
    # cannot catch it, because an in-root tracked file is BY CONSTRUCTION strictly under --root.
    # Its sibling rule (F4 containment) was wired into the engine; this one was not.
    #
    # `scan_slop` already reports tracked slop with `tracked: true` for the user to handle via
    # `git rm`. That is the whole delete story for tracked files; the engine refuses the rest.
    if git -C "$root_real" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
       && git -C "$root_real" ls-files --error-unmatch -- "$real" >/dev/null 2>&1; then
      log "BLOCKED git-tracked: $filepath"
      failed=$((failed + 1))
      continue
    fi

    # Checked against the RESOLVED path as well as the literal one. Every sibling guard here
    # validates `$real`; this one validated only `$filepath`, so a protected directory reached
    # through a differently-named symlink was simply not protected — the substring never appeared:
    #
    #   ln -s node_modules link
    #   delete --root $R $R/link/pkg/index.js      -> {"deleted":1}  the node_modules file DESTROYED
    #   delete --root $R $R/node_modules/pkg/index.js -> {"deleted":0,"failed":1}  same file, blocked
    #
    # Same file, same --root, opposite outcomes decided purely by the literal string. With
    # `ln -s .git store`, `delete --root $R $R/store/HEAD` took out the repo's HEAD and config
    # ("fatal: not a git repository" afterwards). The git-tracked guard does not cover it — that one
    # correctly validates `$real`, but .git internals are not tracked files. Containment passes by
    # construction because the target really is under --root.
    #
    # This violates a rule CLAUDE.md lists as hardcoded and never overridden, and it is the same
    # polarity defect as the others: "is the RESOLVED target protected?" was never asked, and the
    # unasked question resolved to "go ahead". Both forms are checked — the literal one still earns
    # its keep for a path that is protected by NAME but does not resolve (a broken symlink).
    if is_safe "$filepath" || is_safe "$real"; then
      log "BLOCKED safe pattern: $filepath (resolves to $real)"
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
  session-re)
    # Seam: "is this command line a live-claude session shape?" — the ONE fuzzy judgment in the
    # model, exposed so it can be pinned against REAL captured `ps -o command=` output instead of
    # only against a fixture the harness minted for itself. The fixture route is self-fulfilling:
    # a fake session parent named literally `claude` satisfies any plausible regex, which is
    # exactly how a dead session axis shipped under a fully green suite.
    #
    # Takes the RAW ps command line and windows it internally, so this tests command_window and
    # CRUSH_SESSION_RE composed the way production composes them.
    win=$(command_window "${1:-}")
    if [[ "$win" =~ $CRUSH_SESSION_RE ]]; then echo "true"; else echo "false"; fi
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
    echo "Usage: crush.sh {scan [--global] | contention | classify <pid> | session-re <cmd> | kill [--consent <pid>]... <pids...> | delete --root <path> <files...> | setup-launchagent | cron}" >&2
    exit 1
    ;;
esac
