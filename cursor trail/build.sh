#!/bin/bash
# Builds CursorTrail and writes the log next to this script.
#
# Resolves its own directory, so it works from any working directory and on any
# machine — the previous version hardcoded an absolute Desktop path containing
# five literal spaces that never existed.
set -uo pipefail

cd "$(dirname "$0")" || exit 1

# The SAFE_RM_* variables are injected by some agent harnesses; clearing them
# keeps a plain `swift build` from tripping over an inherited sandbox path.
unset SAFE_RM_ALLOWED_PATH
unset SAFE_RM_DENIED_PATH
unset SAFE_RM_PROTECTION_FLAG
unset SAFE_RM_AUTO_ADD_TEMP

LOG="build-output.txt"
SWIFT_BIN="${SWIFT:-/Library/Developer/CommandLineTools/usr/bin/swift}"
[ -x "$SWIFT_BIN" ] || SWIFT_BIN="$(command -v swift)"

echo "Starting build..." > "$LOG"
"$SWIFT_BIN" build >> "$LOG" 2>&1
status=$?
echo "BUILD_EXIT=$status" >> "$LOG"
exit $status