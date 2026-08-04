#!/usr/bin/env bash
# Shared config + helpers, sourced by every script. Loads ../.env, applies
# defaults, defines the paths and the two portability shims (GNU vs BSD stat/date).
set -u

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$LIB_DIR/.." && pwd)"

# load .env (KEY=VALUE lines) into the environment
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi

# ── config (env / .env, with defaults) ──────────────────────────────────────
REPO_SLUG="${REPO_SLUG:?set REPO_SLUG in .env (owner/name)}"
REPO_DIR="${REPO_DIR:?set REPO_DIR in .env (local checkout path)}"
SLACK_CHANNEL="${SLACK_CHANNEL:?set SLACK_CHANNEL in .env}"
OWN_LOGIN="${OWN_LOGIN:-}"
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"   # bot token w/ reactions:write; empty => reactions off
READ_COUNT="${READ_COUNT:-30}"
MAX_PER_TICK="${MAX_PER_TICK:-5}"
INTERVAL_SECS="${INTERVAL_SECS:-180}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
GH_BIN="${GH_BIN:-gh}"
REVIEW_SKILL="${REVIEW_SKILL:-}"
WEB_HOST="${WEB_HOST:-127.0.0.1}"
WEB_PORT="${WEB_PORT:-8787}"
DATA_DIR="${DATA_DIR:-$HOME/.local/state/claude-pr-reviewer}"
LOCK_STALE_SECS="${LOCK_STALE_SECS:-900}"

# expand a leading ~ (env files don't do tilde expansion)
DATA_DIR="${DATA_DIR/#\~/$HOME}"
REPO_DIR="${REPO_DIR/#\~/$HOME}"

# ── paths ───────────────────────────────────────────────────────────────────
STATE_DIR="$DATA_DIR/state"
LOG_DIR="$DATA_DIR/logs"
WATCH_DIR="$STATE_DIR/watching"     # one file per PR awaiting re-review: "<headSHA> <ts>"
VERDICT_DIR="$STATE_DIR/verdicts"   # one file per PR: "<epoch>\t<emoji> PR N: WORD — short"
SEEN="$STATE_DIR/seen_prs.txt"      # handled PR numbers
LOCK="$STATE_DIR/tick.lock"         # atomic mkdir mutex; mtime = acquire time
DISABLED="$STATE_DIR/DISABLED"      # presence => paused
FLOOR_FILE="$STATE_DIR/floor"       # ignore PRs <= this
mkdir -p "$WATCH_DIR" "$VERDICT_DIR" "$LOG_DIR" 2>/dev/null || true
touch "$SEEN" 2>/dev/null || true

FLOOR="${FLOOR:-0}"
[ -f "$FLOOR_FILE" ] && FLOOR="$(cat "$FLOOR_FILE" 2>/dev/null || echo "$FLOOR")"

# ── helpers ─────────────────────────────────────────────────────────────────
botlog(){ echo "[$(date '+%F %T')] $*" >> "$LOG_DIR/daemon.log"; }
# mtime of a file, portable (GNU coreutils, then BSD/macOS)
stat_mtime(){ stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
# format an epoch, portable. $2 = strftime (default full timestamp)
fmt_time(){ date -d "@$1" "+${2:-%Y-%m-%d %H:%M:%S}" 2>/dev/null || date -r "$1" "+${2:-%Y-%m-%d %H:%M:%S}" 2>/dev/null; }
