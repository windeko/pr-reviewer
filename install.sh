#!/usr/bin/env bash
# Install the per-repo schedulers + the shared dashboard as background services.
#   Linux  → systemd --user template timer (pr-reviewer@<repo>) + web service (+ linger)
#   macOS  → launchd LaunchAgents (one tick agent per repo + one web)
# One instance per instances/<name>.env. Idempotent; re-run after editing config.
#
#   ./install.sh                    install/refresh every repo instance + the web UI
#   ./install.sh <name>             only that repo instance (+ web)
#   ./install.sh [<name>] --set-floor   also set each repo's FLOOR to its current max PR
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
[ -f .env ] || { echo "!! copy .env.example to .env and fill it in first"; exit 1; }
set -a; . ./.env; set +a
INTERVAL="${INTERVAL_SECS:-180}"
STATE_ROOT="${STATE_ROOT:-${DATA_DIR:-$HOME/.local/state/claude-pr-reviewer}}"; STATE_ROOT="${STATE_ROOT/#\~/$HOME}"
PY="$(command -v python3 || true)"; [ -n "$PY" ] || { echo "!! python3 not found"; exit 1; }
command -v "${GH_BIN:-gh}" >/dev/null || echo "?? ${GH_BIN:-gh} not on PATH — set GH_BIN to an absolute path in .env"
command -v "${CLAUDE_BIN:-claude}" >/dev/null || echo "?? ${CLAUDE_BIN:-claude} not on PATH — set CLAUDE_BIN to an absolute path in .env"
chmod +x bin/*.sh 2>/dev/null || true

CDIR="$(dirname "$(command -v "${CLAUDE_BIN:-claude}" 2>/dev/null || echo /usr/bin/claude)")"
GDIR="$(dirname "$(command -v "${GH_BIN:-gh}" 2>/dev/null || echo /usr/bin/gh)")"
BINPATH="$CDIR:$GDIR:$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

# args
SET_FLOOR=0; ONLY=""
for a in "$@"; do case "$a" in --set-floor) SET_FLOOR=1;; *) ONLY="$a";; esac; done

list_instances(){ ls instances/*.env 2>/dev/null | grep -v '/example\.env$' | sed -E 's#.*/##; s#\.env$##'; }
inst_val(){ sed -nE "s/^$2=//p" "instances/$1.env" 2>/dev/null | head -1; }
inst_data(){ local dd; dd="$(inst_val "$1" DATA_DIR)"; [ -n "$dd" ] && echo "${dd/#\~/$HOME}" || echo "$STATE_ROOT/$1"; }

INSTANCES="$(list_instances)"
[ -z "$INSTANCES" ] && { echo "!! no instances/*.env — copy instances/example.env to instances/<name>.env"; exit 1; }
[ -n "$ONLY" ] && INSTANCES="$ONLY"

# per-instance state dir + optional floor
for name in $INSTANCES; do
  dd="$(inst_data "$name")"; mkdir -p "$dd/state/watching" "$dd/state/verdicts" "$dd/logs"
  if [ "$SET_FLOOR" = 1 ]; then
    slug="$(inst_val "$name" REPO_SLUG)"
    max="$("${GH_BIN:-gh}" pr list --repo "$slug" --state all --limit 1 --json number --jq '.[0].number' 2>/dev/null || echo 0)"
    echo "$max" > "$dd/state/floor"; echo "  $name ($slug) floor=$max"
  fi
done

render(){ sed -e "s|__ROOT__|$ROOT|g" -e "s|__PYTHON__|$PY|g" -e "s|__INTERVAL__|$INTERVAL|g" \
              -e "s|__BINPATH__|$BINPATH|g" -e "s|__INSTANCE__|${2:-}|g" "$1"; }

case "$(uname -s)" in
  Linux)
    UD="$HOME/.config/systemd/user"; mkdir -p "$UD"
    render init/systemd/pr-reviewer@.service.tmpl    > "$UD/pr-reviewer@.service"
    render init/systemd/pr-reviewer@.timer.tmpl      > "$UD/pr-reviewer@.timer"
    render init/systemd/pr-reviewer-web.service.tmpl > "$UD/pr-reviewer-web.service"
    loginctl enable-linger "$USER" 2>/dev/null || echo "?? enable-linger failed; run: sudo loginctl enable-linger $USER"
    systemctl --user daemon-reload
    systemctl --user enable --now pr-reviewer-web.service
    for name in $INSTANCES; do
      systemctl --user enable --now "pr-reviewer@$name.timer"
      echo "✔ pr-reviewer@$name.timer"
    done
    ;;
  Darwin)
    LA="$HOME/Library/LaunchAgents"; mkdir -p "$LA"
    render init/launchd/com.claude-pr-reviewer.web.plist.tmpl > "$LA/com.claude-pr-reviewer.web.plist"
    launchctl unload "$LA/com.claude-pr-reviewer.web.plist" 2>/dev/null || true
    launchctl load "$LA/com.claude-pr-reviewer.web.plist"
    for name in $INSTANCES; do
      P="$LA/com.claude-pr-reviewer.tick.$name.plist"; dd="$(inst_data "$name")"; mkdir -p "$dd/logs"
      render init/launchd/com.claude-pr-reviewer.tick.plist.tmpl "$name" | sed "s|__DATA__|$dd|g" > "$P"
      launchctl unload "$P" 2>/dev/null || true
      launchctl load "$P"
      echo "✔ com.claude-pr-reviewer.tick.$name"
    done
    ;;
  *) echo "!! unsupported OS — use bin/run-loop.sh with nohup instead"; exit 1;;
esac

echo "✔ dashboard: http://${WEB_HOST:-127.0.0.1}:${WEB_PORT:-8787}"
