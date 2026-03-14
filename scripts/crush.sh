#!/bin/bash

# ClawCrush Scanner Engine
# Outputs JSON for process zombies and repo slop.
# The Claude agent handles UX — this script is a pure data source + executor.
#
# Usage:
#   crush.sh scan [--global]     — scan CWD (or global) for zombies + slop
#   crush.sh kill <pid> [pid...] — kill specific processes (SIGTERM → SIGKILL)
#   crush.sh delete <file> [..] — delete specific files
#   crush.sh setup-launchagent   — install/verify hourly zombie LaunchAgent

set -euo pipefail

ACTION="${1:-scan}"
shift 2>/dev/null || true

# ── Constants ──────────────────────────────────

MIN_AGE_MINUTES=60
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

# Convert ps etime to minutes
etime_to_minutes() {
  local etime="$1"
  local days=0 hours=0 mins=0

  if [[ "$etime" =~ ^([0-9]+)-([0-9]+):([0-9]+):([0-9]+)$ ]]; then
    days="${BASH_REMATCH[1]}"; hours="${BASH_REMATCH[2]}"; mins="${BASH_REMATCH[3]}"
  elif [[ "$etime" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
    hours="${BASH_REMATCH[1]}"; mins="${BASH_REMATCH[2]}"
  elif [[ "$etime" =~ ^([0-9]+):([0-9]+)$ ]]; then
    mins="${BASH_REMATCH[1]}"
  fi

  echo $(( 10#$days * 1440 + 10#$hours * 60 + 10#$mins ))
}

# Format etime for display
format_age() {
  local mins=$1
  if (( mins >= 1440 )); then
    echo "$((mins / 1440))d $((mins % 1440 / 60))h"
  elif (( mins >= 60 )); then
    echo "$((mins / 60))h $((mins % 60))m"
  else
    echo "${mins}m"
  fi
}

# Check if a file matches safe patterns
is_safe() {
  local filepath="$1"
  for pat in "${SAFE_PATTERNS[@]}"; do
    if [[ "$filepath" == *"$pat"* ]]; then
      return 0
    fi
  done
  return 1
}

# Check if file was modified in last N minutes
is_recent() {
  local filepath="$1"
  local mins="${2:-$RECENT_MINUTES}"
  if [[ "$(uname)" == "Darwin" ]]; then
    local mod_epoch
    mod_epoch=$(stat -f %m "$filepath" 2>/dev/null || echo 0)
    local now_epoch
    now_epoch=$(date +%s)
    local age_mins=$(( (now_epoch - mod_epoch) / 60 ))
    (( age_mins < mins ))
  else
    find "$filepath" -maxdepth 0 -mmin "-${mins}" 2>/dev/null | grep -q .
  fi
}

# Read .crushignore patterns from a file
read_crushignore() {
  local ignorefile="$1"
  local patterns=()
  if [[ -f "$ignorefile" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      patterns+=("$line")
    done < "$ignorefile"
  fi
  printf '%s\n' "${patterns[@]}"
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

scan_zombies() {
  local json_items=()

  for pattern in "${MCP_PATTERNS[@]}"; do
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local pid etime ppid
      pid=$(echo "$line" | awk '{print $1}')
      etime=$(echo "$line" | awk '{print $2}')
      ppid=$(echo "$line" | awk '{print $3}')

      local age_mins
      age_mins=$(etime_to_minutes "$etime")
      local age_fmt
      age_fmt=$(format_age "$age_mins")

      local is_orphan="false"
      local reason=""

      # PPID=1 means re-parented to launchd — definitively orphaned
      if [[ "$ppid" == "1" ]]; then
        is_orphan="true"
        reason="ppid=1 (orphaned)"
      elif (( age_mins >= MIN_AGE_MINUTES )); then
        is_orphan="true"
        reason="age > ${MIN_AGE_MINUTES}m"
      fi

      if [[ "$is_orphan" == "true" ]]; then
        # Extract short name
        local short
        short=$(echo "$pattern" | sed 's/mcp-//' | cut -d' ' -f1)
        json_items+=("{\"pid\":$pid,\"name\":\"$short\",\"pattern\":\"$pattern\",\"age\":\"$age_fmt\",\"age_mins\":$age_mins,\"ppid\":$ppid,\"reason\":\"$reason\"}")
      fi
    done < <(ps -eo pid,etime,ppid,command 2>/dev/null | grep -F "$pattern" | grep -v grep | awk '{print $1, $2, $3}')
  done

  # Also check for orphaned node/bun/chromium with PPID=1
  for proc_pattern in "node" "bun" "chromium" "chrome"; do
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local pid etime ppid
      pid=$(echo "$line" | awk '{print $1}')
      etime=$(echo "$line" | awk '{print $2}')
      ppid=$(echo "$line" | awk '{print $3}')

      # Only flag if PPID=1 AND old enough
      [[ "$ppid" != "1" ]] && continue

      local age_mins
      age_mins=$(etime_to_minutes "$etime")
      (( age_mins < MIN_AGE_MINUTES )) && continue

      local age_fmt
      age_fmt=$(format_age "$age_mins")

      # Skip if already captured by MCP patterns
      local already_found=false
      for item in "${json_items[@]}"; do
        if echo "$item" | grep -q "\"pid\":$pid"; then
          already_found=true
          break
        fi
      done
      [[ "$already_found" == "true" ]] && continue

      json_items+=("{\"pid\":$pid,\"name\":\"$proc_pattern\",\"pattern\":\"$proc_pattern (orphaned)\",\"age\":\"$age_fmt\",\"age_mins\":$age_mins,\"ppid\":$ppid,\"reason\":\"ppid=1 + age > ${MIN_AGE_MINUTES}m\"}")
    done < <(ps -eo pid,etime,ppid,command 2>/dev/null | grep -E "[/[:space:]]${proc_pattern}([[:space:]]|$)" | grep -v grep | awk '{print $1, $2, $3}')
  done

  # Output JSON array
  local result="["
  local first=true
  for item in "${json_items[@]}"; do
    [[ "$first" == "true" ]] && first=false || result+=","
    result+="$item"
  done
  result+="]"
  echo "$result"
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

  # Get untracked files from git
  local untracked
  untracked=$(git -C "$target_dir" ls-files --others --exclude-standard 2>/dev/null || true)

  while IFS= read -r filepath; do
    [[ -z "$filepath" ]] && continue

    local fullpath="${target_dir}/${filepath}"
    local basename
    basename=$(basename "$filepath")
    local ext="${basename##*.}"
    local dir
    dir=$(dirname "$filepath")
    local slop_type=""
    local size="0"

    # Skip safe patterns
    is_safe "$filepath" && continue

    # Skip recently modified files
    [[ -e "$fullpath" ]] && is_recent "$fullpath" && continue

    # Skip crushignored files
    matches_crushignore "$filepath" "$crushignore" && continue

    # Check: log/bak/orig/backup extensions at repo root or anywhere
    for slop_ext in "${SLOP_EXTENSIONS[@]}"; do
      if [[ "$ext" == "$slop_ext" ]]; then
        slop_type="$slop_ext"
        break
      fi
    done

    # Check: temp-/scratch-/debug- prefixes
    if [[ -z "$slop_type" ]]; then
      for prefix in "${SLOP_PREFIXES[@]}"; do
        if [[ "$basename" == ${prefix}* ]]; then
          slop_type="temp"
          break
        fi
      done
    fi

    # Check: media files at repo root
    if [[ -z "$slop_type" && "$dir" == "." ]]; then
      for media_ext in "${SLOP_MEDIA[@]}"; do
        if [[ "$ext" == "$media_ext" ]]; then
          slop_type="media"
          break
        fi
      done
    fi

    # Check: numbered variant files (file-v2.js, file2.js with base sibling)
    if [[ -z "$slop_type" ]]; then
      if [[ "$basename" =~ ^(.+)[-_]v?[0-9]+\.[a-z]+$ ]]; then
        # Check if a base version exists (tracked or untracked)
        local base_name="${BASH_REMATCH[1]}"
        local base_file="${dir}/${base_name}.${ext}"
        if [[ -e "${target_dir}/${base_file}" ]] || git -C "$target_dir" ls-files --error-unmatch "$base_file" &>/dev/null; then
          slop_type="dupe"
        fi
      fi
    fi

    # Check: slop directories
    if [[ -z "$slop_type" ]]; then
      for slop_dir in "${SLOP_DIRS[@]}"; do
        if [[ "$filepath" == ${slop_dir}/* || "$filepath" == "$slop_dir" ]]; then
          slop_type="test-artifact"
          break
        fi
      done
    fi

    # Only include if we identified it as slop
    [[ -z "$slop_type" ]] && continue

    # Get file size
    if [[ -f "$fullpath" ]]; then
      size=$(stat -f %z "$fullpath" 2>/dev/null || stat -c %s "$fullpath" 2>/dev/null || echo "0")
    elif [[ -d "$fullpath" ]]; then
      size=$(du -sb "$fullpath" 2>/dev/null | awk '{print $1}' || du -sk "$fullpath" 2>/dev/null | awk '{print $1 * 1024}' || echo "0")
    fi

    # Format size for display
    local size_fmt
    if (( size >= 1048576 )); then
      size_fmt="$(( size / 1048576 ))M"
    elif (( size >= 1024 )); then
      size_fmt="$(( size / 1024 ))K"
    else
      size_fmt="${size}B"
    fi

    # Escape filepath for JSON
    local escaped_path
    escaped_path=$(echo "$filepath" | sed 's/"/\\"/g')

    json_items+=("{\"path\":\"$escaped_path\",\"type\":\"$slop_type\",\"size\":$size,\"size_fmt\":\"$size_fmt\",\"tracked\":false}")
  done <<< "$untracked"

  # Also scan tracked files for report-only slop (log files, temp files at root)
  local tracked
  tracked=$(git -C "$target_dir" ls-files 2>/dev/null || true)

  while IFS= read -r filepath; do
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

    # Only flag tracked slop at repo root level
    [[ "$dir" != "." ]] && continue

    # Check: log files at root
    if [[ "$ext" == "log" ]]; then
      slop_type="log"
    fi

    # Check: temp/scratch/debug prefixes at root
    if [[ -z "$slop_type" ]]; then
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

    local size_fmt
    if (( size >= 1048576 )); then
      size_fmt="$(( size / 1048576 ))M"
    elif (( size >= 1024 )); then
      size_fmt="$(( size / 1024 ))K"
    else
      size_fmt="${size}B"
    fi

    local escaped_path
    escaped_path=$(echo "$filepath" | sed 's/"/\\"/g')

    json_items+=("{\"path\":\"$escaped_path\",\"type\":\"$slop_type\",\"size\":$size,\"size_fmt\":\"$size_fmt\",\"tracked\":true}")
  done <<< "$tracked"

  # Output JSON array
  local result="["
  local first=true
  for item in "${json_items[@]}"; do
    [[ "$first" == "true" ]] && first=false || result+=","
    result+="$item"
  done
  result+="]"
  echo "$result"
}

# ── Scan: Global ───────────────────────────────

scan_global() {
  local json_sections=()

  # 1. Orphaned .claude/projects/ refs
  local orphaned_refs=()
  if [[ -d "$HOME/.claude/projects" ]]; then
    for ref_dir in "$HOME/.claude/projects"/*/; do
      [[ ! -d "$ref_dir" ]] && continue
      local dir_name
      dir_name=$(basename "$ref_dir")
      # Convert dash-encoded path back to real path
      local real_path
      real_path=$(echo "$dir_name" | sed 's/^-/\//; s/-/\//g')
      if [[ ! -d "$real_path" ]]; then
        local ref_size
        ref_size=$(du -sk "$ref_dir" 2>/dev/null | awk '{print $1 * 1024}' || echo "0")
        local size_fmt
        if (( ref_size >= 1024 )); then
          size_fmt="$(( ref_size / 1024 ))K"
        else
          size_fmt="${ref_size}B"
        fi
        local escaped_dir
        escaped_dir=$(echo "$dir_name" | sed 's/"/\\"/g')
        orphaned_refs+=("{\"name\":\"$escaped_dir\",\"size\":$ref_size,\"size_fmt\":\"$size_fmt\"}")
      fi
    done
  fi

  # 2. Config backups in ~/.claude/
  local config_backups=()
  while IFS= read -r backup_file; do
    [[ -z "$backup_file" ]] && continue
    local bname
    bname=$(basename "$backup_file")
    local bsize
    bsize=$(stat -f %z "$backup_file" 2>/dev/null || echo "0")
    local size_fmt
    if (( bsize >= 1024 )); then
      size_fmt="$(( bsize / 1024 ))K"
    else
      size_fmt="${bsize}B"
    fi
    config_backups+=("{\"path\":\"$bname\",\"size\":$bsize,\"size_fmt\":\"$size_fmt\"}")
  done < <(find "$HOME/.claude" -maxdepth 1 -name "*.backup*" -o -name "*.bak" 2>/dev/null)

  # 3. Plugin cache stats
  local cache_size="0"
  local cache_size_fmt="0B"
  local cache_count=0
  if [[ -d "$HOME/.claude/plugins/cache" ]]; then
    cache_size=$(du -sk "$HOME/.claude/plugins/cache" 2>/dev/null | awk '{print $1 * 1024}' || echo "0")
    cache_count=$(find "$HOME/.claude/plugins/cache" -maxdepth 2 -type d 2>/dev/null | wc -l | tr -d ' ')
    if (( cache_size >= 1048576 )); then
      cache_size_fmt="$(( cache_size / 1048576 ))M"
    elif (( cache_size >= 1024 )); then
      cache_size_fmt="$(( cache_size / 1024 ))K"
    fi
  fi

  # Build orphaned refs array
  local refs_json="["
  local first=true
  for item in "${orphaned_refs[@]}"; do
    [[ "$first" == "true" ]] && first=false || refs_json+=","
    refs_json+="$item"
  done
  refs_json+="]"

  # Build backups array
  local backups_json="["
  first=true
  for item in "${config_backups[@]}"; do
    [[ "$first" == "true" ]] && first=false || backups_json+=","
    backups_json+="$item"
  done
  backups_json+="]"

  echo "{\"orphaned_refs\":$refs_json,\"config_backups\":$backups_json,\"plugin_cache\":{\"size\":$cache_size,\"size_fmt\":\"$cache_size_fmt\",\"count\":$cache_count}}"
}

# ── Actions ────────────────────────────────────

do_kill() {
  local killed=0
  local failed=0

  for pid in "$@"; do
    if kill "$pid" 2>/dev/null; then
      # Wait up to 5 seconds for graceful exit
      local waited=0
      while (( waited < 5 )) && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
      done
      # SIGKILL if still alive
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

do_delete() {
  local deleted=0
  local failed=0
  local bytes_freed=0

  for filepath in "$@"; do
    if [[ ! -e "$filepath" ]]; then
      failed=$((failed + 1))
      continue
    fi

    # Safety checks
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
    if [[ -f "$filepath" ]]; then
      fsize=$(stat -f %z "$filepath" 2>/dev/null || echo "0")
    elif [[ -d "$filepath" ]]; then
      fsize=$(du -sk "$filepath" 2>/dev/null | awk '{print $1 * 1024}' || echo "0")
    fi

    if rm -rf "$filepath" 2>/dev/null; then
      deleted=$((deleted + 1))
      bytes_freed=$((bytes_freed + fsize))
      log "Deleted: $filepath ($fsize bytes)"
    else
      failed=$((failed + 1))
      log "Failed to delete: $filepath"
    fi
  done

  # Format bytes freed
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
  echo "{\"status\":\"installed\",\"plist\":\"$LAUNCHAGENT_PLIST\",\"interval\":3600}"
}

# ── Cron mode (silent auto-kill) ───────────────

do_cron() {
  local zombies
  zombies=$(scan_zombies)

  local pids
  pids=$(echo "$zombies" | grep -oE '"pid":[0-9]+' | grep -oE '[0-9]+')

  if [[ -n "$pids" ]]; then
    for pid in $pids; do
      kill "$pid" 2>/dev/null || true
    done
    local count
    count=$(echo "$pids" | wc -l | tr -d ' ')
    log "Cron: killed $count zombie processes"
  fi
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
    echo "Usage: crush.sh {scan [--global] | kill <pids...> | delete <files...> | setup-launchagent | cron}" >&2
    exit 1
    ;;
esac
