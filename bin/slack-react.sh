#!/usr/bin/env bash
# Add/remove a Slack reaction via the Web API. No-op if SLACK_BOT_TOKEN is unset.
#   slack-react.sh <add|remove> <message_ts> <emoji_name>
# Needs a bot token with `reactions:write`, invited to SLACK_CHANNEL.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
mode="${1:?add|remove}"; ts="${2:-}"; name="${3:?emoji name}"
[ -z "${SLACK_BOT_TOKEN:-}" ] && exit 0
[ -z "$ts" ] && exit 0

resp="$(curl -s -X POST "https://slack.com/api/reactions.$mode" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  --data-urlencode "channel=$SLACK_CHANNEL" \
  --data-urlencode "timestamp=$ts" \
  --data-urlencode "name=$name" 2>/dev/null)"

case "$resp" in
  *'"ok":true'*)            : ;;                       # done
  *already_reacted*|*no_reaction*) : ;;                # idempotent
  *) botlog "slack-react $mode $name @ $ts failed: $(printf '%s' "$resp" | head -c140)" ;;
esac
