#!/bin/bash
# Full verification pass for the somno mac client fix round.
# Builds and tests every package, then prints one CHECK line per check.
# Read-only with respect to sources.
set -uo pipefail
ROOT="/Users/jackson/Desktop/work related/claude/somno mac client"
OUT="${1:-/tmp/somno-verify-out.txt}"
: > "$OUT"

# Every run writes to its own log file. Grepping the accumulating $OUT would
# leak a previous module's test count into the next module's verdict.
RUN_LOG="$(mktemp -t somno-run)"
trap 'rm -f "$RUN_LOG"' EXIT

FAILURES=0

run_check() {
  local name="$1"; shift
  local dir="$1"; shift
  echo "=== $name: $*" >> "$OUT"
  : > "$RUN_LOG"
  ( cd "$dir" && "$@" ) >> "$RUN_LOG" 2>&1
  local rc=$?
  cat "$RUN_LOG" >> "$OUT"
  if [ $rc -eq 0 ]; then
    echo "CHECK $name: PASS" >> "$OUT"
  else
    echo "CHECK $name: FAIL (exit $rc)" >> "$OUT"
    FAILURES=$((FAILURES + 1))
  fi
  return 0
}

# This repo is famous for tests that compile and then execute nothing, which
# still exits 0. So never trust the exit code alone -- count what actually ran.
# Three harnesses are in use, each with its own success line:
#   swift-testing  "Test run with N tests"
#   XCTest         "Executed N tests"
#   TestRunner     "Total: N assertions, 0 failed"
# "Executed 0 tests" on its own is benign when the swift-testing line is also
# present, so the two are summed rather than checked separately.
report_test_count() {
  local name="$1"
  local st_count xc_count as_count total
  st_count=$(grep -oE 'Test run with [0-9]+ tests?' "$RUN_LOG" | grep -oE '[0-9]+' | tail -1)
  xc_count=$(grep -oE 'Executed [0-9]+ tests?' "$RUN_LOG" | grep -oE '[0-9]+' | tail -1)
  as_count=$(grep -oE 'Total: [0-9]+ assertions?, [0-9]+ failed' "$RUN_LOG" | grep -oE 'Total: [0-9]+' | grep -oE '[0-9]+' | tail -1)
  total=$(( ${st_count:-0} + ${xc_count:-0} + ${as_count:-0} ))
  if [ "$total" -eq 0 ]; then
    echo "CHECK $name test-count: FAIL (0 tests executed -- suite is dead code)" >> "$OUT"
    FAILURES=$((FAILURES + 1))
  else
    echo "CHECK $name test-count: PASS (${st_count:-0} swift-testing + ${xc_count:-0} XCTest + ${as_count:-0} TestRunner assertions = $total)" >> "$OUT"
  fi
}

# Discover module dirs (post-rename: polymorph is now "cursor changer")
for dir in "cursor trail" "desktop-canvas" "ghost trail" "cursor changer" "polymorph"; do
  pkg="$ROOT/$dir"
  [ -f "$pkg/Package.swift" ] || continue

  run_check "$dir build" "$pkg" swift build
  run_check "$dir test" "$pkg" swift test

  # Not every package uses XCTest: cursor changer ships an executable
  # TestRunner target, for which `swift test` correctly reports
  # "no tests found" -- and exits 1, because it has nothing to run. That is
  # not a failure when a real harness exists, so fall back to running it and
  # score whichever one actually executed tests.
  if grep -q 'no tests found' "$RUN_LOG" && [ -d "$pkg/Tests/TestRunner" ]; then
    echo "=== $dir has no XCTest target; scoring its TestRunner harness instead" >> "$OUT"
    sed -i.bak "/^CHECK $dir test: FAIL/d" "$OUT" && rm -f "$OUT.bak"
    FAILURES=$((FAILURES - 1))
    run_check "$dir TestRunner" "$pkg" swift run TestRunner
    report_test_count "$dir TestRunner"
  else
    report_test_count "$dir test"
  fi
done

# totem pop ships a shell harness that builds and self-tests without sudo
if [ -d "$ROOT/totem pop/test" ]; then
  run_check "totem pop build+selftest" "$ROOT/totem pop/test" ./build.sh
fi

# black hole is reference-only: build check only (no fixes were made there,
# but it should still compile)
if [ -f "$ROOT/black hole/ghostty-blackhole-main/tuner/Package.swift" ]; then
  run_check "blackhole tuner build" "$ROOT/black hole/ghostty-blackhole-main/tuner" swift build
fi

{
  echo "---- SUMMARY ----"
  grep -E '^CHECK' "$OUT"
  echo
  if [ "$FAILURES" -eq 0 ]; then
    echo "ALL CHECKS PASSED -- every module built, ran its tests, and executed a non-zero number of them."
  else
    echo "FAILURES: $FAILURES"
  fi
} >> "$OUT"
cat "$OUT"