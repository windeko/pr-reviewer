#!/usr/bin/env bash
# Args: candidate PR numbers. Prints the NEW ones (> floor, not already handled),
# numeric-only, unique, ascending, capped at MAX_PER_TICK.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

printf '%s\n' "$@" \
  | grep -oE '[0-9]+' \
  | sort -un \
  | awk -v f="$FLOOR" '$1+0 > f+0' \
  | comm -23 - <(sort -un "$SEEN") \
  | head -n "$MAX_PER_TICK"
