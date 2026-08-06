#!/usr/bin/env bash
# One tick (run by systemd/launchd/run-loop):
#   1. re-review watched PRs (had findings) whose head SHA moved
#   2. review genuinely-new PR-review-requests (> floor, not seen, not our own)
# Each review reacts on the Slack request msg. Sequential; per-tick cap bounds cost.
set -u
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$D/lib.sh"

gate=$(bash "$D/tick-precheck.sh")
case "$gate" in OK) ;; *) exit 0 ;; esac
trap 'bash "$D/tick-done.sh" >/dev/null 2>&1' EXIT
cd "$REPO_DIR" || { botlog "no repo $REPO_DIR"; exit 1; }

budget=$MAX_PER_TICK   # total reviews this tick (new + re-review)
do_review(){ bash "$D/review-one.sh" "$1" "$2" "$3" "${4:-}"; }

# ── 1. re-review watched PRs whose head moved ──
for f in "$WATCH_DIR"/*; do
  [ -e "$f" ] || continue
  N=$(basename "$f"); read -r stored_sha stored_ts < "$f" || true
  info=$("$GH_BIN" pr view "$N" --repo "$REPO_SLUG" --json state,headRefOid --jq '.state+" "+.headRefOid' 2>/dev/null)
  [ -z "$info" ] && { botlog "watch #$N: gh read failed, retry next tick"; continue; }
  st=${info%% *}; cur=${info##* }
  if [ "$st" != "OPEN" ]; then rm -f "$f"; botlog "unwatch #$N (state $st)"; continue; fi
  # not yet baselined (reject couldn't read head at review time) → adopt current head, no re-review
  if [ -z "$stored_sha" ]; then
    [ -n "$cur" ] && { printf '%s %s\n' "$cur" "$stored_ts" > "$f"; botlog "watch #$N baselined @ ${cur:0:8}"; }
    continue
  fi
  if [ -n "$cur" ] && [ "$cur" != "$stored_sha" ]; then
    [ "$budget" -le 0 ] && { botlog "re-review #$N deferred (cap)"; continue; }
    ci="$(ci_state "$N")"
    case "$ci" in green|none) ;; *) botlog "re-review #$N held — CI $ci"; continue;; esac
    budget=$((budget-1)); do_review "$N" "$stored_ts" "re-review" "$cur"
  fi
done

# ── 2. read channel → PR/ts pairs (temp-file map: portable, no bash-4 assoc arrays) ──
raw=$("$CLAUDE_BIN" -p "Using the Slack MCP, read the $READ_COUNT most recent messages in channel $SLACK_CHANNEL using the detailed format so each message's ts is included. For each message that is a PR Review Request (its text ends with (#NNNN)), output one line exactly: PR=NNNN TS=<that message's ts> . No prose, no other text." \
  --dangerously-skip-permissions --output-format text 2>>"$LOG_DIR/daemon.err")

tsmap="$(mktemp)"; trap 'rm -f "$tsmap"; bash "$D/tick-done.sh" >/dev/null 2>&1' EXIT
printf '%s\n' "$raw" | grep -oE 'PR=[0-9]+ TS=[0-9.]+' \
  | sed -E 's/PR=([0-9]+) TS=([0-9.]+)/\1 \2/' | sort -un > "$tsmap"
nums=$(awk '{print $1}' "$tsmap")

# ── discover: add new channel PRs to the persistent queue, mark them seen so the
#    channel won't re-surface them (queue is now the source of truth, re-checked every tick).
if [ -n "$nums" ]; then
  pending=$(printf '%s\n' $nums | grep -oE '[0-9]+' | sort -un | awk -v f="$FLOOR" '$1+0 > f+0' | comm -23 - <(sort -un "$SEEN"))
  if [ -n "$pending" ]; then
    for N in $(printf '%s\n' $pending | grep -oE '[0-9]+'); do
      [ -f "$QDIR/$N" ] || { ts=$(awk -v n="$N" '$1==n{print $2; exit}' "$tsmap"); printf '%s\n' "$ts" > "$QDIR/$N"; }
    done
    bash "$D/mark-handled.sh" $pending >/dev/null
    botlog "queued: $(echo $pending | tr '\n' ' ')"
  fi
else
  botlog "read: 0 PR numbers (raw: $(printf '%s' "$raw" | tr '\n' ' ' | head -c140))"
fi

# ── process the persistent queue EVERY tick (independent of the Slack window):
#    review CI-green PRs, re-check the rest. One gh call per PR (state+ci); reads capped.
qtmp="$(mktemp)"; checks=0; READ_CAP=$(( MAX_PER_TICK * 8 ))
for f in "$QDIR"/*; do
  [ -e "$f" ] || continue
  N=$(basename "$f"); read -r qts < "$f" || true
  if [ "$checks" -ge "$READ_CAP" ]; then printf '%s %s\n' "$N" "waiting" >> "$qtmp"; continue; fi
  checks=$((checks+1))
  gate="$(pr_gate "$N")"; state="${gate%% *}"; ci="${gate##* }"
  if [ -z "$state" ]; then printf '%s %s\n' "$N" "unknown" >> "$qtmp"; continue; fi   # gh blip → keep, retry
  if [ "$state" != "OPEN" ]; then rm -f "$f"; botlog "dequeue #$N (state $state)"; continue; fi
  if { [ "$ci" = "green" ] || [ "$ci" = "none" ]; } && [ "$budget" -gt 0 ]; then
    budget=$((budget-1)); do_review "$N" "$qts" "review"; rm -f "$f"
  else
    printf '%s %s\n' "$N" "$ci" >> "$qtmp"   # still queued (CI not green yet, or budget spent this tick)
  fi
done
mv "$qtmp" "$QUEUE_FILE"
botlog "tick complete"
