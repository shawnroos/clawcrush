#!/bin/bash
# U0 — the destructive paths are disarmed, and scan output is trustworthy under bash 3.2.
#
# Guards: F6 (empty-array abort), F2 (armed mass-kill cron), F4 (no path containment),
#         F5 (lossy dash-decode offering live session history for deletion),
#         F7 (is_recent on directories, JSON escaping).

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

setup_tmp

# ── F6: empty scans emit valid empty JSON with rc=0 under /bin/bash ───────────────────────
# Today (pre-fix) this aborts with `json_items[@]: unbound variable`, rc=1, EMPTY stdout —
# and it fails CLOSED on the harmless empty case while failing OPEN on the dangerous one.

empty_repo=$(mk_repo "$TMPROOT/empty")
out=$(crush_in "$empty_repo" scan 2>/dev/null)
rc=$?
expect_eq "F6: scan in a clean repo exits 0" "0" "$rc"
expect_json "F6: scan in a clean repo emits valid JSON" "$out"
expect_eq "F6: clean repo reports no slop" "0" "$(json_get "$out" 'len(d["slop"])')"

out=$(crush_in "$empty_repo" scan --global 2>/dev/null)
rc=$?
expect_eq "F6: scan --global exits 0" "0" "$rc"
expect_json "F6: scan --global emits valid JSON" "$out"
expect_eq "F6: scan --global reports no orphaned refs on an empty fixture HOME" \
  "0" "$(json_get "$out" 'len(d["global"]["orphaned_refs"])')"

# ── F2: cron is report-only ───────────────────────────────────────────────────────────────
# Mint a real orphan (ppid==1) named after a shipped MCP pattern, then run cron with the age
# gate wide open. The pre-fix cron SIGTERMs it; the fixed cron only logs it.

mcp_exec=$(mk_exec "$TMPROOT/bin" "playwright-mcp")
orphan_pid=$(spawn_orphan "$empty_repo" "$mcp_exec")

if [[ -z "$orphan_pid" ]]; then
  nok "F2: could not mint an orphan candidate (harness failure)"
else
  expect_eq "F2: minted candidate really is an orphan (ppid=1)" \
    "1" "$(ps -o ppid= -p "$orphan_pid" 2>/dev/null | tr -d ' ')"

  CRUSH_MIN_AGE_MINUTES=0 crush cron >/dev/null 2>&1

  expect_alive "F2: cron did NOT kill the orphan (report-only)" "$orphan_pid"

  # Delimiter-anchored: a bare substring needle for pid 123 also matches the line for pid 1234.
  logtxt=$(log_contents)
  expect_would_kill "F2: cron logged a dry-run would-kill line for the orphan" \
    "$logtxt" "$orphan_pid"
fi

# ── F4: delete containment ────────────────────────────────────────────────────────────────

repo_a=$(mk_repo "$TMPROOT/repoA")
outside_dir="$TMPROOT/outside"
mkdir -p "$outside_dir"

in_root="$repo_a/debug-in-root.log"
printf 'slop\n' > "$in_root"
age_path "$in_root"

outside_file="$outside_dir/precious.log"
printf 'precious\n' > "$outside_file"
age_path "$outside_file"

# (i) in-root target is deleted
out=$(crush delete --root "$repo_a" "$in_root" 2>/dev/null)
expect_eq "F4: in-root slop is deleted" "1" "$(json_get "$out" 'd["deleted"]')"
expect_missing "F4: the in-root file is really gone" "$in_root"

# (ii) an absolute path OUTSIDE the root is refused — this is the proven arbitrary rm -rf
out=$(crush delete --root "$repo_a" "$outside_file" 2>/dev/null)
expect_eq "F4: out-of-root target is refused" "0" "$(json_get "$out" 'd["deleted"]')"
expect_exists "F4: the out-of-root file survives" "$outside_file"
expect_contains "F4: out-of-root refusal is logged" "$(log_contents)" "BLOCKED out-of-root"

# (iii) an in-root symlink pointing outside the root is refused, target intact.
#      Backdate the LINK ITSELF (-h): BSD stat doesn't follow symlinks, so a freshly-created
#      link is blocked by is_recent and this assertion would pass without ever exercising
#      containment at all — green for the wrong reason.
link="$repo_a/escape.log"
ln -s "$outside_file" "$link"
touch -h -t "$(date -v-1d +%Y%m%d%H%M)" "$link" 2>/dev/null
out=$(crush delete --root "$repo_a" "$link" 2>/dev/null)
expect_eq "F4: in-root symlink resolving outside root is refused" "0" "$(json_get "$out" 'd["deleted"]')"
expect_exists "F4: the symlink's out-of-root target survives" "$outside_file"

# (iv) NO --root at all → refuse everything. This is the collapse point of the containment
#      model: a stale command layer or an agent calling `crush.sh delete <path>` bare must
#      fail closed rather than fall back to the old unbounded behavior.
bare="$repo_a/bare-debug.log"
printf 'slop\n' > "$bare"
age_path "$bare"
crush delete "$bare" >/dev/null 2>&1
rc=$?
if (( rc != 0 )); then ok "F4: delete with no --root exits non-zero"; else nok "F4: delete with no --root exits non-zero (got rc=0)"; fi
expect_exists "F4: delete with no --root deleted nothing" "$bare"
expect_contains "F4: delete with no --root logs a BLOCKED line" "$(log_contents)" "BLOCKED no --root"

# (v) a target that merely LOOKS like a flag must not be swallowed as --root's value
flagish="$repo_a/-weird-debug.log"
printf 'slop\n' > "$flagish"
age_path "$flagish"
crush delete "$flagish" >/dev/null 2>&1
rc=$?
if (( rc != 0 )); then ok "F4: flag-shaped target with no --root exits non-zero"; else nok "F4: flag-shaped target with no --root exits non-zero (got rc=0)"; fi
expect_exists "F4: flag-shaped target survives" "$flagish"

# ── "Never delete git-tracked files" — wired into the ENGINE, not just written down ───────
# CLAUDE.md lists this under "Safety Rules (hardcoded, never overridden)", but it lived only as
# prose plus an LLM command layer reading a `tracked` boolean out of the scan JSON. Containment
# cannot catch this: a tracked file inside the repo is BY CONSTRUCTION strictly under --root, so
# a drifted command layer that loses the flag hands committed work straight to `rm -rf`.
#
# The target is shaped like slop AND is committed — precisely the collision the rule exists for.

tracked_slop="$repo_a/debug-committed.log"
printf 'this is committed work\n' > "$tracked_slop"
git -C "$repo_a" add -f debug-committed.log >/dev/null 2>&1
git -C "$repo_a" commit -qm "commit a log" >/dev/null 2>&1
age_path "$tracked_slop"

out=$(crush delete --root "$repo_a" "$tracked_slop" 2>/dev/null)
expect_eq "tracked: a git-tracked file is refused by the engine" "0" "$(json_get "$out" 'd["deleted"]')"
expect_exists "tracked: the committed file survives" "$tracked_slop"
expect_contains "tracked: the refusal is logged" "$(log_contents)" "BLOCKED git-tracked"

# The positive control: an UNtracked file of the same shape, in the same repo, still deletes.
# Without it, the guard above is satisfied by an engine that refuses every delete.
untracked_slop="$repo_a/debug-untracked.log"
printf 'real slop\n' > "$untracked_slop"
age_path "$untracked_slop"
out=$(crush delete --root "$repo_a" "$untracked_slop" 2>/dev/null)
expect_eq "tracked: an untracked file of the same shape still deletes" "1" "$(json_get "$out" 'd["deleted"]')"
expect_missing "tracked: the untracked slop is really gone" "$untracked_slop"

# ── KTD6: the ~/.claude root authorizes depth-1 config backups ONLY ───────────────────────
# Widening --root to ~/.claude must not put ~/.claude/logs or settings.json in the envelope.

claude_root="$HOME/.claude"
mkdir -p "$claude_root/logs"
printf '{}\n' > "$claude_root/settings.json"
printf '{}\n' > "$claude_root/settings.json.backup"
printf 'log\n' > "$claude_root/logs/foo.log"
age_path "$claude_root/settings.json"
age_path "$claude_root/settings.json.backup"
age_path "$claude_root/logs/foo.log"

out=$(crush delete --root "$claude_root" "$claude_root/settings.json.backup" 2>/dev/null)
expect_eq "KTD6: a depth-1 config backup is deleted" "1" "$(json_get "$out" 'd["deleted"]')"
expect_missing "KTD6: the backup is really gone" "$claude_root/settings.json.backup"

out=$(crush delete --root "$claude_root" "$claude_root/settings.json" 2>/dev/null)
expect_eq "KTD6: settings.json is refused (not a backup-glob match)" "0" "$(json_get "$out" 'd["deleted"]')"
expect_exists "KTD6: settings.json survives" "$claude_root/settings.json"

out=$(crush delete --root "$claude_root" "$claude_root/logs/foo.log" 2>/dev/null)
expect_eq "KTD6: ~/.claude/logs/foo.log is refused (not a direct child of root)" "0" "$(json_get "$out" 'd["deleted"]')"
expect_exists "KTD6: the log under ~/.claude/logs survives" "$claude_root/logs/foo.log"

# ── F7: is_recent must recurse into directories ───────────────────────────────────────────
# SLOP_DIRS are all directories and deletion is recursive, so judging the dir inode's own
# mtime is the weakest guard exactly where the blast radius is largest.

report_dir="$repo_a/playwright-report"
mkdir -p "$report_dir"
printf 'fresh\n' > "$report_dir/index.html"   # written seconds ago
age_path "$report_dir"                        # but the DIRECTORY inode looks old

out=$(crush delete --root "$repo_a" "$report_dir" 2>/dev/null)
expect_eq "F7: a dir with freshly-written content is refused" "0" "$(json_get "$out" 'd["deleted"]')"
expect_exists "F7: the freshly-written report dir survives" "$report_dir/index.html"

# ── F5: orphaned-ref detection fails closed ───────────────────────────────────────────────
# The dash-encoding is not invertible. Resolve the real cwd from the session JSONL, and only
# call a dir orphaned when a cwd was POSITIVELY parsed and that path is gone.

projects="$HOME/.claude/projects"
mkdir -p "$projects/-live-one" "$projects/-dead-one" "$projects/-unparseable"

live_target="$TMPROOT/live-project"
mkdir -p "$live_target"
printf '{"cwd":"%s","type":"user"}\n' "$live_target" > "$projects/-live-one/session.jsonl"
printf '{"cwd":"%s","type":"user"}\n' "$TMPROOT/deleted-project" > "$projects/-dead-one/session.jsonl"
printf '{"type":"user","message":"no cwd here"}\n' > "$projects/-unparseable/session.jsonl"

out=$(crush_in "$empty_repo" scan --global 2>/dev/null)
expect_json "F5: scan --global still emits valid JSON with fixture projects" "$out"
names=$(json_get "$out" '",".join(sorted(x["name"] for x in d["global"]["orphaned_refs"]))')
expect_eq "F5: only the dir whose parsed cwd is gone is orphaned" "-dead-one" "$names"

# ── The ~/.claude/projects delete root re-derives the orphaned predicate ───────────────────
# scan_global emits `~/.claude/projects` as a delete root (commands/crush-fullcream.md names it
# explicitly), and the KTD6 backup_only guard keyed on exact string equality with ~/.claude — so
# handing the PROJECTS SUBDIR as the root walked straight past it. Verified in a sandboxed HOME:
# a project dir whose newest session JSONL points at a LIVE cwd — one scan_global correctly reports
# as NOT orphaned — was still rm -rf'd ({"deleted":1}). Containment cannot catch this: an in-root
# project dir is BY CONSTRUCTION strictly under --root.
#
# Same "documented, not wired" shape as the git-tracked rule, with a worse blast radius — a
# committed file is recoverable from git, a conversation transcript is not. F5 (138/145 LIVE project
# dirs offered for deletion) is the scan-side regression this backstop has to survive.
#
# Backdate everything: is_recent recurses into directories, so a freshly-minted fixture would be
# refused for the WRONG reason and prove nothing about the predicate.
for d in "$projects/-live-one" "$projects/-dead-one" "$projects/-unparseable"; do
  age_path "$d/session.jsonl"
  age_path "$d"
done

# (i) a LIVE project dir under the projects root is refused — the engine re-derives the predicate
out=$(crush delete --root "$projects" "$projects/-live-one" 2>/dev/null)
expect_eq "projects-root: a LIVE project dir is refused" "0" "$(json_get "$out" 'd["deleted"]')"
expect_exists "projects-root: the live session's transcripts survive" "$projects/-live-one/session.jsonl"
expect_contains "projects-root: the refusal is logged as a predicate failure" \
  "$(log_contents)" "BLOCKED not an orphaned ref"

# (ii) fail CLOSED: a dir whose session log has no parseable cwd is refused too. The dash-encoded
#      directory NAME is never trusted — it is not invertible, and trusting it is exactly F5.
out=$(crush delete --root "$projects" "$projects/-unparseable" 2>/dev/null)
expect_eq "projects-root: a dir with no parseable cwd is refused (fail closed)" \
  "0" "$(json_get "$out" 'd["deleted"]')"
expect_exists "projects-root: the unparseable dir survives" "$projects/-unparseable/session.jsonl"

# (iii) every other root under ~/.claude is refused outright — ~/.claude/logs must not become a
#       delete root just because it is not one of the two authorized ones. Refused at the ROOT, so
#       (like a missing --root) it exits non-zero with its JSON on stderr and never enters the loop.
crush delete --root "$claude_root/logs" "$claude_root/logs/foo.log" >/dev/null 2>&1
rc=$?
if (( rc != 0 )); then ok "projects-root: an unauthorized root under ~/.claude exits non-zero"; else nok "projects-root: an unauthorized root under ~/.claude exits non-zero (got rc=0)"; fi
expect_exists "projects-root: the file under the unauthorized root survives" "$claude_root/logs/foo.log"
expect_contains "projects-root: the unauthorized root is logged" \
  "$(log_contents)" "BLOCKED unauthorized root"

# (iv) THE POSITIVE CONTROL. Without it, every assertion above is satisfied by an engine that
#      refuses every delete under this root — i.e. by deleting the feature.
out=$(crush delete --root "$projects" "$projects/-dead-one" 2>/dev/null)
expect_eq "projects-root: the genuinely orphaned ref IS deleted" "1" "$(json_get "$out" 'd["deleted"]')"
expect_missing "projects-root: the orphaned ref is really gone" "$projects/-dead-one"

# ── F7: JSON escaping survives quotes and backslashes ─────────────────────────────────────

repo_b=$(mk_repo "$TMPROOT/repoB")
nasty='we"ird\path-debug.log'
printf 'slop\n' > "$repo_b/$nasty"
age_path "$repo_b/$nasty"

out=$(crush_in "$repo_b" scan 2>/dev/null)
expect_json "F7: scan output with a quote+backslash filename is valid JSON" "$out"
expect_eq "F7: the nasty path round-trips exactly" \
  "$nasty" "$(json_get "$out" '[x["path"] for x in d["slop"] if not x["tracked"]][0]')"

# ── JSON escaping survives CONTROL CHARACTERS ─────────────────────────────────────────────
# json_escape used to pass the C0 range through raw and STRIP newlines with `tr -d`. Both are
# corruption, not cosmetics:
#   - one raw control char in ONE filename makes the ENTIRE scan document invalid JSON, and every
#     command mode that parses it goes blind — including the fullcream path that is about to act
#     on it;
#   - a stripped newline means the emitted path is a DIFFERENT STRING than the real filename, so a
#     delete target no longer names the file that was scanned.
# `git ls-files -z` hands both shapes over verbatim, so neither is hypothetical.

repo_c=$(mk_repo "$TMPROOT/repoC")
ctrl=$(printf 'ctl\ttab\nnewline-debug.log')   # a real TAB and a real NEWLINE in the filename
printf 'slop\n' > "$repo_c/$ctrl" 2>/dev/null

if [[ ! -e "$repo_c/$ctrl" ]]; then
  nok "ctrl: could not create a control-char filename (harness failure)"
else
  age_path "$repo_c/$ctrl"
  out=$(crush_in "$repo_c" scan 2>/dev/null)
  expect_json "ctrl: a filename with a tab and a newline still yields VALID scan JSON" "$out"
  expect_eq "ctrl: and the control-char path round-trips byte-exactly (not silently rewritten)" \
    "$ctrl" "$(json_get "$out" '[x["path"] for x in d["slop"] if not x["tracked"]][0]')"
fi

finish
