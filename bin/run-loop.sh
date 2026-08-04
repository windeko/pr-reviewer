#!/usr/bin/env bash
# Fallback scheduler: run a tick every INTERVAL_SECS forever. Use this instead of
# systemd/launchd if you prefer — e.g.  nohup bin/run-loop.sh >/dev/null 2>&1 &
set -u
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$D/lib.sh"
botlog "run-loop start (interval ${INTERVAL_SECS}s)"
while true; do
  bash "$D/tick.sh" || botlog "tick.sh exited $?"
  sleep "$INTERVAL_SECS"
done
