#!/usr/bin/env bash
# Gate a tick. Prints "SKIP ..." (caller must stop) or "OK" (proceed, lock held).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ -e "$DISABLED" ] && { echo "SKIP disabled"; exit 0; }

# reap a stale lock from a crashed tick
if [ -d "$LOCK" ]; then
  age=$(( $(date +%s) - $(stat_mtime "$LOCK" 2>/dev/null || echo 0) ))
  [ "$age" -ge "$LOCK_STALE_SECS" ] && rm -rf "$LOCK"
fi

# atomic acquire
if mkdir "$LOCK" 2>/dev/null; then echo "OK"; else echo "SKIP locked"; fi
