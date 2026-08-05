# pr-reviewer

An autonomous PR reviewer driven by [Claude Code](https://claude.com/claude-code).
It watches a Slack channel for pull-request review requests, and for each new one
it runs a breaking-change review and posts the result to GitHub — then reacts on
the Slack message (👀 reviewing, ✅ approved, 🚫 findings) and re-reviews when the
author pushes fixes. Ships with a small localhost dashboard where you can also
paste a PR number and run a review on demand.

Runs on **Linux** (systemd) and **macOS** (launchd). No native Windows; use WSL.

---

## How it works

```
 every ~3 min (systemd timer / launchd)          on demand
        │                                              │
        ▼                                              ▼
   bin/tick.sh                                   web dashboard  ── POST /run ─┐
        │  1. re-review watched PRs whose head SHA moved                      │
        │  2. read Slack channel → find new PR-review-requests                │
        └────────────────► bin/review-one.sh <PR> ◄──────────────────────────┘
                                 │
             claude -p ──────────┤ 👀 react → review (your skill or the
                                 │            built-in breaking-change prompt)
             gh ─────────────────┤ post GitHub review
                                 └ ✅ / 🚫 react → APPROVED unwatches,
                                                   findings → watch for re-review
```

State lives in `DATA_DIR` (default `~/.local/state/claude-pr-reviewer`):
`state/seen_prs.txt` (handled), `state/floor` (backlog cutoff), `state/watching/`
(PRs awaiting re-review), `logs/`.

---

## Prerequisites

You need these working **before** installing — the bot orchestrates them:

1. **Claude Code CLI** — installed and logged in (`claude` on PATH).
2. **A connected Slack MCP** in Claude Code — used to **read** the channel. Verify:
   `claude mcp list` shows a Slack server as ✔ Connected. (This is the one
   prerequisite that isn't a simple package install — set up the Slack integration
   in Claude Code first.) Reactions are separate and optional — see
   [Slack reactions](#slack-reactions-optional).
3. **GitHub CLI** — `gh auth status` shows you logged in with the **`repo`** scope
   (needed to post reviews). `gh auth refresh -s repo` if missing.
4. A **local checkout** of the repo you want reviewed (`REPO_DIR`).
5. **bash 4+** and **python3** (both standard on Linux; on macOS python3 ships with
   the Command Line Tools — `xcode-select --install`).

> ⚠️ This bot posts reviews to GitHub automatically and runs Claude in
> `--dangerously-skip-permissions` mode. Point it at a repo/channel you own, keep
> `WEB_HOST` on loopback, and start with a small `MAX_PER_TICK`.

---

## Install

```bash
git clone https://github.com/windeko/pr-reviewer.git
cd pr-reviewer
cp .env.example .env                       # shared defaults: CLIs, OWN_LOGIN, cadence, web
$EDITOR .env
cp instances/example.env instances/myrepo.env   # one file per repo
$EDITOR instances/myrepo.env               # REPO_SLUG, REPO_DIR, SLACK_CHANNEL
./install.sh --set-floor
```

Config is split: **`.env`** holds shared settings (CLI paths, `OWN_LOGIN`, cadence,
web bind, Slack token), and **`instances/<name>.env`** holds one repo's settings.
Each repo gets isolated state under `STATE_ROOT/<name>`.

`--set-floor` records each repo's current max PR number so the bot ignores the
existing backlog and only reviews PRs opened from now on. Drop it to review every
open request it sees (respecting `MAX_PER_TICK`).

`install.sh` detects your OS:

- **Linux** → `systemd --user` template timer per repo (`pr-reviewer@<name>`) + one web
  service, lingering enabled (survive logout/reboot).
- **macOS** → launchd agents in `~/Library/LaunchAgents` (one tick agent per repo + web).

Then open the dashboard: **http://127.0.0.1:8787** (one page, a tab per repo).

### Multiple repositories

Add another repo any time — one channel per repo:

```bash
cp instances/example.env instances/otherrepo.env
$EDITOR instances/otherrepo.env            # its own REPO_SLUG / REPO_DIR / SLACK_CHANNEL
./install.sh otherrepo --set-floor         # enable just that repo (web already running)
```

Each repo runs its own tick with isolated state (PR numbers never collide across
repos), and all show up as tabs on the single dashboard. `./install.sh` with no name
refreshes every repo.

### No systemd / launchd? Run the loop directly

```bash
nohup bin/run-loop.sh >/dev/null 2>&1 &     # ticks every INTERVAL_SECS
nohup python3 web/server.py >/dev/null 2>&1 &
```

---

## Configuration

**`instances/<name>.env`** — one per repo:

| Key | Meaning |
|---|---|
| `REPO_SLUG` | GitHub repo as `owner/name` (required) |
| `REPO_DIR` | Local checkout — review greps/reads files here (required) |
| `SLACK_CHANNEL` | Channel ID of this repo's PR-review-request channel (required) |
| `FLOOR` | Ignore PRs `<=` this number (backlog guard). `state/floor` overrides |
| `DATA_DIR` | Optional — override the default `STATE_ROOT/<name>` state dir |

**`.env`** — shared across all repos:

| Key | Meaning |
|---|---|
| `OWN_LOGIN` | Your GitHub login — bot skips your own PRs. Empty = review all |
| `REVIEW_SKILL` | A Claude Code skill to drive the review. Empty = built-in breaking-change prompt |
| `SLACK_BOT_TOKEN` | Optional `xoxb-` token w/ `reactions:write` for 👀/✅/🚫 reactions |
| `MAX_PER_TICK` | Cap reviews launched per tick (new + re-reviews) |
| `INTERVAL_SECS` | Seconds between ticks (loop/launchd; systemd uses it too) |
| `READ_COUNT` | Recent channel messages scanned per tick |
| `CLAUDE_BIN` / `GH_BIN` | **Absolute** CLI paths (services run with a minimal PATH) |
| `STATE_ROOT` | Base dir for per-repo state (`STATE_ROOT/<name>`) |
| `WEB_HOST` / `WEB_PORT` | Dashboard bind |

(Any shared key can be overridden per-repo by setting it in the instance file. A
key that was previously in `.env`, like `SLACK_BOT_TOKEN`, also works there.)
| `WEB_HOST` / `WEB_PORT` | Dashboard bind (keep host on loopback) |
---

## Slack reactions (optional)

Two modes, pick by whether you set `SLACK_BOT_TOKEN`:

- **No token (default, zero setup)** — Claude posts a **one-line threaded reply** on the
  request message (✅ approved / 🚫 changes) through the Slack MCP connector it already uses
  to read the channel. Nothing to configure.
- **With a bot token** — real **reactions** (👀 while reviewing, then ✅ / 🚫) via the Slack
  Web API in plain bash (`bin/slack-react.sh`), since the managed MCP connector can't add
  reactions. Cleaner/quieter than a reply. To enable:

1. Create a Slack app — https://api.slack.com/apps → **From scratch**, pick your workspace.
2. **OAuth & Permissions → Bot Token Scopes** → add `reactions:write`.
3. **Install to Workspace**, copy the **Bot User OAuth Token** (`xoxb-…`).
4. Invite the bot to your channel: in Slack, `/invite @your-app-name`.
5. Put it in `.env`: `SLACK_BOT_TOKEN=xoxb-…`, then restart the services.

Test: `bash bin/slack-react.sh add <message_ts> eyes` — returns silently and the 👀
appears in the channel. Leave `SLACK_BOT_TOKEN` empty to use the one-line-reply mode
instead (reviews always post to GitHub regardless).

---

## Usage

- **Dashboard** — `http://WEB_HOST:WEB_PORT`: status, watch-list, recent reviews,
  log tail, and a box to paste a PR number and run a review now. (A pasted PR has
  no Slack message, so a manual run posts the GitHub review but adds no reaction.)
- **Status** — `bash bin/status.sh`
- **Pause / resume** — `touch "$DATA_DIR/state/DISABLED"` / `rm` it
- **Re-review a PR** — remove its number from `state/seen_prs.txt` (and ensure it's `> floor`)
- **Logs** — `tail -f "$DATA_DIR/logs/daemon.log"`; per-PR: `logs/review-<N>.log`
- **Uninstall** — `./uninstall.sh` (keeps your state/logs)

### Service control

Linux:
```bash
systemctl --user status  pr-reviewer.timer pr-reviewer-web.service
systemctl --user restart pr-reviewer-web.service     # after editing web/server.py
journalctl --user -u pr-reviewer-web -f
```
macOS:
```bash
launchctl list | grep claude-pr-reviewer
launchctl unload ~/Library/LaunchAgents/com.claude-pr-reviewer.web.plist   # stop web
```

---

## Behavior notes

- **Only reviews new PRs.** The floor + `seen_prs.txt` mean it never re-reviews the
  backlog or the same commit twice. PR numbers are monotonic, so `> floor` is a
  reliable "opened after install" test even when old requests scroll into view.
- **Skips merged PRs** (nothing to post) and **your own PRs** (`OWN_LOGIN`).
- **Re-reviews on push.** A PR that gets findings is watched by head SHA; when the
  author pushes, the next tick runs another round. Approval stops the watching.
- **Never posts to Slack messages** except the three reactions; **never edits code.**
- A per-PR lock plus the tick lock prevent the scheduler and a manual run from
  double-reviewing the same PR.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `review-<N>.log` empty on a merged PR | Expected — merged PRs get a retrospective, no post |
| Reviews don't post | `gh auth status` needs `repo` scope; `gh auth refresh -s repo` |
| No reactions appear | `SLACK_BOT_TOKEN` unset, missing `reactions:write`, or bot not invited to the channel |
| Nothing happens | `bash bin/status.sh`; check `logs/daemon.err`; is it paused (`state/DISABLED`)? |
| Services die at logout (Linux) | `sudo loginctl enable-linger $USER` |
| macOS `stat`/`date` errors | You're on an old checkout — the scripts already handle BSD tools |

## License

MIT — see [LICENSE](LICENSE).
