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


def watching(limit=25):
    d = os.path.join(STATE, "watching")
    rows = []
    if os.path.isdir(d):
        names = sorted((n for n in os.listdir(d) if n.isdigit()), key=int, reverse=True)
        for name in names[:limit]:
            parts = read(os.path.join(d, name)).split()
            rows.append((name, parts[0][:8] if parts else "?"))
    return rows


def recent_reviews(limit=25):
    """PR -> (epoch, verdict text). Prefer structured verdict files; fall back to
    the raw review-log tail for anything reviewed before verdicts existed."""
    items = {}  # pr -> (epoch, text)
    vdir = os.path.join(STATE, "verdicts")
    if os.path.isdir(vdir):
        for name in os.listdir(vdir):
            if not name.isdigit():
                continue
            body = read(os.path.join(vdir, name))
            if "\t" not in body:
                continue
            ep, txt = body.split("\t", 1)
            try:
                ep = int(ep)
            except ValueError:
                ep = int(os.path.getmtime(os.path.join(vdir, name)))
            items[name] = (ep, txt)
    if os.path.isdir(LOGS):
        for f in os.listdir(LOGS):
            m = re.fullmatch(r"review-(\d+)\.log", f)
            if not m or m.group(1) in items:
                continue
            pr = m.group(1)
            body = read(os.path.join(LOGS, f))
            line = body.splitlines()[-1] if body else "(empty)"
            items[pr] = (int(os.path.getmtime(os.path.join(LOGS, f))), f"PR {pr}: {line[:150]}")
    rows = sorted(items.items(), key=lambda kv: kv[1][0], reverse=True)[:limit]
    return [(pr, txt, ago(ep)) for pr, (ep, txt) in rows]


def in_review():
    """PRs with an active per-PR review lock (being reviewed right now)."""
    if not os.path.isdir(STATE):
        return []
    out = [int(m.group(1)) for n in os.listdir(STATE)
           if (m := re.fullmatch(r"review-(\d+)\.lock", n))]
    return sorted(out)


def queued():
    """PRs found in the channel awaiting review, minus the ones in flight."""
    nums = sorted({int(x) for x in re.findall(r"\d+", read(os.path.join(STATE, "queue")))})
    active = set(in_review())
    return [n for n in nums if n not in active]


def page(flash=""):
    paused = os.path.exists(os.path.join(STATE, "DISABLED"))
    last = ago(read(os.path.join(STATE, "last_tick"), "0"))
    handled = len([x for x in read(os.path.join(STATE, "seen_prs.txt")).splitlines() if x.strip()])
    floor = read(os.path.join(STATE, "floor"), os.environ.get("FLOOR", "0"))
    watch = watching()
    reviews = recent_reviews()
    inrev = in_review()
    q = queued()
    logtail = "\n".join(read(os.path.join(LOGS, "daemon.log")).splitlines()[-200:])

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
    queue_rows = "".join(
        f'<tr><td><a href="https://github.com/{SLUG}/pull/{pr}" target="_blank">#{pr}</a></td>'
        f'<td>⏳ reviewing…</td></tr>' for pr in inrev
    ) + "".join(
        f'<tr><td><a href="https://github.com/{SLUG}/pull/{pr}" target="_blank">#{pr}</a></td>'
        f'<td class="dim">queued</td></tr>' for pr in q
    ) or '<tr><td colspan="2" class="dim">queue empty</td></tr>'
    flash_html = f'<div class="flash">{html.escape(flash)}</div>' if flash else ""

    return f"""<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="15">
<link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>🔍</text></svg>">
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
.scroll{{max-height:420px;overflow:auto;border:1px solid #8882;border-radius:8px}}
.scroll table{{margin:0}} .scroll th{{position:sticky;top:0;background:Canvas}}
pre{{background:#8881;padding:.8rem;border-radius:8px;overflow:auto;font-size:12px;max-height:460px}}
.flash{{background:#1f6feb22;border:1px solid #1f6feb88;padding:.5rem .8rem;border-radius:6px;margin-bottom:1rem}}
a{{color:#1f6feb}}
</style></head><body>
<h1>PR-review bot <span class="dim" style="font-size:.8rem">{html.escape(SLUG)}</span></h1>
<div class="bar">{pill}<span>last tick {last}</span><span>handled {handled}</span>
<span>floor {html.escape(str(floor))}</span><span>queue {len(inrev) + len(q)}</span><span>watching {len(watch)}</span></div>
{flash_html}
<form method="post" action="/run">
  <input type="number" name="pr" placeholder="PR number — e.g. 2140" min="1" required>
  <button type="submit">Run review</button>
</form>
<h3>Review queue</h3>
<div class="scroll"><table><tr><th>PR</th><th>status</th></tr>{queue_rows}</table></div>
<h3>Awaiting re-review</h3>
<div class="scroll"><table><tr><th>PR</th><th>reviewed SHA</th></tr>{watch_rows}</table></div>
<h3>Recent reviews</h3>
<div class="scroll"><table><tr><th>PR</th><th>verdict</th><th>when</th></tr>{rev_rows}</table></div>
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
