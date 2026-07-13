#!/bin/bash
# Runs every clawcrush test file under /bin/bash (macOS bash 3.2) — the interpreter launchd
# resolves. Running these under homebrew bash 5.x would hide the F6 empty-array abort.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

files_run=0
files_failed=0
failed_names=()

for f in "$TESTS_DIR"/*.test.sh; do
  [[ -e "$f" ]] || continue
  files_run=$((files_run + 1))
  echo ""
  echo "=== $(basename "$f") ==="
  /bin/bash "$f"
  if (( $? != 0 )); then
    files_failed=$((files_failed + 1))
    failed_names+=("$(basename "$f")")
  fi
done

echo ""
echo "══════════════════════════════════════"
# A zero-discovery run must be LOUD. The whole safety contract of this engine — the kill matrix,
# delete containment, cron's report-only-ness — is proven only by this harness, so "0 files ran"
# and "everything is green" must never render as the same line. A wrong TESTS_DIR, a broken
# checkout, or a rename that drops the `.test.sh` suffix would otherwise print PASSED and exit 0.
if (( files_run == 0 )); then
  echo "SUITE: FAILED — no test files discovered under $TESTS_DIR"
  exit 1
fi
if (( files_failed > 0 )); then
  echo "SUITE: FAILED — $files_failed of $files_run file(s) failed:"
  for n in ${failed_names[@]+"${failed_names[@]}"}; do
    echo "  - $n"
  done
  exit 1
fi
echo "SUITE: PASSED — $files_run file(s) green"
exit 0
