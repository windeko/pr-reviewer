#!/usr/bin/env bash
# Review ONE PR end to end. Shared by the tick and the web app.
#   review-one.sh <PR#> [<slack_ts>] [<label>]
# Slack feedback on the request message:
#   - SLACK_BOT_TOKEN set → real reactions via the Slack Web API (bash, no Claude):
#     👀 while reviewing, then ✅ approved / 🚫 findings.
#   - no token → Claude posts one short threaded reply (✅/🚫 one-liner) via the MCP.
# Writes a structured verdict to state/verdicts/<N> for the dashboard. Skips PRs
# already merged/closed and our own. After a review: reads our latest GitHub review
# state — APPROVED unwatches, non-approval watches (headSHA + ts) so a later push
# re-reviews. Per-PR lock prevents double-review.
set -u
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$D/lib.sh"
N="${1:?PR number required}"; ts="${2:-}"; label="${3:-manual}"
case "$N" in *[!0-9]*|'') echo "bad PR: $N" >&2; exit 2;; esac
react(){ [ -n "$ts" ] && bash "$D/slack-react.sh" "$1" "$ts" "$2"; }
# verdict file: "<epoch>\t<emoji> PR <N>: <WORD> — <short>"
write_verdict(){ printf '%s\t%s PR %s: %s — %s\n' "$(date +%s)" "$1" "$N" "$2" "$3" > "$VERDICT_DIR/$N"; }

cd "$REPO_DIR" || { botlog "$label #$N: no repo $REPO_DIR"; exit 1; }

PLOCK="$STATE_DIR/review-$N.lock"
if ! mkdir "$PLOCK" 2>/dev/null; then botlog "$label #$N skipped (already reviewing)"; exit 0; fi
trap 'rm -rf "$PLOCK"' EXIT

# PR state + author in one call
prinfo="$("$GH_BIN" pr view "$N" --repo "$REPO_SLUG" --json state,author --jq '.state+" "+.author.login' 2>/dev/null)"
prstate="${prinfo%% *}"; author="${prinfo##* }"
# skip already merged/closed (nothing to review). gh read failure (empty) → fall through and review.
if [ -n "$prstate" ] && [ "$prstate" != "OPEN" ]; then
  write_verdict "⏭️" "SKIP" "already $prstate by someone"
  botlog "$label #$N skip — already $prstate"; exit 0
fi
# skip our own PRs
if [ -n "$OWN_LOGIN" ] && [ "$author" = "$OWN_LOGIN" ]; then
  write_verdict "⏭️" "SKIP" "own PR (author $author)"
  botlog "$label #$N skip — own PR ($author)"; exit 0
fi

# review instruction: your skill if configured, else a built-in generic prompt
if [ -n "$REVIEW_SKILL" ]; then
  step2="Invoke the $REVIEW_SKILL skill for PR $N in $REPO_SLUG and follow it fully to completion."
else
  step2="Review PR $N in $REPO_SLUG for breaking changes: env-var/secret wiring not carried into infra, changed function signatures with stale call sites, removed or renamed exports, DB migration ordering/columns, new IAM/DB/OAuth permissions, and retry/error-classification changes. Investigate the diff AND grep the wider repo for indirect breaks. Then post a GitHub review with the gh CLI: approve if nothing breaks, otherwise a REQUEST_CHANGES review listing the concrete breakages with file:line. Do not edit code."
fi

# No bot token → have Claude post a one-line threaded reply via the Slack MCP.
slack_step=""
if [ -z "${SLACK_BOT_TOKEN:-}" ] && [ -n "$ts" ]; then
  slack_step="Then use the Slack MCP to post ONE short threaded reply to the message at thread_ts=$ts in channel $SLACK_CHANNEL: a single line starting with ✅ if you approved (no breaking changes) or 🚫 if you requested changes, then a few words of why and the PR link."
fi

reqtime="$(fmt_time "${ts%%.*}" '%Y-%m-%d %H:%M' 2>/dev/null)"
botlog "$label #$N start — author ${author:-unknown}, request ${reqtime:-n/a}"
react add eyes                                   # 👀 while reviewing (no-op without token)

"$CLAUDE_BIN" -p "$step2 $slack_step End with exactly one final line: \"Verdict: APPROVED — <short reason>\" if you approved the PR, or \"Verdict: CHANGES — <short reason>\" if you requested changes." \
  --dangerously-skip-permissions --output-format text > "$LOG_DIR/review-$N.log" 2>&1
rc=$?

# short description = cleaned last line of the review output
short="$(tail -n1 "$LOG_DIR/review-$N.log" 2>/dev/null \
  | sed -E 's/[*_`]//g; s/^[[:space:]]*[Vv]erdict:?[[:space:]]*//; s/^PR[[:space:]]*[0-9]+:?[[:space:]]*//; s/^(APPROVED|REJECTED|COMMENTED|CHANGES([_ ]REQUESTED)?)[ :-]*//; s/^[^A-Za-z0-9]+//' \
  | cut -c1-150)"

# Verdict = the skill's own final "Verdict:" line (authoritative + robust to flaky gh).
vline="$(grep -iE 'verdict:' "$LOG_DIR/review-$N.log" 2>/dev/null | tail -1 | tr 'A-Z' 'a-z')"
case "$vline" in
  *approv*)                              verdict="APPROVED" ;;
  *chang*|*reject*|*request*|*comment*)  verdict="CHANGES" ;;
  *)                                     verdict="" ;;
esac

# head SHA for the watch-list; also a gh review-state fallback if there was no Verdict line.
me="$("$GH_BIN" api user --jq .login 2>/dev/null)"
head=""; ghstate=""
for _try in 1 2 3; do
  read -r head ghstate < <("$GH_BIN" pr view "$N" --repo "$REPO_SLUG" --json headRefOid,reviews \
    --jq --arg me "$me" '.headRefOid+" "+(([.reviews[]|select(.author.login==$me)]|last|.state)//"")' 2>/dev/null)
  [ -n "$head" ] && break
  sleep 3
done
if [ -z "$verdict" ] && [ -n "$ghstate" ]; then
  [ "$ghstate" = "APPROVED" ] && verdict="APPROVED" || verdict="CHANGES"
fi

react remove eyes                                 # done reviewing
case "$verdict" in
  APPROVED)
    react add white_check_mark                     # ✅
    rm -f "$WATCH_DIR/$N"
    write_verdict "✅" "APPROVED" "$short"
    botlog "$label #$N done — ✅ APPROVED (author ${author:-?})" ;;
  CHANGES)
    react add no_entry_sign                        # 🚫
    if [ -n "$head" ]; then printf '%s %s\n' "$head" "$ts" > "$WATCH_DIR/$N"
    else botlog "$label #$N: CHANGES but head SHA unreadable — not watching this round"; fi
    write_verdict "🚫" "REJECTED" "$short"
    botlog "$label #$N done — 🚫 REJECTED (author ${author:-?})" ;;
  *)
    word="UNKNOWN"; [ "$rc" -ne 0 ] && word="ERROR"
    write_verdict "⚠️" "$word" "${short:-no Verdict line emitted and gh review-state unreadable}"
    botlog "$label #$N done — ⚠️ $word (no Verdict line; gh unreadable)" ;;
esac
