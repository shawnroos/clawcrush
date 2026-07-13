#!/bin/bash

# ClawCrush Scanner Engine
# Outputs JSON for process zombies and repo slop.
# The Claude agent handles UX — this script is a pure data source + executor.
#
# Usage:
#   crush.sh scan [--global]                  — scan CWD (or global) for zombies + slop
#   crush.sh kill <pid> [pid...]              — kill specific processes (SIGTERM → SIGKILL)
#   crush.sh delete --root <path> <file>...   — delete files, contained under <root>
#   crush.sh setup-launchagent                — install/verify hourly LaunchAgent
#   crush.sh cron                             — REPORT-ONLY dry run: logs would-kill candidates
#
# CRON IS REPORT-ONLY. It kills nothing. Every line it emits is prefixed `Cron dry-run:`.

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

# Generic runtimes: only ever candidates when ALREADY orphaned (ppid=1) AND old.
ORPHAN_RUNTIME_PATTERNS=("node" "bun" "chromium" "chrome")

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

# ── Scan: Processes ────────────────────────────

# Emit one row per process candidate:
#   pid|ppid|age_mins|age_fmt|name|pattern|reason
# Single source of truth for both `scan` (JSON) and `cron` (dry-run log).
zombie_rows() {
  local seen=" "
  local pid ppid etime cmd p

  # ONE ps call, matched in-process. The old code ran `ps | grep | awk` once per pattern and
  # then forked three more subshells per matched line to split the fields.
  while read -r pid ppid etime cmd; do
    [[ -z "${pid:-}" || -z "${cmd:-}" ]] && continue
    [[ "$pid" == "$$" ]] && continue
    case "$cmd" in
      *crush.sh*) continue ;;
    esac
    [[ "$seen" == *" $pid "* ]] && continue

    local name="" pattern="" reason=""

    for p in "${MCP_PATTERNS[@]}"; do
      if [[ "$cmd" == *"$p"* ]]; then
        pattern="$p"
        name="${p#mcp-}"
        name="${name%% *}"
        break
      fi
    done

    if [[ -n "$pattern" ]]; then
      set_age "$etime"
      # NOTE (F1): age alone is still sufficient here. That is the zero-precision predicate —
      # U1 replaces it with the two-axis classifier. U0 only disarms what ACTS on it.
      if [[ "$ppid" == "1" ]]; then
        reason="ppid=1 (orphaned)"
      elif (( _AGE_MINS >= MIN_AGE_MINUTES )); then
        reason="age > ${MIN_AGE_MINUTES}m"
      else
        continue
      fi
    else
      # Generic runtimes: candidates ONLY when already orphaned AND old (the correct AND model
      # that already existed in the second loop).
      [[ "$ppid" != "1" ]] && continue
      for p in "${ORPHAN_RUNTIME_PATTERNS[@]}"; do
        if [[ "$cmd" =~ (^|[/[:space:]])"$p"([[:space:]]|$) ]]; then
          pattern="$p (orphaned)"
          name="$p"
          break
        fi
      done
      [[ -z "$pattern" ]] && continue
      set_age "$etime"
      (( _AGE_MINS < MIN_AGE_MINUTES )) && continue
      reason="ppid=1 + age > ${MIN_AGE_MINUTES}m"
    fi

    seen="$seen$pid "
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
      "$pid" "$ppid" "$_AGE_MINS" "$_AGE_FMT" "$name" "$pattern" "$reason"
  done < <(ps -eo pid=,ppid=,etime=,command= 2>/dev/null)
}

scan_zombies() {
  local json_items=()
  local row pid ppid age_mins age_fmt name pattern reason

  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    IFS='|' read -r pid ppid age_mins age_fmt name pattern reason <<< "$row"
    json_items+=("{\"pid\":$pid,\"name\":\"$(json_escape "$name")\",\"pattern\":\"$(json_escape "$pattern")\",\"age\":\"$age_fmt\",\"age_mins\":$age_mins,\"ppid\":$ppid,\"reason\":\"$(json_escape "$reason")\"}")
  done < <(zombie_rows)

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

# ── Actions ────────────────────────────────────

do_kill() {
  local killed=0
  local failed=0

  for pid in "$@"; do
    if kill "$pid" 2>/dev/null; then
      local waited=0
      while (( waited < 5 )) && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        log "SIGKILL PID $pid (SIGTERM failed)"
      else
        log "Killed PID $pid"
      fi
      killed=$((killed + 1))
    else
      failed=$((failed + 1))
      log "Failed to kill PID $pid"
    fi
  done

  echo "{\"killed\":$killed,\"failed\":$failed}"
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
  local row pid ppid age_mins age_fmt name pattern reason

  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    IFS='|' read -r pid ppid age_mins age_fmt name pattern reason <<< "$row"
    log "Cron dry-run: would-kill pid $pid name=$name age=$age_fmt reason=$reason"
    count=$((count + 1))
  done < <(zombie_rows)

  log "Cron dry-run: $count candidate(s); killed 0 (report-only)"
}

# ── Main dispatch ──────────────────────────────

case "$ACTION" in
  scan)
    flag="${1:-}"
    if [[ "$flag" == "--global" ]]; then
      zombies=$(scan_zombies)
      global=$(scan_global)
      echo "{\"zombies\":$zombies,\"global\":$global}"
    else
      zombies=$(scan_zombies)
      slop=$(scan_slop ".")
      echo "{\"zombies\":$zombies,\"slop\":$slop}"
    fi
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
    echo "Usage: crush.sh {scan [--global] | kill <pids...> | delete --root <path> <files...> | setup-launchagent | cron}" >&2
    exit 1
    ;;
esac
