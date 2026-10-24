#!/usr/bin/env python3
"""Activity log and filterable HTML report for pr-feedback-fixer.

  report.py add --thread ID --repo R --pr N --outcome O [--title T] [--url U] [--comment-url C] [--reply-url R]
                [--path P] [--reviewer L] [--sha S] [--note TEXT] [--at ISO8601]
  report.py render

LOG_FILE is an event log, one event per line. `add` appends a `classified`
event. `render` reads each thread from GitHub through `gh` (GH), appends an
`observed` event when the thread differs from its last snapshot, drops the
threads with no event in the last 30 days, and writes REPORT_FILE with the
events inlined. The page folds the events with store.js. It renders without
snapshots when GitHub can't be reached.
"""
import argparse, base64, hashlib, html, json, os, subprocess, sys
from datetime import datetime, timedelta, timezone

STATE_DIR = os.path.expanduser("~/.local/state/pr-feedback-fixer")
LOG_FILE = os.environ.get("LOG_FILE", os.path.join(STATE_DIR, "log.jsonl"))
REPORT_FILE = os.environ.get("REPORT_FILE", os.path.join(STATE_DIR, "report.html"))
GH = os.environ.get("GH", "gh")
CODE_DIR = os.environ.get("CODE_DIR", os.path.expanduser("~/apps"))
OUTCOMES = ["fixed", "already_fixed", "deferred", "question", "skipped"]
RENAMED = {"noted": "deferred"}
DAYS = 30
VERSION = "v1"
STORE_FILE = os.path.join(os.path.dirname(os.path.realpath(__file__)), "store.js")
THREAD_FIELDS = "isResolved isOutdated line startLine path comments(first: 50) { nodes { id author { login } body createdAt url diffHunk reactionGroups { content viewerHasReacted reactors { totalCount } } } }"


def now():
    return datetime.now(timezone.utc)


def ms(t):
    return int(t.timestamp() * 1000)


def event(object_id, action, data, time):
    return {"key": f"{time}/threads/{object_id}/{action}/{VERSION}", "time": time, "collection": "threads",
            "objectId": object_id, "action": action, "data": data, "version": VERSION}


def add(args):
    entry = {k: v for k, v in vars(args).items() if k != "cmd" and v is not None}
    entry.setdefault("at", now().isoformat(timespec="seconds"))
    time = ms(datetime.fromisoformat(entry["at"])) if args.at else ms(now())
    with open(LOG_FILE, "a") as f:
        f.write(json.dumps(event(args.thread, "classified", entry, time)) + "\n")


def read_events():
    """The log as events, oldest first. A line from before the log held events reads as a classified event."""
    if not os.path.exists(LOG_FILE):
        return []
    events, keys = [], set()
    with open(LOG_FILE) as f:
        for line in f:
            if not line.strip():
                continue
            e = json.loads(line)
            if "action" not in e:
                e = event(e["thread"], "classified", e, ms(datetime.fromisoformat(e["at"])))
                while e["key"] in keys:
                    e = event(e["objectId"], e["action"], e["data"], e["time"] + 1)
            if e["action"] == "classified":
                e["data"]["outcome"] = RENAMED.get(e["data"]["outcome"], e["data"]["outcome"])
            if e["key"] not in keys:
                keys.add(e["key"])
                events.append(e)
    return sorted(events, key=lambda e: (e["time"], e["key"]))


def prune(events):
    """Drops every event of a thread whose newest event is older than DAYS; keeps all events of the others."""
    newest = {}
    for e in events:
        newest[e["objectId"]] = max(newest.get(e["objectId"], 0), e["time"])
    cutoff = ms(now() - timedelta(days=DAYS))
    return [e for e in events if newest[e["objectId"]] >= cutoff]


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def to_ctx(node):
    comments = node["comments"]["nodes"]
    return {"resolved": node["isResolved"], "outdated": node["isOutdated"], "line": node["line"], "start_line": node.get("startLine"), "path": node["path"],
            "hunk": comments[0]["diffHunk"] if comments else "",
            "comments": [{"id": c.get("id"), "author": (c["author"] or {}).get("login"), "body": c["body"], "at": c["createdAt"], "url": c["url"],
                          "reactions": [{"content": g["content"], "count": g["reactors"]["totalCount"], "mine": g["viewerHasReacted"]}
                                        for g in c.get("reactionGroups") or [] if g["reactors"]["totalCount"]]}
                         for c in comments]}


def fetch_threads(ids):
    """Reads review threads from GitHub; returns {thread id: context}, partial or empty when GitHub fails."""
    ctx = {}
    for i in range(0, len(ids), 100):
        query = "{ nodes(ids: %s) { ... on PullRequestReviewThread { id %s } } }" % (json.dumps(ids[i:i + 100]), THREAD_FIELDS)
        try:
            out = subprocess.run([GH, "api", "graphql", "-f", "query=" + query], capture_output=True, text=True, timeout=60).stdout
            nodes = (json.loads(out).get("data") or {}).get("nodes") or []
        except (OSError, subprocess.SubprocessError, ValueError, AttributeError):
            return ctx
        for n in nodes:
            if n and "comments" in n:
                ctx[n["id"]] = to_ctx(n)
    return ctx


def my_login():
    """The login of the GitHub user `gh` is signed in as; empty when GitHub fails."""
    try:
        return subprocess.run([GH, "api", "user", "-q", ".login"], capture_output=True, text=True, timeout=60).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def repos(root, depth=3):
    """The git checkouts under root, at most depth levels down; does not look inside a checkout."""
    if os.path.isdir(os.path.join(root, ".git")):
        return [root]
    if depth == 0 or not os.path.isdir(root):
        return []
    return [r for d in os.listdir(root) if not d.startswith(".") for r in repos(os.path.join(root, d), depth - 1)]


def checkouts():
    """Map "owner/name" to the local checkout under CODE_DIR; the shortest directory name wins over suffixed copies."""
    found = {}
    for path in sorted(repos(CODE_DIR), key=lambda p: len(os.path.basename(p)), reverse=True):
        url = subprocess.run(["git", "-C", path, "config", "--get", "remote.origin.url"], capture_output=True, text=True).stdout.strip()
        if "github.com" in url:
            found[url.split("github.com")[1][1:].removesuffix(".git")] = path
    return found


def render():
    events = prune(read_events())
    latest = {e["objectId"]: e["data"] for e in events if e["action"] == "observed"}
    time = ms(now())
    for thread, ctx in fetch_threads(sorted({e["objectId"] for e in events if e["action"] == "classified"})).items():
        if thread not in latest or digest(latest[thread]) != digest(ctx):
            events.append(event(thread, "observed", ctx, time))
    lines = [json.dumps(e) + "\n" for e in events]
    with open(LOG_FILE, "w") as f:
        f.writelines(lines)
    jsonl = "".join(l.replace("<", "\\u003c") for l in lines)
    folders = json.dumps(checkouts()).replace("<", "\\u003c")
    with open(STORE_FILE) as f:
        store = f.read()
    script = store + (SCRIPT.replace("__OUTCOMES__", json.dumps(OUTCOMES)).replace("__ME__", json.dumps(my_login()))
                      .replace("__THREAD_FIELDS__", json.dumps(THREAD_FIELDS)))
    csp = base64.b64encode(hashlib.sha256(script.encode()).digest()).decode()
    page = (PAGE.replace("__CSP_HASH__", csp)
            .replace("__GENERATED__", html.escape(now().strftime("%Y-%m-%d %H:%M UTC"))))
    with open(REPORT_FILE, "w") as f:
        f.write(page.replace("__FOLDERS__", folders).replace("__SCRIPT__", script).replace("__ROWS__", jsonl))


PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'sha256-__CSP_HASH__'; style-src 'unsafe-inline'; img-src https://github.com https://avatars.githubusercontent.com; connect-src https://api.github.com; base-uri 'none'; form-action 'none'">
<title>PR Feedback Fixer</title><base target="_blank">
<style>
:root{color-scheme:light dark;--bg:#fff;--panel:#f8fafc;--fg:#0f172a;--muted:#475569;--line:#cbd5e1;--zebra:#f8fafc;--hover:#eef2ff;--focus:#2563eb;--on-focus:#fff;--link:#1d4ed8;
 --bubble:#f1f5f9;--bubble-me:#dbeafe;--add:#dcfce7;--del:#fee2e2;
 --fixed-bg:#dcfce7;--fixed-fg:#14532d;--deferred-bg:#fef3c7;--deferred-fg:#78350f;--question-bg:#dbeafe;--question-fg:#1e3a8a;--skipped-bg:#e2e8f0;--skipped-fg:#334155}
@media (prefers-color-scheme:dark){:root{--bg:#0b0f17;--panel:#111827;--fg:#f1f5f9;--muted:#a5b4c8;--line:#334155;--zebra:#111827;--hover:#1e293b;--focus:#60a5fa;--on-focus:#0b0f17;--link:#93c5fd;
 --bubble:#1e293b;--bubble-me:#1e3a8a;--add:rgba(34,197,94,.18);--del:rgba(239,68,68,.2);
 --fixed-bg:#14532d;--fixed-fg:#dcfce7;--deferred-bg:#713f12;--deferred-fg:#fef3c7;--question-bg:#1e3a8a;--question-fg:#dbeafe;--skipped-bg:#334155;--skipped-fg:#e2e8f0}}
*{box-sizing:border-box}
body{margin:0;padding:24px 16px 48px;background:var(--bg);color:var(--fg);font:15px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:1240px;margin:0 auto}
h1{font-size:22px;margin:0 0 4px}.sub{color:var(--muted);margin:0 0 20px;display:flex;flex-wrap:wrap;gap:8px 16px;align-items:center}
a{color:var(--link);text-underline-offset:2px}a:hover{text-decoration-thickness:2px}
:focus-visible{outline:3px solid var(--focus);outline-offset:2px;border-radius:4px}
.filters{display:grid;grid-template-columns:3fr repeat(2,minmax(150px,1fr));gap:12px;padding:16px;background:var(--panel);border:1px solid var(--line);border-radius:10px;margin-bottom:12px}
.field{display:flex;flex-direction:column;gap:4px}
label{font-size:13px;font-weight:600;color:var(--muted)}
input,select,textarea{font:inherit;color:inherit;background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:8px 10px;min-height:40px;width:100%}
textarea{border-radius:10px;resize:vertical}
.outcomes{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:0 0 16px;padding:0;border:0}
.outcomes legend{font-size:13px;font-weight:600;color:var(--muted);float:left;margin-right:4px}
.toggle{font:inherit;font-size:14px;font-weight:600;border:2px solid transparent;border-radius:999px;padding:4px 14px;cursor:pointer;min-height:36px}
.toggle[aria-pressed=false]{background:transparent!important;color:var(--muted)!important;border-color:var(--line);text-decoration:line-through}
.badge{display:inline-block;font-size:13px;font-weight:700;border-radius:999px;padding:2px 10px;white-space:nowrap}
.o-fixed,.o-already_fixed{background:var(--fixed-bg);color:var(--fixed-fg)}.o-deferred{background:var(--deferred-bg);color:var(--deferred-fg)}
.o-question{background:var(--question-bg);color:var(--question-fg)}.o-skipped{background:var(--skipped-bg);color:var(--skipped-fg)}
.btn{font:inherit;font-size:14px;font-weight:600;border:1px solid var(--line);background:var(--bg);color:var(--fg);border-radius:8px;padding:6px 12px;min-height:36px;cursor:pointer}
.btn:hover{background:var(--hover)}.btn.primary{background:var(--focus);border-color:var(--focus);color:var(--on-focus)}.btn:disabled{opacity:.5;cursor:wait}
.btn.small{min-height:30px;padding:3px 10px;font-size:13px;margin-top:8px}
.tools{margin-left:auto;display:flex;gap:6px}.btn.tool{margin-top:8px;min-height:32px;min-width:32px;padding:0;display:inline-grid;place-items:center}.btn.tool[hidden]{display:none}
.drop-zone{position:fixed;inset:0;z-index:20;display:grid;place-items:center;background:color-mix(in srgb,var(--bg) 85%,transparent);border:3px dashed var(--focus);font-size:20px;font-weight:600;pointer-events:none}.drop-zone[hidden]{display:none}
.wrap{border:1px solid var(--line);border-radius:10px;overflow:hidden}
table{width:100%;border-collapse:collapse}
caption{text-align:left;padding:10px 14px;font-weight:600;color:var(--muted);background:var(--panel);border-bottom:1px solid var(--line)}
th{position:sticky;top:0;z-index:1;background:var(--panel);text-align:left;font-size:13px;font-weight:700;color:var(--muted);padding:10px 14px;border-bottom:2px solid var(--line)}
td{padding:12px 14px;border-bottom:1px solid var(--line);vertical-align:top}
tbody tr.row:hover{background:var(--hover)}
tr.group th{position:static;background:var(--bg);color:var(--fg);font-size:15px;padding:16px 14px 10px;border-top:2px solid var(--line);border-bottom:1px solid var(--line)}
tbody:first-of-type tr.group th{border-top:0}
.group-head{display:flex;flex-wrap:wrap;gap:6px 12px;align-items:baseline}.group-head .pr-title{font-weight:400}
.counts{display:flex;gap:6px;flex-wrap:wrap;margin-left:auto}
tr.handled td{opacity:.55}
.who{display:flex;align-items:center;gap:10px;white-space:nowrap;text-align:left}
.pick{font:inherit;font-weight:inherit;color:var(--link);background:none;border:0;padding:2px 4px;margin:-2px -4px;border-radius:6px;cursor:pointer}
.pick:hover{background:var(--hover);text-decoration:underline;text-underline-offset:2px}
.who img{width:32px;height:32px;border-radius:50%;background:var(--line);flex:none}
.pr-title{color:var(--muted);font-size:14px}
code{font:13px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}
.note{margin-top:4px}
.meta,.actions,.detail-head{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.when{white-space:nowrap;color:var(--muted);font-size:14px}
.btn.ask{margin-left:auto;font-size:12px;padding:2px 8px;min-height:0;text-decoration:none;white-space:nowrap}
.empty{padding:32px;text-align:center;color:var(--muted)}
.detail-head{margin-bottom:10px}
pre.hunk{max-height:280px;overflow:auto;margin:0 0 18px;padding:8px 0;background:var(--bg);border:1px solid var(--line);border-radius:8px;font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
pre.hunk span{display:block;padding:0 12px;white-space:pre}.hunk .add{background:var(--add)}.hunk .del{background:var(--del)}.hunk .hh{color:var(--muted)}
.thread{display:flex;flex-direction:column;gap:14px}
.msg{display:flex;gap:12px;align-items:flex-end}.msg.me{flex-direction:row-reverse}
.msg>img{width:36px;height:36px;border-radius:50%;background:var(--line);flex:none}
.bubble{position:relative;background:var(--bubble);border:1px solid var(--line);border-radius:18px;padding:10px 14px;max-width:min(700px,85%);min-width:0}
.bubble::after{content:"";position:absolute;bottom:12px;width:12px;height:12px;background:inherit;border:inherit;transform:rotate(45deg)}
.msg:not(.me) .bubble{border-bottom-left-radius:6px}.msg:not(.me) .bubble::after{left:-7px;border-top:0;border-right:0}
.msg.me .bubble{background:var(--bubble-me);border-bottom-right-radius:6px}.msg.me .bubble::after{right:-7px;border-bottom:0;border-left:0}
.bubble-head{font-size:13px;margin-bottom:4px;display:flex;gap:8px;align-items:baseline}
.bubble .p{white-space:pre-wrap;overflow-wrap:anywhere}
.bubble pre{background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:8px 10px;overflow:auto;margin:6px 0;font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
.bubble pre.suggestion{padding:6px 0;margin:6px 0 0}
.code-label{font-size:12px;font-weight:700;color:var(--muted);margin-top:6px}
tr.row{cursor:pointer}tr.row.active{background:var(--hover);box-shadow:inset 4px 0 0 var(--focus)}
.open{font:inherit;color:inherit;background:none;border:0;padding:0;margin:0;text-align:left;cursor:pointer;display:block;width:100%}
.excerpt,.note{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.note{color:var(--muted);font-size:13px;margin-top:6px}.replies{color:var(--muted);font-size:13px;margin-top:4px}
dialog#drawer{margin:0 0 0 auto;inset:0 0 0 auto;height:100dvh;max-height:100dvh;width:min(760px,100vw);max-width:100vw;border:0;border-left:1px solid var(--line);border-radius:0;padding:0;background:var(--bg);color:var(--fg);flex-direction:column}
dialog#drawer[open]{display:flex;animation:slide .18s ease-out}
@keyframes slide{from{transform:translateX(48px);opacity:.3}}
@media (prefers-reduced-motion:reduce){dialog#drawer[open]{animation:none}}
dialog#drawer::backdrop{background:rgba(15,23,42,.35)}
.caught-up{margin:0 0 16px;padding:14px 18px;border-radius:12px;background:var(--fixed-bg);color:var(--fixed-fg);font-size:17px;font-weight:700}
.confetti{position:fixed;inset:0;pointer-events:none;overflow:hidden;z-index:10}
.confetti i{position:absolute;top:-16px;width:8px;height:14px;border-radius:2px;animation:fall linear forwards}
@keyframes fall{to{transform:translate(var(--x),105vh) rotate(var(--r))}}
dialog#history{margin:0 0 0 auto;inset:0 0 0 auto;height:100dvh;max-height:100dvh;width:min(480px,100vw);max-width:100vw;border:0;border-left:1px solid var(--line);border-radius:0;padding:0;flex-direction:column}
dialog#history[open]{display:flex;animation:slide .18s ease-out}dialog#history::backdrop{background:rgba(15,23,42,.35)}
dialog#history h2{margin:0;font-size:17px}dialog#history .close{margin-left:auto}
.hist-list{list-style:none;margin:0}.hist{padding:10px 0;border-bottom:1px solid var(--line)}
.hist .excerpt{display:block;font-size:14px;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.hist-meta{display:flex;gap:12px;align-items:center;font-size:13px;color:var(--muted)}.hist-meta .btn.small{margin:0 0 0 auto}
.drawer-head{padding:12px 20px 14px;border-bottom:1px solid var(--line);background:var(--panel)}
.drawer-head h2{font-size:17px;line-height:1.35;margin:10px 0 8px}.drawer-head .note{-webkit-line-clamp:4;font-size:14px}
.drawer-nav{display:flex;gap:6px;align-items:center}.drawer-nav .close{margin-left:auto}
.btn.icon{min-width:36px;padding:4px 8px}
.drawer-body{flex:1;overflow:auto;padding:18px 20px 24px}
.reply{padding:12px 20px 16px;border-top:1px solid var(--line);background:var(--panel)}
.reactions{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px;align-items:center}
.react{font:inherit;font-size:13px;line-height:1;border:1px solid var(--line);background:var(--bg);color:var(--fg);border-radius:999px;padding:5px 9px;cursor:pointer;min-height:28px}
.react:hover{background:var(--hover)}.react.mine{border-color:var(--focus);background:var(--question-bg);color:var(--question-fg)}
.picker{display:inline-flex;gap:4px;flex-wrap:wrap}.picker[hidden]{display:none}
.status{color:var(--muted);font-size:14px}
.resolved-mark{color:var(--fixed-fg);background:var(--fixed-bg);font-size:12px;font-weight:700;border-radius:999px;padding:2px 8px;white-space:nowrap}
tr.row.resolved .excerpt{color:var(--muted)}tr.row.resolved .who img{filter:grayscale(1);opacity:.7}
tr.row.resolved td:nth-child(2){background-image:linear-gradient(var(--fixed-bg),var(--fixed-bg));background-size:3px 100%;background-repeat:no-repeat}
.resolved-banner{margin:0 0 16px;padding:10px 14px;border-radius:10px;background:var(--fixed-bg);color:var(--fixed-fg);font-weight:700}
.is-resolved .thread,.is-resolved pre.hunk{opacity:.7}.is-resolved .msg>img{filter:grayscale(1)}
dialog{border:1px solid var(--line);border-radius:12px;background:var(--bg);color:var(--fg);max-width:500px;width:calc(100% - 32px);padding:20px 22px}
dialog::backdrop{background:rgba(15,23,42,.55)}dialog h2{margin:0 0 8px;font-size:18px}
.muted{color:var(--muted)}
@media (max-width:900px){.filters{grid-template-columns:1fr 1fr}.filters .field:first-child{grid-column:1/-1}}
@media (max-width:700px){thead{position:absolute;left:-9999px}table,tbody,tr,td,tr.group th{display:block}tr{padding:10px 14px;border-bottom:1px solid var(--line)}
 tr.row td{border:0;padding:4px 0;display:grid;grid-template-columns:90px 1fr;gap:8px}tr.row td::before{content:attr(data-label);font-size:13px;font-weight:600;color:var(--muted)}
 .bubble{max-width:100%}}
</style></head><body><main>
<h1>PR Feedback Fixer</h1><div class="sub"><span>The latest state of each review thread from the last 30 days. Generated __GENERATED__.</span><span class="status" id="logStatus"></span><span class="tools"><button type="button" class="btn icon tool" id="historyOpen" aria-label="History" title="History"><svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l3 2"/></svg></button><button type="button" class="btn icon tool" id="logPick" hidden aria-label="Load log file" title="Load log file"><svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg></button><button type="button" class="btn icon tool" id="forget" hidden aria-label="Forget GitHub token" title="Forget GitHub token"><svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="7.5" cy="15.5" r="3.5"/><path d="M10 13l9-9M16 7l2 2M14 9l2 2"/></svg></button></span></div>
<div id="dropZone" class="drop-zone" hidden><p>Drop log.jsonl to use it</p></div>
<div class="filters" role="search">
<div class="field"><label for="q">Search</label><input type="search" id="q" placeholder="Repository, title, comment, reviewer, commit"></div>
<div class="field"><label for="status">Status</label><select id="status"><option value="">All</option><option value="no" selected>Needs you</option><option value="yes">Handled</option></select></div>
<div class="field"><label for="since">Time range</label><select id="since"><option value="1h">Last hour</option><option value="4h">Last 4 hours</option><option value="8h">Last 8 hours</option><option value="1d">Last day</option><option value="2d">Last 2 days</option><option value="3d">Last 3 days</option><option value="7d">Last 7 days</option><option value="30d" selected>Last 30 days</option></select></div>
</div>
<fieldset class="outcomes" id="chips"><legend>Outcome</legend></fieldset>
<p id="caughtUp" class="caught-up" role="status" hidden>🎉 Nothing needs you.</p>
<div class="wrap"><table id="table">
<caption id="count" aria-live="polite"></caption>
<thead><tr><th scope="col">Reviewer</th><th scope="col">Feedback</th><th scope="col">Outcome</th><th scope="col">When</th></tr></thead>
</table></div>
</main>
<dialog id="drawer" aria-labelledby="drawerTitle"></dialog>
<dialog id="history" aria-labelledby="historyTitle"><header class="drawer-head"><div class="drawer-nav"><h2 id="historyTitle">My actions</h2><button type="button" class="btn icon close" data-close aria-label="Close">✕</button></div><p class="status" id="historyStatus" role="status"></p></header>
<ol class="drawer-body hist-list" id="historyList"></ol></dialog>
<dialog id="tokenDialog" aria-labelledby="tokenTitle"><h2 id="tokenTitle">GitHub token</h2>
<p>Paste a fine-grained personal access token with <strong>Pull requests: read and write</strong> on these repositories. The page keeps it in memory only. It is gone when you close or reload the page.</p>
<label for="tokenInput">Token</label><input id="tokenInput" type="password" autocomplete="off" spellcheck="false">
<div class="actions" style="margin-top:12px"><button type="button" class="btn primary" id="tokenUse">Use token</button><button type="button" class="btn" id="tokenCancel">Cancel</button>
<a href="https://github.com/settings/personal-access-tokens/new">Create a token</a></div></dialog>
<script type="application/jsonl" id="rows">
__ROWS__</script>
<script type="application/json" id="folders">
__FOLDERS__</script>
<script>__SCRIPT__</script></body></html>
"""

SCRIPT = r"""
const OUTCOMES=__OUTCOMES__, on=new Set(OUTCOMES);
const ME=__ME__, THREAD_FIELDS=__THREAD_FIELDS__, FOLDERS=JSON.parse(document.getElementById("folders").textContent);
const $=id=>document.getElementById(id), esc=s=>String(s??"").replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const label=o=>o.replace("_"," ").replace(/^./,c=>c.toUpperCase());
const drafts=new Map(), handled=r=>PFF.handled(r,ME);
const EMOJI={THUMBS_UP:"👍",THUMBS_DOWN:"👎",LAUGH:"😄",HOORAY:"🎉",CONFUSED:"😕",HEART:"❤️",ROCKET:"🚀",EYES:"👀"};
let active=null, current=[];
const excerpt=r=>{const c=r.ctx,m=c&&(c.comments.find(x=>x.author!==ME)||c.comments[0]);return m?String(m.body||"").replace(/```[\s\S]*?```/g," ").replace(/\s+/g," ").trim():""};
// The log's events plus the page's own: what GitHub answered after this page acted. Merged by key.
const store=new PFF.EventStore(), EKEY="pr-feedback-fixer:events", KEEP=30*864e5;
let pageEvents=[];try{pageEvents=JSON.parse(localStorage.getItem(EKEY)||"[]").filter(e=>e&&e.time>=Date.now()-KEEP)}catch(e){}
store.restore(PFF.parseJsonl(document.getElementById("rows").textContent));store.restore(pageEvents);
let ROWS=[], byId=new Map(), HIST=[];
function rebuild(){const s=store.state();ROWS=PFF.threads(s);ROWS.forEach(r=>{r.excerpt=excerpt(r);r.folder=FOLDERS[r.repo]});byId=new Map(ROWS.map(r=>[r.thread,r]));HIST=PFF.history(s,ME)}
rebuild();
function observe(t,ctx){const r=byId.get(t);if(r&&r.ctx&&PFF.stable(r.ctx)===PFF.stable(ctx))return;
 const e=PFF.event(t,"observed",ctx);store.track(e);pageEvents=[...pageEvents.filter(x=>x.time>=Date.now()-KEEP),e];try{localStorage.setItem(EKEY,JSON.stringify(pageEvents))}catch(err){}}
let token=null;
const HLABEL={reply:"Replied",unreply:"Deleted reply",resolve:"Resolved",unresolve:"Unresolved",react:"Reacted",unreact:"Removed reaction"};
const FKEY="pr-feedback-fixer:filters", FIELDS=["q","status","since"];
function saveFilters(){try{localStorage.setItem(FKEY,JSON.stringify({...Object.fromEntries(FIELDS.map(id=>[id,$(id).value])),outcomes:[...on]}))}catch(e){}}
try{const f=JSON.parse(localStorage.getItem(FKEY)||"null");if(f){FIELDS.forEach(id=>{if(f[id]!=null&&[...($(id).options||[{value:f[id]}])].some(o=>o.value==f[id]))$(id).value=f[id]});
 if(Array.isArray(f.outcomes)){on.clear();f.outcomes.forEach(o=>on.add(o))}}}catch(e){}
document.addEventListener("error",e=>{if(e.target.tagName==="IMG")e.target.style.visibility="hidden"},true);
const chips=new Map();
OUTCOMES.forEach(o=>{const c=document.createElement("button");chips.set(o,c);c.type="button";c.className="toggle o-"+o;
 c.setAttribute("aria-pressed",on.has(o));
 c.onclick=()=>{on.has(o)?on.delete(o):on.add(o);c.setAttribute("aria-pressed",on.has(o));saveFilters();draw()};$("chips").append(c)});
const rel=t=>{const m=(Date.now()-Date.parse(t))/6e4;return m<60?Math.max(1,Math.round(m))+" min ago":m<1440?Math.round(m/60)+" h ago":Math.round(m/1440)+" d ago"};
const avatar=(l,s)=>l?`<img src="https://github.com/${encodeURIComponent(l)}.png?size=${s*2}" alt="" width="${s}" height="${s}" loading="lazy">`:"";
function md(s,c){const parts=esc(String(s??"").replace(/\r\n/g,"\n")).split(/^```(\w*)\n([\s\S]*?)^```$/m);
 return parts.map((x,i)=>i%3==0?(x.trim()?`<div class="p">${x.trim().replace(/`([^`\n]+)`/g,"<code>$1</code>")}</div>`:"")
  :i%3==1?"":parts[i-1]=="suggestion"?suggestion(x,c):`<pre>${x}</pre>`).join("")}
function suggestion(x,c){const n=c&&c.line&&c.start_line?c.line-c.start_line+1:1,old=c&&c.hunk?c.hunk.split("\n").slice(-n).map(l=>esc(l.slice(1))):[];
 const add=x.replace(/\n$/,"").split("\n").filter((l,i,a)=>a.length>1||l!=="");
 return `<div class="code-label">Suggested change${add.length?"":": remove "+(n>1?"these lines":"this line")}</div><pre class="hunk suggestion">${old.map(l=>`<span class="del">-${l||" "}</span>`).join("")}${add.map(l=>`<span class="add">+${l||" "}</span>`).join("")}</pre>`}
const hunk=h=>h.split("\n").slice(-20).map(l=>`<span class="${l[0]=="+"?"add":l[0]=="-"?"del":l.startsWith("@@")?"hh":""}">${esc(l)||" "}</span>`).join("");
function toCtx(n){const cs=n.comments.nodes;return{resolved:n.isResolved,outdated:n.isOutdated,line:n.line,start_line:n.startLine,path:n.path,hunk:cs[0]?cs[0].diffHunk:"",
 comments:cs.map(c=>({id:c.id,author:c.author&&c.author.login,body:c.body,at:c.createdAt,url:c.url,
  reactions:(c.reactionGroups||[]).filter(g=>g.reactors.totalCount).map(g=>({content:g.content,count:g.reactors.totalCount,mine:g.viewerHasReacted}))}))}}
const rlabel=k=>label(k.toLowerCase());
const claudeUrl=(u,f)=>"claude://code/new?q="+encodeURIComponent("Let's discuss this comment: "+u)+(f?"&folder="+encodeURIComponent(f):"");
function reactionsHtml(m,i){if(!m.id)return "";const rs=m.reactions||[];
 return `<div class="reactions">${rs.map(x=>`<button type="button" class="react${x.mine?" mine":""}" data-react="${esc(x.content)}" data-c="${i}" aria-pressed="${!!x.mine}" aria-label="${esc(rlabel(x.content))}, ${x.count}">${EMOJI[x.content]||esc(x.content)} ${x.count}</button>`).join("")}<button type="button" class="react" data-picker aria-expanded="false" aria-label="Add a reaction">☺ +</button><span class="picker" hidden>${Object.keys(EMOJI).map(k=>`<button type="button" class="react" data-react="${k}" data-c="${i}" aria-label="${esc(rlabel(k))}">${EMOJI[k]}</button>`).join("")}</span></div>`}
function drawerHtml(r){const c=r.ctx,i=current.indexOf(r.thread),id=esc(r.thread);
 return `<header class="drawer-head"><div class="drawer-nav"><button type="button" class="btn icon" data-nav="-1" aria-label="Previous thread"${i<=0?" disabled":""}>↑</button><button type="button" class="btn icon" data-nav="1" aria-label="Next thread"${i<0||i>=current.length-1?" disabled":""}>↓</button>${i>=0?`<span class="muted">${i+1} of ${current.length}</span>`:""}<button type="button" class="btn icon close" data-close aria-label="Close">✕</button></div>
  <h2 id="drawerTitle"><a href="${esc(r.url)}">${esc(r.repo)}#${esc(r.pr)}</a> ${esc(r.title)}</h2>
  <div class="detail-head"><span class="badge o-${esc(r.outcome)}">${esc(label(r.outcome))}</span>${c&&c.outdated?'<span class="badge o-skipped">Outdated</span>':""}${r.sha?`<a href="${esc(r.url)}/commits/${esc(r.sha)}"><code>${esc(r.sha)}</code></a>`:""}<code>${esc((c&&c.path)||r.path||"")}${c&&c.line?":"+esc(c.line):""}</code><a href="${esc(r.comment_url||r.url)}">Open on GitHub</a></div>
  ${r.note?`<div class="note">${esc(r.note)}</div>`:""}</header>
 <div class="drawer-body${c&&c.resolved?" is-resolved":""}">${c&&c.resolved?'<p class="resolved-banner">✓ This thread is resolved.</p>':""}${c?`${c.hunk?`<pre class="hunk" aria-label="Code around the comment">${hunk(c.hunk)}</pre>`:""}
  <div class="thread">${c.comments.map((m,i)=>`<div class="msg${m.author===ME?" me":""}">${avatar(m.author,36)}<div class="bubble"><div class="bubble-head"><strong>${esc(m.author||"ghost")}</strong><a class="when" href="${esc(m.url)}">${esc(rel(m.at))}</a>${m.url?`<a class="btn ask" href="${esc(claudeUrl(m.url,r.folder))}" target="_self" title="Start a Claude Code session on this comment">Open in Claude</a>`:""}</div>${md(m.body,c)}${reactionsHtml(m,i)}</div></div>`).join("")}</div>`
  :`<p class="muted">The thread loads the next time the report builds, or press Refresh.</p>`}</div>
 <footer class="reply" data-thread="${id}"><label for="reply-text">Reply as ${esc(ME)}</label><textarea id="reply-text" rows="3" data-draft="${id}">${esc(drafts.get(r.thread)||"")}</textarea>
  <div class="actions"><button type="button" class="btn primary" data-act="reply">Reply</button>${c&&c.resolved?"":`<button type="button" class="btn" data-act="reply-resolve">Reply and resolve</button><button type="button" class="btn" data-act="resolve">Resolve</button>`}<button type="button" class="btn" data-act="refresh">Refresh</button><span class="status" role="status"></span></div></footer>`}
function openDrawer(t,focus){active=t;const d=$("drawer");d.innerHTML=drawerHtml(byId.get(t));if(!d.open)d.showModal();
 const h=d.querySelector("pre.hunk");if(h)h.scrollTop=h.scrollHeight;
 const f=focus&&d.querySelector(focus);(f&&!f.disabled?f:d.querySelector("[data-close]")).focus();
 document.querySelectorAll("tr.row").forEach(tr=>tr.classList.toggle("active",tr.dataset.thread===t))}
function nav(step){const i=current.indexOf(active)+step;if(i>=0&&i<current.length)openDrawer(current[i],`[data-nav="${step}"]`)}
function status(msg){const s=$("drawer").querySelector(".status");if(s)s.textContent=msg}
let wasLeft=null;
function celebrate(){const left=ROWS.filter(r=>!handled(r)).length;$("caughtUp").hidden=left>0;if(left===0&&wasLeft>0)confetti();wasLeft=left}
function confetti(){if(matchMedia("(prefers-reduced-motion: reduce)").matches)return;
 const box=document.createElement("div"),colors=["#f43f5e","#f59e0b","#10b981","#3b82f6","#a855f7"];box.className="confetti";box.setAttribute("aria-hidden","true");
 for(let i=0;i<140;i++){const p=document.createElement("i");p.style.left=Math.random()*100+"vw";p.style.background=colors[i%colors.length];
  p.style.animationDelay=Math.random()*.7+"s";p.style.animationDuration=2+Math.random()*1.6+"s";p.style.setProperty("--x",(Math.random()-.5)*240+"px");p.style.setProperty("--r",(Math.random()*4-2)*360+"deg");box.append(p)}
 (document.querySelector("dialog[open]")||document.body).append(box);setTimeout(()=>box.remove(),4800)}
function draw(){celebrate();chips.forEach((c,o)=>c.textContent=label(o)+" ("+ROWS.filter(r=>r.outcome==o).length+")");const q=$("q").value.toLowerCase(),v=$("since").value,since=Date.now()-parseInt(v)*(v.endsWith("h")?36e5:864e5);
 const rs=ROWS.filter(r=>on.has(r.outcome)&&
  (!$("status").value||handled(r)==($("status").value=="yes"))&&Date.parse(r.at)>=since
  &&(!q||[r.repo,r.repo+"#"+r.pr,r.title,r.path,r.note,r.reviewer,r.sha,r.excerpt].join(" ").toLowerCase().includes(q)));
 $("count").textContent="Showing "+rs.length+" of "+ROWS.length+" threads in "+new Set(rs.map(r=>r.repo+"#"+r.pr)).size+" pull requests";
 const groups=new Map();rs.forEach(r=>{const k=r.repo+"#"+r.pr;groups.has(k)||groups.set(k,[]);groups.get(k).push(r)});
 current=[...groups.values()].flat().map(r=>r.thread);
 $("table").querySelectorAll("tbody").forEach(b=>b.remove());
 $("table").insertAdjacentHTML("beforeend",rs.length?[...groups.values()].map(g=>{const p=g[0],counts=OUTCOMES.map(o=>[o,g.filter(r=>r.outcome==o).length]).filter(([,n])=>n);
  return `<tbody><tr class="group"><th scope="rowgroup" colspan="4"><div class="group-head"><span><button type="button" class="pick" data-field="q" data-value="${esc(p.repo)}" title="Search for ${esc(p.repo)}">${esc(p.repo)}</button> <a href="${esc(p.url)}">#${esc(p.pr)}</a></span><span class="pr-title">${esc(p.title)}</span>
  <span class="counts">${counts.map(([o,n])=>`<span class="badge o-${o}">${n} ${esc(label(o).toLowerCase())}</span>`).join("")}</span></div></th></tr>`+g.map(r=>{const d=handled(r),n=r.ctx?r.ctx.comments.length:0;
  return `<tr class="row${d?" handled":""}${r.ctx&&r.ctx.resolved?" resolved":""}${r.thread===active?" active":""}" data-thread="${esc(r.thread)}">
  <td data-label="Reviewer"><button type="button" class="who pick" data-field="q" data-value="${esc(r.reviewer)}" title="Search for ${esc(r.reviewer||"Unknown")}">${avatar(r.reviewer,32)}${esc(r.reviewer||"Unknown")}</button></td>
  <td data-label="Feedback"><button type="button" class="open" data-open="${esc(r.thread)}"><span class="excerpt">${esc(r.excerpt||r.note||"Open the thread")}</span></button>${n>1?`<div class="replies">${n} comments</div>`:""}</td>
  <td data-label="Outcome"><div class="meta"><span class="badge o-${esc(r.outcome)}">${esc(label(r.outcome))}</span>${r.ctx&&r.ctx.resolved?'<span class="resolved-mark">✓ Resolved</span>':""}</div>${r.note?`<div class="note">${esc(r.note)}</div>`:""}</td>
  <td data-label="When"><time class="when" datetime="${esc(r.at)}" title="${esc(new Date(r.at).toLocaleString())}">${esc(rel(r.at))}</time></td></tr>`}).join("")+`</tbody>`}).join("")
  :`<tbody><tr><td colspan="4" class="empty">No threads match these filters.</td></tr></tbody>`)}
function updateTokenUi(){$("forget").hidden=!token}
$("forget").addEventListener("click",()=>{token=null;updateTokenUi()});
function getToken(){if(token)return Promise.resolve(token);const dl=$("tokenDialog"),inp=$("tokenInput");inp.value="";dl.showModal();inp.focus();
 return new Promise(res=>{const done=ok=>{dl.close();if(ok&&inp.value.trim()){token=inp.value.trim();updateTokenUi()}inp.value="";res(token)};
  $("tokenUse").onclick=()=>done(true);$("tokenCancel").onclick=()=>done(false);dl.oncancel=e=>{e.preventDefault();done(false)};
  inp.onkeydown=e=>{if(e.key==="Enter"){e.preventDefault();done(true)}}})}
async function gql(query,variables){const res=await fetch("https://api.github.com/graphql",{method:"POST",headers:{Authorization:"Bearer "+token,"Content-Type":"application/json"},body:JSON.stringify({query,variables})});
 if(res.status===401){token=null;updateTokenUi();throw new Error("GitHub rejected the token. Nothing was sent.")}
 const j=await res.json().catch(()=>({}));if(!res.ok||j.errors)throw new Error("GitHub error: "+((j.errors&&j.errors[0].message)||res.status));return j.data}
const DONE={reply:"Reply posted.","reply-resolve":"Reply posted and thread resolved.",resolve:"Thread resolved.",refresh:"Thread refreshed."};
function refreshViews(t,msg,focus){draw();if(byId.has(t))openDrawer(t,focus);if(msg)status(msg)}
// Commands act on GitHub, then track what GitHub answers. State only ever comes from the store.
async function reobserve(t){const d=await gql("query($t:ID!){node(id:$t){... on PullRequestReviewThread{"+THREAD_FIELDS+"}}}",{t});if(d.node)observe(t,toCtx(d.node));rebuild()}
async function act(btn){const t=active,ta=$("reply-text"),a=btn.dataset.act,body=ta.value.trim();
 if(a.startsWith("reply")&&!body){status("Write a reply first.");ta.focus();return}
 if(!await getToken()){status("No token. Nothing was sent.");return}
 const buttons=$("drawer").querySelectorAll(".reply button");buttons.forEach(b=>b.disabled=true);status("Working…");
 try{if(a.startsWith("reply")){await gql("mutation($t:ID!,$b:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$t,body:$b}){comment{id}}}",{t,b:body});drafts.delete(t)}
  if(a.endsWith("resolve"))await gql("mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}",{t});
  await reobserve(t);refreshViews(t,DONE[a])
 }catch(err){status(err.message);buttons.forEach(b=>b.disabled=false)}}
const reactMutation=add=>`mutation($s:ID!,$c:ReactionContent!){${add?"addReaction":"removeReaction"}(input:{subjectId:$s,content:$c}){reaction{content}}}`;
async function react(btn){const t=active,m=byId.get(t).ctx.comments[+btn.dataset.c],k=btn.dataset.react,x=(m.reactions||[]).find(z=>z.content===k),mine=!!(x&&x.mine);
 if(!await getToken()){status("No token. Nothing was sent.");return}
 btn.disabled=true;
 try{await gql(reactMutation(!mine),{s:m.id,c:k});await reobserve(t);
  refreshViews(t,(mine?"Removed ":"Added ")+rlabel(k).toLowerCase()+".")
 }catch(err){status(err.message);btn.disabled=false}}
function drawHistory(){$("historyList").innerHTML=HIST.length?HIST.map((h,i)=>{const r=byId.get(h.thread);
 return `<li class="hist"><div><strong>${esc(HLABEL[h.kind]||h.kind)}</strong>${h.content?" "+(EMOJI[h.content]||esc(h.content)):""} on <button type="button" class="pick" data-thread="${esc(h.thread)}">${r?esc(r.repo+"#"+r.pr):"a thread"}</button>${r&&r.title?` <span class="muted">${esc(r.title)}</span>`:""}</div>
  ${h.body?`<span class="excerpt">${esc(h.body)}</span>`:""}<div class="hist-meta"><time datetime="${esc(h.at)}" title="${esc(new Date(h.at).toLocaleString())}">${esc(rel(h.at))}</time>${h.url?`<a href="${esc(h.url)}">Open on GitHub</a>`:""}${h.undoable?`<button type="button" class="btn small" data-undo="${i}">Undo</button>`:""}</div></li>`}).join("")
 :'<li class="muted">No actions yet. Replies, resolves, and reactions show here.</li>'}
function hstatus(msg){$("historyStatus").textContent=msg}
async function undo(btn){const h=HIST[+btn.dataset.undo];
 if(!await getToken()){hstatus("No token. Nothing was sent.");return}
 btn.disabled=true;hstatus("Undoing…");
 try{if(h.kind==="reply")await gql("mutation($id:ID!){deletePullRequestReviewComment(input:{id:$id}){clientMutationId}}",{id:h.comment});
  if(h.kind==="resolve")await gql("mutation($t:ID!){unresolveReviewThread(input:{threadId:$t}){thread{isResolved}}}",{t:h.thread});
  if(h.kind.endsWith("react"))await gql(reactMutation(h.kind==="unreact"),{s:h.comment,c:h.content});
  await reobserve(h.thread);draw();drawHistory();hstatus("Undid: "+(HLABEL[h.kind]||h.kind).toLowerCase()+".")
 }catch(err){hstatus(err.message);btn.disabled=false}}
const histPane=$("history");
$("historyOpen").addEventListener("click",()=>{hstatus("");drawHistory();histPane.showModal();histPane.querySelector("[data-close]").focus()});
histPane.addEventListener("click",e=>{if(e.target===histPane||e.target.closest("[data-close]")){histPane.close();return}
 const u=e.target.closest("[data-undo]");if(u){undo(u);return}
 const p=e.target.closest("[data-thread]");if(p&&byId.has(p.dataset.thread)){histPane.close();openDrawer(p.dataset.thread)}});
$("table").addEventListener("click",e=>{
 const b=e.target.closest(".pick");if(b){if(b.dataset.value){$(b.dataset.field).value=b.dataset.value;saveFilters();draw();$(b.dataset.field).focus()}return}
 if(e.target.closest("a,input"))return;
 const tr=e.target.closest("tr.row");if(tr)openDrawer(tr.dataset.thread)});
const drawer=$("drawer");
drawer.addEventListener("click",e=>{if(e.target===drawer){drawer.close();return}
 const n=e.target.closest("[data-nav]");if(n){nav(+n.dataset.nav);return}
 if(e.target.closest("[data-close]")){drawer.close();return}
 const p=e.target.closest("[data-picker]");if(p){const k=p.nextElementSibling;k.hidden=!k.hidden;p.setAttribute("aria-expanded",!k.hidden);if(!k.hidden)k.querySelector("button").focus();return}
 const rb=e.target.closest("[data-react]");if(rb){react(rb);return}
 const ab=e.target.closest("[data-act]");if(ab)act(ab)});
drawer.addEventListener("input",e=>{const t=e.target.dataset.draft;if(t)drafts.set(t,e.target.value)});
drawer.addEventListener("keydown",e=>{if(e.target.closest("textarea,input"))return;if(e.key==="j"||e.key==="ArrowDown"&&e.altKey)nav(1);if(e.key==="k"||e.key==="ArrowUp"&&e.altKey)nav(-1)});
drawer.addEventListener("close",()=>{const t=active;active=null;document.querySelectorAll("tr.row.active").forEach(tr=>tr.classList.remove("active"));
 const o=document.querySelector(`[data-open="${CSS.escape(t||"")}"]`);if(o)o.focus()});
// Reload: a picked or dropped log file is re-read every 30 seconds and its new events merged in. The handle lives in IndexedDB.
const IDB={open:()=>new Promise((res,rej)=>{const q=indexedDB.open("pr-feedback-fixer",1);q.onupgradeneeded=()=>q.result.createObjectStore("handles");q.onsuccess=()=>res(q.result);q.onerror=()=>rej(q.error)}),
 get:async k=>{const db=await IDB.open();return new Promise(res=>{const q=db.transaction("handles").objectStore("handles").get(k);q.onsuccess=()=>res(q.result);q.onerror=()=>res(null)})},
 set:async(k,v)=>{const db=await IDB.open();return new Promise(res=>{const tx=db.transaction("handles","readwrite");tx.objectStore("handles").put(v,k);tx.oncomplete=tx.onerror=()=>res()})}};
let logHandle=null, savedHandle=null, logStamp=0, polling=null;
function redraw(){draw();if(histPane.open)drawHistory();
 const typing=document.activeElement&&document.activeElement.matches("#drawer textarea");if(active&&byId.has(active)&&!typing)openDrawer(active)}
const logStatus=t=>$("logStatus").textContent=t;
async function pollLog(){if(!logHandle)return;try{const f=await logHandle.getFile();if(f.lastModified!==logStamp){logStamp=f.lastModified;
 if(store.restore(PFF.parseJsonl(await f.text()))){rebuild();redraw()}}logStatus("Using "+f.name+" · updated "+rel(new Date(f.lastModified).toISOString()))}catch(e){logStatus("Can't read "+logHandle.name+" any more. Click the folder to load it again.")}}
const pick=$("logPick"),pickLabel=t=>{pick.setAttribute("aria-label",t);pick.title=t};
function watch(h){logHandle=h;savedHandle=null;logStamp=0;pickLabel("Choose another log file");logStatus("Using "+h.name);pollLog();if(!polling)polling=setInterval(pollLog,30000)}
if(window.showOpenFilePicker){pick.hidden=false;
 IDB.get("log").then(async h=>{if(!h)return;if(await h.queryPermission({mode:"read"})==="granted")watch(h);else{savedHandle=h;pickLabel("Reconnect "+h.name);logStatus("Click the folder to reconnect "+h.name)}}).catch(()=>{});
 pick.addEventListener("click",async()=>{try{if(savedHandle&&await savedHandle.requestPermission({mode:"read"})==="granted"){watch(savedHandle);return}
  const[h]=await showOpenFilePicker({types:[{description:"Event log",accept:{"text/plain":[".jsonl"]}}]});await IDB.set("log",h);watch(h)}catch(e){}})}
const zone=$("dropZone"),hasFiles=e=>[...((e.dataTransfer&&e.dataTransfer.types)||[])].includes("Files");let dragDepth=0;
addEventListener("dragenter",e=>{if(hasFiles(e)){dragDepth++;zone.hidden=false}});
addEventListener("dragleave",e=>{if(hasFiles(e)&&--dragDepth<=0){dragDepth=0;zone.hidden=true}});
addEventListener("dragover",e=>{if(hasFiles(e))e.preventDefault()});
addEventListener("drop",async e=>{if(!hasFiles(e))return;e.preventDefault();dragDepth=0;zone.hidden=true;
 const item=[...e.dataTransfer.items].find(i=>i.kind==="file"),file=item&&item.getAsFile(),hp=item&&item.getAsFileSystemHandle?item.getAsFileSystemHandle():null;
 if(!file||!file.name.endsWith(".jsonl")){logStatus("Drop a .jsonl log file.");return}
 const h=hp&&await hp.catch(()=>null);if(h&&h.kind==="file"){try{await IDB.set("log",h)}catch(err){}watch(h);return}
 if(store.restore(PFF.parseJsonl(await file.text()))){rebuild();redraw()}logStatus("Loaded "+file.name+" once. This browser can't watch it for changes.")});
FIELDS.forEach(id=>$(id).addEventListener("input",()=>{saveFilters();draw()}));draw();
"""


def main(argv):
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add")
    a.add_argument("--thread", required=True)
    a.add_argument("--repo", required=True)
    a.add_argument("--pr", required=True, type=int)
    a.add_argument("--outcome", required=True, choices=OUTCOMES)
    for opt in ["title", "url", "comment-url", "reply-url", "path", "reviewer", "sha", "note", "at"]:
        a.add_argument("--" + opt)
    sub.add_parser("render")
    args = p.parse_args(argv)
    for f in (LOG_FILE, REPORT_FILE):
        os.makedirs(os.path.dirname(f), exist_ok=True)
    add(args) if args.cmd == "add" else render()


if __name__ == "__main__":
    main(sys.argv[1:])
