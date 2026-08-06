#!/usr/bin/env python3
"""claude-pr-reviewer — multi-repo dashboard + on-demand trigger.

One dashboard across every configured repo (instances/<name>.env), with a repo
tab bar. Each repo's state lives in its own DATA_DIR, so nothing collides. The
"Run review" form is scoped to the active repo and spawns that instance's
bin/review-one.sh (PRR_INSTANCE=<name>). Localhost, stdlib only.

    GET  /            active repo's dashboard (repo via ?repo=<name>)
    POST /run  repo,pr  spawn review-one for that repo (detached), redirect back
"""
import html
import os
import re
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REVIEW_ONE = os.path.join(ROOT, "bin", "review-one.sh")


def parse_env_file(path):
    d = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    d[k.strip()] = v.strip()
    except OSError:
        pass
    return d


def exp(p):
    return os.path.expanduser(p) if p else p


SHARED = parse_env_file(os.path.join(ROOT, ".env"))
STATE_ROOT = exp(SHARED.get("STATE_ROOT") or SHARED.get("DATA_DIR") or "~/.local/state/claude-pr-reviewer")
HOST = os.environ.get("WEB_HOST", SHARED.get("WEB_HOST", "127.0.0.1"))
PORT = int(os.environ.get("WEB_PORT", SHARED.get("WEB_PORT", "8787")))


def instances():
    """[(name, slug, data_dir)] — one per instances/<name>.env, else single-repo from .env."""
    out = []
    d = os.path.join(ROOT, "instances")
    if os.path.isdir(d):
        for f in sorted(os.listdir(d)):
            if f.endswith(".env") and f != "example.env":
                name = f[:-4]
                cfg = parse_env_file(os.path.join(d, f))
                dd = cfg.get("DATA_DIR") or os.path.join(STATE_ROOT, name)
                out.append((name, cfg.get("REPO_SLUG", "?"), exp(dd)))
    if not out:
        out.append(("default", SHARED.get("REPO_SLUG", "owner/repo"),
                    exp(SHARED.get("DATA_DIR") or STATE_ROOT)))
    return out


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


def in_review(st):
    if not os.path.isdir(st):
        return []
    return sorted(int(m.group(1)) for n in os.listdir(st)
                  if (m := re.fullmatch(r"review-(\d+)\.lock", n)))


def queue_items(st):
    """[(pr, status)] from the queue file, excluding in-flight (lock) PRs."""
    active = set(in_review(st))
    out = []
    for line in read(os.path.join(st, "queue")).splitlines():
        p = line.split()
        if p and p[0].isdigit() and int(p[0]) not in active:
            out.append((int(p[0]), p[1] if len(p) > 1 else "waiting"))
    return out


def watching(st, limit=25):
    d = os.path.join(st, "watching")
    rows = []
    if os.path.isdir(d):
        for name in sorted((n for n in os.listdir(d) if n.isdigit()), key=int, reverse=True)[:limit]:
            parts = read(os.path.join(d, name)).split()
            rows.append((name, parts[0][:8] if parts else "?"))
    return rows


def verdict_of(st, pr):
    """(epoch, author, text) from state/verdicts/<pr>, or None. Handles the older
    2-field format (no author) as well as the current 3-field one."""
    body = read(os.path.join(st, "verdicts", str(pr)))
    if not body or "\t" not in body:
        return None
    parts = body.split("\t")
    if len(parts) >= 3:
        ep, author, txt = parts[0], parts[1], "\t".join(parts[2:])
    else:
        ep, author, txt = parts[0], "", parts[1]
    try:
        ep = int(ep)
    except ValueError:
        ep = 0
    return ep, author, txt


def au(st, pr):
    v = verdict_of(st, pr)
    if v and v[1]:
        return v[1]
    return read(os.path.join(st, "authors", str(pr))) or "—"


def recent_reviews(st, limit=25):
    """Finished cycles only — one per verdict file; exclude anything running now."""
    items = {}
    active = set(in_review(st))
    vdir = os.path.join(st, "verdicts")
    if os.path.isdir(vdir):
        for name in os.listdir(vdir):
            if not name.isdigit() or int(name) in active:
                continue
            v = verdict_of(st, name)
            if not v:
                continue
            ep, author, txt = v
            if ep == 0:
                ep = int(os.path.getmtime(os.path.join(vdir, name)))
            items[name] = (ep, author, txt)
    rows = sorted(items.items(), key=lambda kv: kv[1][0], reverse=True)[:limit]
    return [(pr, author, txt, ago(ep)) for pr, (ep, author, txt) in rows]


def page(active, flash=""):
    insts = instances()
    names = [n for n, _, _ in insts]
    if active not in names:
        active = names[0]
    slug, dd = next((s, d) for n, s, d in insts if n == active)
    st, lg = os.path.join(dd, "state"), os.path.join(dd, "logs")

    paused = os.path.exists(os.path.join(st, "DISABLED"))
    last = ago(read(os.path.join(st, "last_tick"), "0"))
    handled = len([x for x in read(os.path.join(st, "seen_prs.txt")).splitlines() if x.strip()])
    floor = read(os.path.join(st, "floor"), "0")
    watch = watching(st)
    reviews = recent_reviews(st)
    inrev = in_review(st)
    items = queue_items(st)
    ready = [pr for pr, s in items if s in ("green", "none", "waiting")]
    ci_wait = [(pr, s) for pr, s in items if s in ("pending", "failing", "unknown")]
    logtail = "\n".join(reversed(read(os.path.join(lg, "daemon.log")).splitlines()[-200:]))

    pill = ('<span class="pill bad">PAUSED</span>' if paused
            else '<span class="pill ok">enabled</span>')
    tabs = "".join(
        f'<a class="tab{" act" if n == active else ""}" href="?repo={n}">{html.escape(n)}</a>'
        for n in names)
    link = f"https://github.com/{slug}/pull"
    queue_rows = "".join(
        f'<tr><td><a href="{link}/{pr}" target="_blank">#{pr}</a></td><td class="dim">{html.escape(au(st, pr))}</td><td>⏳ running</td></tr>' for pr in inrev
    ) + "".join(
        f'<tr><td><a href="{link}/{pr}" target="_blank">#{pr}</a></td><td class="dim">{html.escape(au(st, pr))}</td><td class="dim">queued</td></tr>' for pr in ready
    ) or '<tr><td colspan="3" class="dim">queue empty</td></tr>'
    cilab = {"pending": "⏳ CI pending", "failing": "🚫 CI failing", "unknown": "❔ CI unknown"}
    ci_rows = "".join(
        f'<tr><td><a href="{link}/{pr}" target="_blank">#{pr}</a></td><td class="dim">{html.escape(au(st, pr))}</td><td>{cilab.get(s, s)}</td></tr>'
        for pr, s in ci_wait
    ) or '<tr><td colspan="3" class="dim">nothing waiting on CI</td></tr>'
    watch_rows = "".join(
        f'<tr><td><a href="{link}/{pr}" target="_blank">#{pr}</a></td><td class="dim">{html.escape(au(st, pr))}</td><td class="mono">{sha}</td></tr>'
        for pr, sha in watch
    ) or '<tr><td colspan="3" class="dim">nothing awaiting re-review</td></tr>'
    rev_rows = "".join(
        f'<tr><td><a href="{link}/{pr}" target="_blank">#{pr}</a></td><td class="dim">{html.escape(author or "—")}</td><td>{html.escape(v)}</td>'
        f'<td class="dim nowrap">{when}</td></tr>' for pr, author, v, when in reviews
    ) or '<tr><td colspan="4" class="dim">no reviews yet</td></tr>'
    flash_html = f'<div class="flash">{html.escape(flash)}</div>' if flash else ""

    return f"""<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="15">
<link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>🔍</text></svg>">
<title>PR-review bot · {html.escape(slug)}</title><style>
:root{{color-scheme:light dark}}
body{{font:14px/1.5 system-ui,sans-serif;max-width:920px;margin:2rem auto;padding:0 1rem}}
h1{{font-size:1.3rem;margin:0 0 .3rem}} h3{{margin:1.4rem 0 .3rem}}
.tabs{{display:flex;gap:.3rem;flex-wrap:wrap;margin:.6rem 0}}
.tab{{padding:.25rem .7rem;border:1px solid #8884;border-radius:6px;text-decoration:none;color:inherit;font-size:.85rem}}
.tab.act{{background:#1f6feb;color:#fff;border-color:#1f6feb;font-weight:600}}
.bar{{display:flex;gap:1.2rem;align-items:center;flex-wrap:wrap;color:#888;margin-bottom:1rem}}
.pill{{padding:.1rem .55rem;border-radius:1rem;font-weight:600;font-size:.8rem}}
.ok{{background:#1a7f37;color:#fff}} .bad{{background:#b35900;color:#fff}}
form{{display:flex;gap:.5rem;margin:1rem 0;padding:1rem;border:1px solid #8884;border-radius:8px}}
input[type=number]{{flex:1;padding:.5rem;font:inherit;border:1px solid #8886;border-radius:6px;background:transparent;color:inherit}}
button{{padding:.5rem 1rem;font:inherit;font-weight:600;border:0;border-radius:6px;background:#1f6feb;color:#fff;cursor:pointer}}
table{{width:100%;border-collapse:collapse;margin:.3rem 0 1.4rem;table-layout:fixed}}
th,td{{text-align:left;padding:.35rem .5rem;border-bottom:1px solid #8883;vertical-align:top;overflow-wrap:anywhere}}
.nowrap{{white-space:nowrap}}
th{{font-size:.75rem;text-transform:uppercase;color:#888;letter-spacing:.03em}}
.mono{{font-family:ui-monospace,monospace}} .dim{{color:#999}}
.scroll{{max-height:420px;overflow:auto;border:1px solid #8882;border-radius:8px}}
.scroll table{{margin:0}} .scroll th{{position:sticky;top:0;background:Canvas}}
pre{{background:#8881;padding:.8rem;border-radius:8px;overflow:auto;font-size:12px;max-height:460px}}
.flash{{background:#1f6feb22;border:1px solid #1f6feb88;padding:.5rem .8rem;border-radius:6px;margin-bottom:1rem}}
a{{color:#1f6feb}}
</style></head><body>
<h1>PR-review bot <span class="dim" style="font-size:.8rem">{html.escape(slug)}</span></h1>
<div class="tabs">{tabs}</div>
<div class="bar">{pill}<span>last tick {last}</span><span>handled {handled}</span>
<span>floor {html.escape(str(floor))}</span><span>queue {len(inrev) + len(ready)}</span><span>CI-wait {len(ci_wait)}</span><span>watching {len(watch)}</span></div>
{flash_html}
<form method="post" action="/run">
  <input type="hidden" name="repo" value="{html.escape(active)}">
  <input type="number" name="pr" placeholder="PR number in {html.escape(slug)}" min="1" required>
  <button type="submit">Run review</button>
</form>
<h3>Review queue</h3>
<div class="scroll"><table><colgroup><col style="width:64px"><col style="width:140px"><col></colgroup><tr><th>PR</th><th>author</th><th>status</th></tr>{queue_rows}</table></div>
<h3>Waiting for CI</h3>
<div class="scroll"><table><colgroup><col style="width:64px"><col style="width:140px"><col></colgroup><tr><th>PR</th><th>author</th><th>CI</th></tr>{ci_rows}</table></div>
<h3>Awaiting re-review</h3>
<div class="scroll"><table><colgroup><col style="width:64px"><col style="width:140px"><col></colgroup><tr><th>PR</th><th>author</th><th>reviewed SHA</th></tr>{watch_rows}</table></div>
<h3>Recent reviews</h3>
<div class="scroll"><table><colgroup><col style="width:64px"><col style="width:130px"><col><col style="width:96px"></colgroup><tr><th>PR</th><th>author</th><th>verdict</th><th class="nowrap">when</th></tr>{rev_rows}</table></div>
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
        qs = parse_qs(query)
        active = (qs.get("repo", [""])[0] or "").strip()
        started = (qs.get("started", [""])[0] or "").strip()
        repo = (qs.get("in", [""])[0] or "").strip()
        flash = f"Started review of #{started} in {repo}." if started.isdigit() else ""
        self._send(200, page(active, flash))

    def do_POST(self):
        if self.path != "/run":
            return self._send(404, "not found", "text/plain")
        n = int(self.headers.get("Content-Length", 0))
        form = parse_qs(self.rfile.read(n).decode())
        pr = (form.get("pr", [""])[0] or "").strip()
        repo = (form.get("repo", [""])[0] or "").strip()
        known = {name for name, _, _ in instances()}
        if not pr.isdigit() or repo not in known:
            return self._send(400, "bad pr or repo", "text/plain")
        env = dict(os.environ, PRR_INSTANCE=("" if repo == "default" else repo))
        logs = os.path.join(next(d for nm, _, d in instances() if nm == repo), "logs")
        os.makedirs(logs, exist_ok=True)
        subprocess.Popen(
            ["bash", REVIEW_ONE, pr, "", "manual"], env=env,
            stdout=open(os.path.join(logs, f"manual-{pr}.out"), "w"),
            stderr=subprocess.STDOUT, start_new_session=True,
        )
        self.send_response(303)
        self.send_header("Location", f"/?repo={repo}&started={pr}&in={repo}")
        self.end_headers()

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print(f"PR-review dashboard on http://{HOST}:{PORT}  ({len(instances())} repo(s))")
    ThreadingHTTPServer((HOST, PORT), H).serve_forever()
