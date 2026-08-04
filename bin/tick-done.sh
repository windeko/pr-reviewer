#!/usr/bin/env bash
# Release the tick lock and stamp last-run.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rm -rf "$LOCK"
date +%s > "$STATE_DIR/last_tick"
echo done
