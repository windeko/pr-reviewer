#!/usr/bin/env bash
# Review ONE PR end to end. Shared by the tick and the web app.
#   review-one.sh <PR#> [<slack_ts>] [<label>]
# With a ts + SLACK_BOT_TOKEN it reacts on the Slack request message via the Slack
# Web API (deterministic bash, not the connector): 👀 while reviewing, then swaps to
# ✅ approved / 🚫 findings. After: reads our latest GitHub review state — APPROVED
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

botlog "$label #$N start (ts ${ts:-none})"
react add eyes                                   # 👀 while reviewing

"$CLAUDE_BIN" -p "$step2 End with a one-line verdict." \
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
