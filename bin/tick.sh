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
do_review(){ bash "$D/review-one.sh" "$1" "$2" "$3"; }

# ── 1. re-review watched PRs whose head moved ──
for f in "$WATCH_DIR"/*; do
  [ -e "$f" ] || continue
  N=$(basename "$f"); read -r stored_sha stored_ts < "$f" || true
  # self-heal a corrupt watch file (no reviewed SHA) — otherwise "moved" is always true
  [ -z "$stored_sha" ] && { rm -f "$f"; botlog "unwatch #$N (corrupt empty-SHA watch file)"; continue; }
  info=$("$GH_BIN" pr view "$N" --repo "$REPO_SLUG" --json state,headRefOid --jq '.state+" "+.headRefOid' 2>/dev/null)
  [ -z "$info" ] && { botlog "watch #$N: gh read failed, retry next tick"; continue; }
  st=${info%% *}; cur=${info##* }
  if [ "$st" != "OPEN" ]; then rm -f "$f"; botlog "unwatch #$N (state $st)"; continue; fi
  if [ -n "$cur" ] && [ "$cur" != "$stored_sha" ]; then
    [ "$budget" -le 0 ] && { botlog "re-review #$N deferred (cap)"; continue; }
    budget=$((budget-1)); do_review "$N" "$stored_ts" "re-review"
  fi
done

# ── 2. read channel → PR/ts pairs (temp-file map: portable, no bash-4 assoc arrays) ──
raw=$("$CLAUDE_BIN" -p "Using the Slack MCP, read the $READ_COUNT most recent messages in channel $SLACK_CHANNEL using the detailed format so each message's ts is included. For each message that is a PR Review Request (its text ends with (#NNNN)), output one line exactly: PR=NNNN TS=<that message's ts> . No prose, no other text." \
  --dangerously-skip-permissions --output-format text 2>>"$LOG_DIR/daemon.err")

tsmap="$(mktemp)"; trap 'rm -f "$tsmap"; bash "$D/tick-done.sh" >/dev/null 2>&1' EXIT
printf '%s\n' "$raw" | grep -oE 'PR=[0-9]+ TS=[0-9.]+' \
  | sed -E 's/PR=([0-9]+) TS=([0-9.]+)/\1 \2/' | sort -un > "$tsmap"
nums=$(awk '{print $1}' "$tsmap")
if [ -z "$nums" ]; then botlog "read: 0 PR numbers (raw: $(printf '%s' "$raw" | tr '\n' ' ' | head -c140))"; : > "$QUEUE_FILE"; exit 0; fi

# pending = every request PR > floor not yet handled (uncapped) — this is the review queue
pending=$(printf '%s\n' $nums | grep -oE '[0-9]+' | sort -un | awk -v f="$FLOOR" '$1+0 > f+0' | comm -23 - <(sort -un "$SEEN"))
printf '%s\n' $pending | grep -oE '[0-9]+' > "$QUEUE_FILE"

new=$(printf '%s\n' $pending | grep -oE '[0-9]+' | head -n "$MAX_PER_TICK")   # this tick's batch
[ -z "$new" ] && exit 0
botlog "new: $(echo $new | tr '\n' ' ')"
bash "$D/mark-handled.sh" $new >/dev/null

for N in $new; do
  [ "$budget" -le 0 ] && { botlog "review #$N deferred (cap)"; continue; }
  ts=$(awk -v n="$N" '$1==n{print $2; exit}' "$tsmap")
  budget=$((budget-1))
  do_review "$N" "$ts" "review"
done
botlog "tick complete"
