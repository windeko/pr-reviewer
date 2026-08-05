#!/usr/bin/env bash
# Install the scheduler + dashboard as background services.
#   Linux  → systemd --user timer + service (+ linger so they survive logout)
#   macOS  → launchd LaunchAgents
# Idempotent. Re-run after editing .env or the code.
#
#   ./install.sh              install/refresh services
#   ./install.sh --set-floor  also set FLOOR to the repo's current max PR number
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# ── prereqs ──
[ -f .env ] || { echo "!! copy .env.example to .env and fill it in first"; exit 1; }
set -a; . ./.env; set +a
DATA_DIR="${DATA_DIR:-$HOME/.local/state/claude-pr-reviewer}"; DATA_DIR="${DATA_DIR/#\~/$HOME}"
INTERVAL="${INTERVAL_SECS:-180}"
PY="$(command -v python3 || true)"; [ -n "$PY" ] || { echo "!! python3 not found"; exit 1; }
command -v bash >/dev/null || { echo "!! bash not found"; exit 1; }
command -v "${GH_BIN:-gh}" >/dev/null || echo "?? ${GH_BIN:-gh} not on PATH — reviews will fail until it is"
command -v "${CLAUDE_BIN:-claude}" >/dev/null || echo "?? ${CLAUDE_BIN:-claude} not on PATH — reviews will fail until it is"
mkdir -p "$DATA_DIR/state/watching" "$DATA_DIR/logs"
chmod +x bin/*.sh 2>/dev/null || true

# dirs of gh & claude, so the service PATH can find them (systemd/launchd PATH is minimal)
CDIR="$(dirname "$(command -v "${CLAUDE_BIN:-claude}" 2>/dev/null || echo /usr/bin/claude)")"
GDIR="$(dirname "$(command -v "${GH_BIN:-gh}" 2>/dev/null || echo /usr/bin/gh)")"
BINPATH="$CDIR:$GDIR:$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

render(){ sed -e "s|__ROOT__|$ROOT|g" -e "s|__PYTHON__|$PY|g" -e "s|__INTERVAL__|$INTERVAL|g" -e "s|__DATA__|$DATA_DIR|g" -e "s|__BINPATH__|$BINPATH|g" "$1"; }

if [ "${1:-}" = "--set-floor" ]; then
  max="$("${GH_BIN:-gh}" pr list --repo "$REPO_SLUG" --state all --limit 1 --json number --jq '.[0].number' 2>/dev/null || echo 0)"
  echo "$max" > "$DATA_DIR/state/floor"; echo "floor set to $max"
fi

OS="$(uname -s)"
case "$OS" in
  Linux)
    UD="$HOME/.config/systemd/user"; mkdir -p "$UD"
    render init/systemd/pr-reviewer.service.tmpl     > "$UD/pr-reviewer.service"
    render init/systemd/pr-reviewer.timer.tmpl       > "$UD/pr-reviewer.timer"
    render init/systemd/pr-reviewer-web.service.tmpl > "$UD/pr-reviewer-web.service"
    loginctl enable-linger "$USER" 2>/dev/null || echo "?? enable-linger failed (services stop at logout); run: sudo loginctl enable-linger $USER"
    systemctl --user daemon-reload
    systemctl --user enable --now pr-reviewer.timer
    systemctl --user enable --now pr-reviewer-web.service
    echo "✔ systemd services installed + started"
    echo "  systemctl --user status pr-reviewer.timer pr-reviewer-web.service"
    ;;
  Darwin)
    LA="$HOME/Library/LaunchAgents"; mkdir -p "$LA"
    render init/launchd/com.claude-pr-reviewer.tick.plist.tmpl > "$LA/com.claude-pr-reviewer.tick.plist"
    render init/launchd/com.claude-pr-reviewer.web.plist.tmpl  > "$LA/com.claude-pr-reviewer.web.plist"
    for l in com.claude-pr-reviewer.tick com.claude-pr-reviewer.web; do
      launchctl unload "$LA/$l.plist" 2>/dev/null || true
      launchctl load  "$LA/$l.plist"
    done
    echo "✔ launchd agents installed + loaded"
    echo "  launchctl list | grep claude-pr-reviewer"
    ;;
  *) echo "!! unsupported OS: $OS — use bin/run-loop.sh with nohup instead"; exit 1;;
esac

echo "✔ dashboard: http://${WEB_HOST:-127.0.0.1}:${WEB_PORT:-8787}"
echo "  status:    bash bin/status.sh"
