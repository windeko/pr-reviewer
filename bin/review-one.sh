#!/usr/bin/env bash
# Review ONE PR end to end. Shared by the tick and the web app.
#   review-one.sh <PR#> [<slack_ts>] [<label>]
# Slack feedback on the request message:
#   - SLACK_BOT_TOKEN set → real reactions via the Slack Web API (bash, no Claude):
#     👀 while reviewing, then ✅ approved / 🚫 findings.
#   - no token → Claude posts one short threaded reply (✅/🚫 one-liner) via the MCP.
# After: reads our latest GitHub review state — APPROVED
# unwatches, anything else watches (headSHA + ts) so a later push re-reviews.
# Per-PR lock prevents double-review.
set -u
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$D/lib.sh"
N="${1:?PR number required}"; ts="${2:-}"; label="${3:-manual}"
case "$N" in *[!0-9]*|'') echo "bad PR: $N" >&2; exit 2;; esac
react(){ [ -n "$ts" ] && bash "$D/slack-react.sh" "$1" "$ts" "$2"; }

cd "$REPO_DIR" || { botlog "$label #$N: no repo $REPO_DIR"; exit 1; }

PLOCK="$STATE_DIR/review-$N.lock"
if ! mkdir "$PLOCK" 2>/dev/null; then botlog "$label #$N skipped (already reviewing)"; exit 0; fi
trap 'rm -rf "$PLOCK"' EXIT

# skip our own PRs
if [ -n "$OWN_LOGIN" ]; then
  author="$("$GH_BIN" pr view "$N" --repo "$REPO_SLUG" --json author --jq .author.login 2>/dev/null)"
  if [ "$author" = "$OWN_LOGIN" ]; then botlog "$label #$N skip (own PR)"; exit 0; fi
fi

# review instruction: your skill if configured, else a built-in generic prompt
if [ -n "$REVIEW_SKILL" ]; then
  step2="Invoke the $REVIEW_SKILL skill for PR $N in $REPO_SLUG and follow it fully to completion."
else
  step2="Review PR $N in $REPO_SLUG for breaking changes: env-var/secret wiring not carried into infra, changed function signatures with stale call sites, removed or renamed exports, DB migration ordering/columns, new IAM/DB/OAuth permissions, and retry/error-classification changes. Investigate the diff AND grep the wider repo for indirect breaks. Then post a GitHub review with the gh CLI: approve if nothing breaks, otherwise a COMMENT review listing the concrete breakages with file:line. Do not edit code."
fi

# No bot token → have Claude post a one-line threaded reply via the Slack MCP
# (the connector can send messages, just not reactions).
slack_step=""
if [ -z "${SLACK_BOT_TOKEN:-}" ] && [ -n "$ts" ]; then
  slack_step="Then use the Slack MCP to post ONE short threaded reply to the message at thread_ts=$ts in channel $SLACK_CHANNEL: a single line starting with ✅ if you approved (no breaking changes) or 🚫 if you requested changes, then a few words of why and the PR link."
fi

botlog "$label #$N start (ts ${ts:-none})"
react add eyes                                   # 👀 while reviewing (no-op without token)

"$CLAUDE_BIN" -p "$step2 $slack_step End with a one-line verdict." \
  --dangerously-skip-permissions --output-format text > "$LOG_DIR/review-$N.log" 2>&1
rc=$?

me="$("$GH_BIN" api user --jq .login 2>/dev/null)"
state="$("$GH_BIN" pr view "$N" --repo "$REPO_SLUG" --json reviews --jq --arg me "$me" '[.reviews[]|select(.author.login==$me)]|last|.state' 2>/dev/null)"
head="$("$GH_BIN" pr view "$N" --repo "$REPO_SLUG" --json headRefOid --jq .headRefOid 2>/dev/null)"

react remove eyes                                # done reviewing
if [ "$state" = "APPROVED" ]; then
  react add white_check_mark                     # ✅
  rm -f "$WATCH_DIR/$N"; botlog "$label #$N rc=$rc -> APPROVED (unwatch)"
else
  react add no_entry_sign                        # 🚫
  printf '%s %s\n' "$head" "$ts" > "$WATCH_DIR/$N"; botlog "$label #$N rc=$rc -> ${state:-nostate} (watch @ ${head:0:8})"
fi
