#!/usr/bin/env bash
# Human-readable status.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "claude-pr-reviewer  ($REPO_SLUG)"
[ -e "$DISABLED" ] && echo "  state:   PAUSED (rm $DISABLED to resume)" || echo "  state:   enabled"
if [ -d "$LOCK" ]; then
  echo "  tick:    RUNNING (since $(fmt_time "$(stat_mtime "$LOCK")" '%H:%M:%S'))"
else
  echo "  tick:    idle"
fi
if [ -f "$STATE_DIR/last_tick" ]; then
  lt="$(cat "$STATE_DIR/last_tick")"
  echo "  last:    $(fmt_time "$lt") ($(( ($(date +%s)-lt)/60 ))m ago)"
else
  echo "  last:    never"
fi
echo "  handled: $(grep -c . "$SEEN" 2>/dev/null || echo 0) PRs"
echo "  watching: $(ls -1 "$WATCH_DIR" 2>/dev/null | grep -c '^[0-9]' || echo 0) awaiting re-review"
echo "  floor:   $FLOOR   cap: $MAX_PER_TICK/tick   channel: $SLACK_CHANNEL"
echo "  web:     http://$WEB_HOST:$WEB_PORT"
