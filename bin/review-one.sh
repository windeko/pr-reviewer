#!/usr/bin/env bash
# Review ONE PR end to end. Shared by the tick and the web app.
#   review-one.sh <PR#> [<slack_ts>] [<label>]
# Reacts on the Slack request message when a ts is given (:eyes: start,
# :white_check_mark: approved / :no_entry_sign: findings). After: reads our latest
# GitHub review state — APPROVED unwatches, anything else watches (stores headSHA
# + ts) so a later push triggers a re-review. Per-PR lock prevents double-review.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
N="${1:?PR number required}"; ts="${2:-}"; label="${3:-manual}"
case "$N" in *[!0-9]*|'') echo "bad PR: $N" >&2; exit 2;; esac

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
  step2="invoke the $REVIEW_SKILL skill for PR $N and follow it fully to completion."
else
  step2="review PR $N for breaking changes: env-var/secret wiring not carried into infra, changed function signatures with stale call sites, removed or renamed exports, DB migration ordering/columns, new IAM/DB/OAuth permissions, and retry/error-classification changes. Investigate the diff AND grep the wider repo for indirect breaks. Then post a GitHub review with the gh CLI: approve if nothing breaks, otherwise a COMMENT review that lists the concrete breakages with file:line. Do not edit code."
fi

botlog "$label #$N start (ts ${ts:-none})"
"$CLAUDE_BIN" -p "Task for PR $N in $REPO_SLUG. Its Slack review-request is in channel $SLACK_CHANNEL at ts=$ts. This is a $label.
Step 1 — if ts is non-empty: use the Slack MCP to add the :eyes: reaction to that message (channel $SLACK_CHANNEL, timestamp $ts).
Step 2: $step2
Step 3 — if ts is non-empty: reflect the outcome on that same message. If your review approved the PR with no blocking findings, add :white_check_mark: and remove :no_entry_sign: if present. Otherwise add :no_entry_sign: and remove :white_check_mark: if present. Keep :eyes:.
End with a one-line verdict." \
  --dangerously-skip-permissions --output-format text > "$LOG_DIR/review-$N.log" 2>&1
rc=$?

state="$("$GH_BIN" pr view "$N" --repo "$REPO_SLUG" --json reviews --jq '[.reviews[]|select(.author.login=="'"${OWN_LOGIN:-__me__}"'" or true)]|last|.state' 2>/dev/null)"
head="$("$GH_BIN" pr view "$N" --repo "$REPO_SLUG" --json headRefOid --jq .headRefOid 2>/dev/null)"
if [ "$state" = "APPROVED" ]; then
  rm -f "$WATCH_DIR/$N"; botlog "$label #$N rc=$rc -> APPROVED (unwatch)"
else
  printf '%s %s\n' "$head" "$ts" > "$WATCH_DIR/$N"; botlog "$label #$N rc=$rc -> ${state:-nostate} (watch @ ${head:0:8})"
fi
