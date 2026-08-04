#!/usr/bin/env bash
# Stop + remove the services. Leaves your state/logs (DATA_DIR) alone.
set -u
OS="$(uname -s)"
case "$OS" in
  Linux)
    systemctl --user disable --now pr-reviewer.timer pr-reviewer-web.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/pr-reviewer.service" \
          "$HOME/.config/systemd/user/pr-reviewer.timer" \
          "$HOME/.config/systemd/user/pr-reviewer-web.service"
    systemctl --user daemon-reload
    echo "✔ systemd services removed"
    ;;
  Darwin)
    LA="$HOME/Library/LaunchAgents"
    for l in com.claude-pr-reviewer.tick com.claude-pr-reviewer.web; do
      launchctl unload "$LA/$l.plist" 2>/dev/null || true
      rm -f "$LA/$l.plist"
    done
    echo "✔ launchd agents removed"
    ;;
  *) echo "nothing to do for $OS";;
esac
echo "state/logs kept. delete manually if you want: your DATA_DIR"
