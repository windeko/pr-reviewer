#!/usr/bin/env python3
"""claude-pr-reviewer — dashboard + on-demand trigger.

Read-only view of the bot's state plus a form to paste a PR number and run a
review on demand. Localhost by default. Python stdlib only, no dependencies.

    GET  /            status page (auto-refresh)
    POST /run  pr=N   spawn bin/review-one.sh N (detached), redirect back

The trigger reuses the exact bin/review-one.sh the scheduler calls, so a manual
run behaves identically (reactions, watch-state) — minus the Slack reaction,
since a pasted PR carries no message ts.

Config comes from ../.env (same file the shell scripts read) with env-var
overrides. Run directly (`python3 web/server.py`) or via systemd/launchd.
"""
import html
import os
import re
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_env(path):
    """Minimal .env loader — KEY=VALUE lines, does not override real env vars."""
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())
    except OSError:
        pass


load_env(os.path.join(ROOT, ".env"))

SLUG = os.environ.get("REPO_SLUG", "owner/repo")
DATA_DIR = os.path.expanduser(os.environ.get("DATA_DIR", "~/.local/state/claude-pr-reviewer"))
STATE = os.path.join(DATA_DIR, "state")
LOGS = os.path.join(DATA_DIR, "logs")
REVIEW_ONE = os.path.join(ROOT, "bin", "review-one.sh")
HOST = os.environ.get("WEB_HOST", "127.0.0.1")
PORT = int(os.environ.get("WEB_PORT", "8787"))


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def ago(epoch):
    try:
        d = int(time.time()) - int(epoch)
    except (ValueError, TypeError):
        return "never"
    if d < 60:
        return f"{d}s ago"
    if d < 3600:
        return f"{d // 60}m ago"
    return f"{d // 3600}h {d % 3600 // 60}m ago"


def watching():
    d = os.path.join(STATE, "watching")
    rows = []
    if os.path.isdir(d):
        for name in sorted(os.listdir(d), key=lambda n: int(n) if n.isdigit() else 0):
            if not name.isdigit():
                continue
            parts = read(os.path.join(d, name)).split()
            rows.append((name, parts[0][:8] if parts else "?"))
    return rows


def recent_reviews(limit=15):
    out = []
    if not os.path.isdir(LOGS):
        return out
    files = [f for f in os.listdir(LOGS) if re.fullmatch(r"review-\d+\.log", f)]
    files.sort(key=lambda f: os.path.getmtime(os.path.join(LOGS, f)), reverse=True)
    for f in files[:limit]:
        pr = f[len("review-"):-len(".log")]
        body = read(os.path.join(LOGS, f))
        verdict = body.splitlines()[-1] if body else "(empty)"
        out.append((pr, verdict[:160], ago(os.path.getmtime(os.path.join(LOGS, f)))))
    return out


def page(flash=""):
    paused = os.path.exists(os.path.join(STATE, "DISABLED"))
    last = ago(read(os.path.join(STATE, "last_tick"), "0"))
    handled = len([x for x in read(os.path.join(STATE, "seen_prs.txt")).splitlines() if x.strip()])
    floor = read(os.path.join(STATE, "floor"), os.environ.get("FLOOR", "0"))
    watch = watching()
    reviews = recent_reviews()
    logtail = "\n".join(read(os.path.join(LOGS, "daemon.log")).splitlines()[-30:])

    pill = ('<span class="pill bad">PAUSED</span>' if paused
            else '<span class="pill ok">enabled</span>')
    watch_rows = "".join(
        f'<tr><td><a href="https://github.com/{SLUG}/pull/{pr}" target="_blank">#{pr}</a></td>'
        f'<td class="mono">{sha}</td></tr>' for pr, sha in watch
    ) or '<tr><td colspan="2" class="dim">nothing awaiting re-review</td></tr>'
    rev_rows = "".join(
        f'<tr><td><a href="https://github.com/{SLUG}/pull/{pr}" target="_blank">#{pr}</a></td>'
        f'<td>{html.escape(v)}</td><td class="dim">{when}</td></tr>'
        for pr, v, when in reviews
    ) or '<tr><td colspan="3" class="dim">no reviews yet</td></tr>'
    flash_html = f'<div class="flash">{html.escape(flash)}</div>' if flash else ""

    return f"""<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="15">
<title>PR-review bot · {html.escape(SLUG)}</title><style>
:root{{color-scheme:light dark}}
body{{font:14px/1.5 system-ui,sans-serif;max-width:920px;margin:2rem auto;padding:0 1rem}}
h1{{font-size:1.3rem;margin:0 0 .3rem}} h3{{margin:1.4rem 0 .3rem}}
.bar{{display:flex;gap:1.2rem;align-items:center;flex-wrap:wrap;color:#888;margin-bottom:1rem}}
.pill{{padding:.1rem .55rem;border-radius:1rem;font-weight:600;font-size:.8rem}}
.ok{{background:#1a7f37;color:#fff}} .bad{{background:#b35900;color:#fff}}
form{{display:flex;gap:.5rem;margin:1rem 0;padding:1rem;border:1px solid #8884;border-radius:8px}}
input[type=number]{{flex:1;padding:.5rem;font:inherit;border:1px solid #8886;border-radius:6px;background:transparent;color:inherit}}
button{{padding:.5rem 1rem;font:inherit;font-weight:600;border:0;border-radius:6px;background:#1f6feb;color:#fff;cursor:pointer}}
table{{width:100%;border-collapse:collapse;margin:.3rem 0 1.4rem}}
th,td{{text-align:left;padding:.35rem .5rem;border-bottom:1px solid #8883;vertical-align:top}}
th{{font-size:.75rem;text-transform:uppercase;color:#888;letter-spacing:.03em}}
.mono{{font-family:ui-monospace,monospace}} .dim{{color:#999}}
pre{{background:#8881;padding:.8rem;border-radius:8px;overflow:auto;font-size:12px;max-height:320px}}
.flash{{background:#1f6feb22;border:1px solid #1f6feb88;padding:.5rem .8rem;border-radius:6px;margin-bottom:1rem}}
a{{color:#1f6feb}}
</style></head><body>
<h1>PR-review bot <span class="dim" style="font-size:.8rem">{html.escape(SLUG)}</span></h1>
<div class="bar">{pill}<span>last tick {last}</span><span>handled {handled}</span>
<span>floor {html.escape(str(floor))}</span><span>watching {len(watch)}</span></div>
{flash_html}
<form method="post" action="/run">
  <input type="number" name="pr" placeholder="PR number — e.g. 2140" min="1" required>
  <button type="submit">Run review</button>
</form>
<h3>Awaiting re-review</h3>
<table><tr><th>PR</th><th>reviewed SHA</th></tr>{watch_rows}</table>
<h3>Recent reviews</h3>
<table><tr><th>PR</th><th>verdict</th><th>when</th></tr>{rev_rows}</table>
<h3>Log</h3><pre>{html.escape(logtail)}</pre>
</body></html>"""


class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path != "/":
            return self._send(404, "not found", "text/plain")
        started = (parse_qs(query).get("started", [""])[0] or "").strip()
        flash = f"Started review of #{started} — refresh in a minute." if started.isdigit() else ""
        self._send(200, page(flash))

    def do_POST(self):
        if self.path != "/run":
            return self._send(404, "not found", "text/plain")
        n = int(self.headers.get("Content-Length", 0))
        pr = (parse_qs(self.rfile.read(n).decode()).get("pr", [""])[0] or "").strip()
        if not pr.isdigit():
            return self._send(400, "PR must be a number", "text/plain")
        subprocess.Popen(
            ["bash", REVIEW_ONE, pr, "", "manual"],
            stdout=open(os.path.join(LOGS, f"manual-{pr}.out"), "w"),
            stderr=subprocess.STDOUT, start_new_session=True,
        )
        self.send_response(303)
        self.send_header("Location", f"/?started={pr}")
        self.end_headers()

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    os.makedirs(LOGS, exist_ok=True)
    print(f"PR-review dashboard on http://{HOST}:{PORT}  (repo {SLUG})")
    ThreadingHTTPServer((HOST, PORT), H).serve_forever()
