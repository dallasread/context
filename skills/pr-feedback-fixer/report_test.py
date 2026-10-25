import base64, hashlib, json, os, re, subprocess, sys, tempfile, unittest
from datetime import datetime, timedelta, timezone

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "report.py")


class ReportTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.env = {**os.environ, "LOG_FILE": f"{self.dir}/log.jsonl", "REPORT_FILE": f"{self.dir}/report.html", "GH": "/usr/bin/false"}

    def fake_gh(self, nodes):
        with open(f"{self.dir}/gh.json", "w") as f:
            json.dump({"data": {"nodes": nodes}}, f)
        with open(f"{self.dir}/gh", "w") as f:
            f.write(f"#!/bin/sh\ncat {self.dir}/gh.json\n")
        os.chmod(f"{self.dir}/gh", 0o755)
        self.env["GH"] = f"{self.dir}/gh"

    def html(self):
        return open(self.env["REPORT_FILE"]).read()

    def run_cmd(self, *args):
        subprocess.run([sys.executable, SCRIPT, *args], env=self.env, check=True)

    def events(self):
        jsonl = self.html().split('<script type="application/jsonl" id="rows">')[1].split("</script>")[0]
        return [json.loads(l) for l in jsonl.splitlines() if l.strip()]

    def log(self):
        with open(self.env["LOG_FILE"]) as f:
            return [json.loads(l) for l in f if l.strip()]

    def rows(self):
        """Each thread's latest classification, with its latest GitHub snapshot as ctx, newest first."""
        threads = {}
        for e in sorted(self.events(), key=lambda e: (e["time"], e["key"])):
            t = threads.setdefault(e["objectId"], {})
            if e["action"] == "classified":
                t.update(e["data"], _time=e["time"])
            if e["action"] == "observed":
                t["ctx"] = e["data"]
        return [{k: v for k, v in t.items() if k != "_time"} for t in sorted((t for t in threads.values() if "_time" in t), key=lambda t: -t["_time"])]

    def folders(self):
        return json.loads(self.html().split('<script type="application/json" id="folders">')[1].split("</script>")[0])

    def gh_thread(self, resolved=False):
        return {"id": "T1", "isResolved": resolved, "isOutdated": False, "line": 1, "startLine": None, "path": "a.rb", "comments": {"nodes": [
            {"id": "C1", "reactionGroups": [], "author": {"login": "rev"}, "body": "Fix", "createdAt": "2026-10-23T00:00:00Z", "url": "https://c1", "diffHunk": "@@"}]}}

    def test_add_appends_a_classified_event(self):
        self.run_cmd("add", "--thread", "T1", "--repo", "o/r", "--pr", "1", "--outcome", "fixed", "--at", "2026-10-20T00:00:00+00:00")
        [e] = self.log()
        time = int(datetime(2026, 10, 20, tzinfo=timezone.utc).timestamp() * 1000)
        self.assertEqual({k: e[k] for k in ["key", "time", "collection", "objectId", "action", "version"]},
                         {"key": f"{time}/threads/T1/classified/v1", "time": time, "collection": "threads", "objectId": "T1", "action": "classified", "version": "v1"})
        self.assertEqual((e["data"]["outcome"], e["data"]["repo"], e["data"]["pr"]), ("fixed", "o/r", 1))

    def test_render_records_a_github_snapshot_only_when_it_changes(self):
        self.run_cmd("add", "--thread", "T1", "--repo", "o/r", "--pr", "1", "--outcome", "deferred")
        self.fake_gh([self.gh_thread()])
        self.run_cmd("render")
        self.run_cmd("render")
        self.assertEqual([e["action"] for e in self.log()], ["classified", "observed"])
        self.fake_gh([self.gh_thread(resolved=True)])
        self.run_cmd("render")
        observed = [e for e in self.log() if e["action"] == "observed"]
        self.assertEqual([e["data"]["resolved"] for e in observed], [False, True])
        self.assertEqual(self.rows()[0]["ctx"]["resolved"], True)

    def test_keeps_every_event_of_a_thread_that_is_still_active(self):
        old = int((datetime.now(timezone.utc) - timedelta(days=40)).timestamp() * 1000)
        with open(self.env["LOG_FILE"], "w") as f:
            f.write(json.dumps({"key": f"{old}/threads/T1/classified/v1", "time": old, "collection": "threads", "objectId": "T1", "action": "classified",
                                "data": {"thread": "T1", "repo": "o/r", "pr": 1, "outcome": "question"}, "version": "v1"}) + "\n")
        self.run_cmd("add", "--thread", "T1", "--repo", "o/r", "--pr", "1", "--outcome", "fixed")
        self.run_cmd("render")
        self.assertEqual([e["data"]["outcome"] for e in self.log()], ["question", "fixed"])

    def test_the_page_inlines_the_event_store(self):
        self.run_cmd("render")
        script = self.html().split("<script>")[1].split("</script>")[0]
        with open(os.path.join(os.path.dirname(SCRIPT), "store.js")) as f:
            self.assertIn(f.read(), script)
        self.assertIn("new PFF.EventStore()", script)

    def test_the_page_can_reload_the_log_from_a_picked_file(self):
        self.run_cmd("render")
        html = self.html()
        self.assertIn('id="logPick"', html)
        for s in ["showOpenFilePicker", "indexedDB", "queryPermission", "requestPermission", "setInterval(pollLog,30000)"]:
            self.assertIn(s, html)

    def test_page_actions_are_labelled_icon_buttons(self):
        self.run_cmd("render")
        html = self.html()
        self.assertNotIn('class="menu"', html)
        for id, label in [("historyOpen", "History"), ("logPick", "Load log file"), ("forget", "Forget GitHub token")]:
            self.assertRegex(html, f'<button type="button" class="btn icon tool" id="{id}"[^>]* aria-label="{label}" title="{label}"><svg')

    def test_the_log_source_reads_as_a_status_not_an_action(self):
        self.run_cmd("render")
        html = self.html()
        self.assertIn('id="logStatus"', html)
        self.assertNotIn("Reloading", html)

    def test_dropping_a_log_file_on_the_window_uses_it(self):
        self.run_cmd("render")
        html = self.html()
        for s in ['addEventListener("dragover"', 'addEventListener("drop"', "getAsFileSystemHandle", 'id="dropZone"']:
            self.assertIn(s, html)

    def test_keeps_its_data_in_a_state_directory_outside_the_skill(self):
        env = {k: v for k, v in self.env.items() if k not in ("LOG_FILE", "REPORT_FILE")}
        env["HOME"] = self.dir
        subprocess.run([sys.executable, SCRIPT, "add", "--thread", "T1", "--repo", "o/r", "--pr", "1", "--outcome", "fixed"], env=env, check=True)
        subprocess.run([sys.executable, SCRIPT, "render"], env=env, check=True)
        state = f"{self.dir}/.local/state/pr-feedback-fixer"
        self.assertTrue(os.path.exists(f"{state}/log.jsonl"))
        self.assertTrue(os.path.exists(f"{state}/report.html"))

    def test_keeps_the_latest_entry_of_each_thread(self):
        self.run_cmd("add", "--thread", "T1", "--repo", "o/r", "--pr", "1", "--outcome", "question")
        self.run_cmd("add", "--thread", "T1", "--repo", "o/r", "--pr", "1", "--outcome", "fixed", "--sha", "abc")
        self.run_cmd("add", "--thread", "T2", "--repo", "o/r", "--pr", "2", "--outcome", "deferred", "--note", "</script>")
        self.run_cmd("render")
        rows = self.rows()
        self.assertEqual({(r["thread"], r["outcome"]) for r in rows}, {("T1", "fixed"), ("T2", "deferred")})
        self.assertNotIn("</script>\"", open(self.env["REPORT_FILE"]).read())

    def test_a_thread_is_handled_when_resolved_or_my_comment_is_the_latest(self):
        self.run_cmd("render")
        html = self.html()
        self.assertIn("PFF.handled(r,ME)", html)
        self.assertNotRegex(html, r"(?i)replied=|not replied")
        self.assertNotIn('type="checkbox"', html)
        self.assertNotRegex(html, r"(?i)\bseen\b")

    def test_the_status_filter_starts_on_needs_you(self):
        self.run_cmd("render")
        self.assertIn('<option value="no" selected>Needs you</option>', self.html())

    def test_filters_are_saved_in_local_storage(self):
        self.run_cmd("render")
        self.assertIn("pr-feedback-fixer:filters", open(self.env["REPORT_FILE"]).read())

    def test_the_drawer_links_to_the_comment(self):
        self.run_cmd("add", "--thread", "T1", "--repo", "o/r", "--pr", "1", "--outcome", "fixed",
                     "--comment-url", "https://c", "--reply-url", "https://r")
        self.run_cmd("render")
        html = open(self.env["REPORT_FILE"]).read()
        self.assertEqual((self.rows()[0]["comment_url"], self.rows()[0]["reply_url"]), ("https://c", "https://r"))
        self.assertIn("r.comment_url", html)

    def test_shows_reviewer_avatars(self):
        self.run_cmd("render")
        self.assertIn("https://github.com/${encodeURIComponent(l)}.png", open(self.env["REPORT_FILE"]).read())

    def test_table_and_filters_are_labelled(self):
        self.run_cmd("render")
        html = open(self.env["REPORT_FILE"]).read()
        self.assertIn("<caption", html)
        self.assertIn('scope="col"', html)
        self.assertIn('scope="rowgroup"', html)
        for id in ["repo", "pr", "reviewer"]:
            self.assertNotIn(f'id="{id}"', html)
        for id in ["q", "status", "since"]:
            self.assertIn(f'<label for="{id}"', html)

    def test_time_range_offers_hour_and_day_presets(self):
        self.run_cmd("render")
        html = open(self.env["REPORT_FILE"]).read()
        for v in ["1h", "4h", "8h", "1d", "2d", "3d", "7d", "30d"]:
            self.assertIn(f'<option value="{v}"', html)

    def test_reviewer_names_filter_by_that_person(self):
        self.run_cmd("render")
        self.assertIn('data-field="q" data-value="${esc(r.reviewer)}"', open(self.env["REPORT_FILE"]).read())

    def test_repo_names_search_for_that_repo(self):
        self.run_cmd("render")
        html = open(self.env["REPORT_FILE"]).read()
        self.assertIn('data-field="q" data-value="${esc(p.repo)}"', html)
        self.assertIn("[r.repo,", html)

    def test_comments_open_in_claude_in_the_repo_checkout(self):
        code = f"{self.dir}/code"
        for name, origin in [("app", "git@github.com:o/r.git"), ("app-copy", "git@github.com:o/r.git"), ("other", "git@github.com:o/x.git")]:
            subprocess.run(["git", "init", "-q", f"{code}/{name}"], check=True)
            subprocess.run(["git", "-C", f"{code}/{name}", "remote", "add", "origin", origin], check=True)
        self.env["CODE_DIR"] = code
        self.run_cmd("add", "--thread", "T1", "--repo", "o/r", "--pr", "1", "--outcome", "deferred")
        self.run_cmd("add", "--thread", "T2", "--repo", "o/none", "--pr", "2", "--outcome", "deferred")
        self.run_cmd("render")
        self.assertEqual(self.folders(), {"o/r": f"{code}/app", "o/x": f"{code}/other"})
        self.assertIn("FOLDERS[r.repo]", self.html())
        self.assertIn("claude://code/new?q=", self.html())

    def test_finds_checkouts_nested_under_apps_in_home_by_default(self):
        for name in ["dns/app", "dns/app-copy"]:
            subprocess.run(["git", "init", "-q", f"{self.dir}/apps/{name}"], check=True)
            subprocess.run(["git", "-C", f"{self.dir}/apps/{name}", "remote", "add", "origin", "git@github.com:o/r.git"], check=True)
        self.env["HOME"] = self.dir
        self.env.pop("CODE_DIR", None)
        self.run_cmd("add", "--thread", "T1", "--repo", "o/r", "--pr", "1", "--outcome", "deferred")
        self.run_cmd("render")
        self.assertEqual(self.folders()["o/r"], f"{self.dir}/apps/dns/app")

    def test_reads_my_login_from_github(self):
        with open(f"{self.dir}/gh", "w") as f:
            f.write('#!/bin/sh\n[ "$2" = user ] && echo octo || echo "{}"\n')
        os.chmod(f"{self.dir}/gh", 0o755)
        self.env["GH"] = f"{self.dir}/gh"
        self.run_cmd("render")
        self.assertIn('const ME="octo"', self.html())
        self.assertNotIn("ME = \"", open(SCRIPT).read())

    def test_embeds_the_thread_comments_and_code(self):
        self.fake_gh([{"id": "T1", "isResolved": False, "isOutdated": False, "line": 7, "startLine": 5, "path": "a.rb", "comments": {"nodes": [
            {"id": "C1", "reactionGroups": [{"content": "ROCKET", "viewerHasReacted": True, "reactors": {"totalCount": 2}}, {"content": "EYES", "viewerHasReacted": False, "reactors": {"totalCount": 0}}], "author": {"login": "rev"}, "body": "Please fix", "createdAt": "2026-10-23T00:00:00Z", "url": "https://c1", "diffHunk": "@@ -1 +1 @@\n+x"},
            {"author": None, "body": "Done", "createdAt": "2026-10-23T01:00:00Z", "url": "https://c2", "diffHunk": "@@"}]}}, None])
        self.run_cmd("add", "--thread", "T1", "--repo", "o/r", "--pr", "1", "--outcome", "fixed")
        self.run_cmd("render")
        ctx = self.rows()[0]["ctx"]
        self.assertEqual([c["body"] for c in ctx["comments"]], ["Please fix", "Done"])
        self.assertEqual((ctx["hunk"], ctx["line"], ctx["resolved"], ctx["comments"][1]["author"]), ("@@ -1 +1 @@\n+x", 7, False, None))
        self.assertEqual(ctx["start_line"], 5)
        self.assertEqual((ctx["comments"][0]["id"], ctx["comments"][0]["reactions"]), ("C1", [{"content": "ROCKET", "count": 2, "mine": True}]))
        self.assertEqual(ctx["comments"][1]["reactions"], [])

    def test_renders_without_github(self):
        self.run_cmd("add", "--thread", "T1", "--repo", "o/r", "--pr", "1", "--outcome", "fixed")
        self.run_cmd("render")
        self.assertNotIn("ctx", self.rows()[0])

    def test_content_policy_allows_only_the_page_script_and_github(self):
        self.run_cmd("add", "--thread", "T1", "--repo", "o/r", "--pr", "1", "--outcome", "fixed")
        self.run_cmd("render")
        html = self.html()
        csp = re.search(r'http-equiv="Content-Security-Policy" content="([^"]+)"', html).group(1)
        script = html.split("<script>")[1].split("</script>")[0]
        digest = base64.b64encode(hashlib.sha256(script.encode()).digest()).decode()
        self.assertIn(f"script-src 'sha256-{digest}'", csp)
        self.assertIn("default-src 'none'", csp)
        self.assertIn("connect-src https://api.github.com", csp)
        self.assertNotRegex(html, r'\son[a-z]+="')

    def test_the_token_is_never_stored(self):
        self.run_cmd("render")
        html = self.html()
        self.assertNotIn("sessionStorage", html)
        self.assertEqual(set(re.findall(r"localStorage\.setItem\((\w+)", html)), {"FKEY", "EKEY"})

    def test_celebrates_when_nothing_is_left_to_review(self):
        self.run_cmd("render")
        html = self.html()
        self.assertIn('id="caughtUp"', html)
        self.assertIn("function confetti(", html)
        self.assertIn("prefers-reduced-motion", html.split("function confetti(")[1])

    def test_my_actions_are_kept_in_a_history_pane_with_undo(self):
        self.run_cmd("render")
        html = self.html()
        self.assertIn('<dialog id="history"', html)
        self.assertIn('id="historyOpen"', html)
        self.assertIn('EKEY="pr-feedback-fixer:events"', html)
        self.assertIn("PFF.history(", html)
        self.assertNotIn("HKEY", html)
        for undo in ["deletePullRequestReviewComment", "unresolveReviewThread", "removeReaction", "addReaction"]:
            self.assertIn(undo, html)

    def test_comments_show_as_bubbles_with_my_replies_on_the_right(self):
        self.run_cmd("render")
        html = self.html()
        self.assertIn('class="bubble"', html)
        self.assertIn('" me":""', html)

    def test_details_open_in_a_drawer_and_the_table_shows_the_comment_not_the_file(self):
        self.run_cmd("render")
        html = self.html()
        self.assertIn('<dialog id="drawer"', html)
        self.assertIn('<th scope="col">Feedback</th>', html)
        self.assertNotIn("<code>${path}</code>", html)
        self.assertNotIn("Show thread", html)
        self.assertNotIn(">Reply</a>", html)

    def test_resolved_threads_are_marked_in_the_table_and_drawer(self):
        self.run_cmd("render")
        html = self.html()
        self.assertIn('${r.ctx&&r.ctx.resolved?" resolved":""}', html)
        self.assertIn('class="resolved-banner"', html)

    def test_links_open_in_a_new_tab(self):
        self.run_cmd("render")
        self.assertIn('<base target="_blank">', open(self.env["REPORT_FILE"]).read())

    def test_has_an_inline_favicon(self):
        self.run_cmd("render")
        html = self.html()
        self.assertIn('<link rel="icon" href="data:image/svg+xml,', html)
        csp = re.search(r'http-equiv="Content-Security-Policy" content="([^"]+)"', html).group(1)
        self.assertIn("img-src data:", csp)

    def test_add_takes_an_explicit_time(self):
        at = (datetime.now(timezone.utc) - timedelta(days=3)).isoformat(timespec="seconds")
        self.run_cmd("add", "--thread", "T1", "--repo", "o/r", "--pr", "1", "--outcome", "fixed", "--at", at)
        self.run_cmd("render")
        self.assertEqual(self.rows()[0]["at"], at)

    def test_rows_are_inlined_as_jsonl_outside_the_page_script(self):
        self.run_cmd("add", "--thread", "T1", "--repo", "o/r", "--pr", "1", "--outcome", "fixed")
        self.run_cmd("add", "--thread", "T2", "--repo", "o/r", "--pr", "2", "--outcome", "deferred")
        self.run_cmd("render")
        self.assertEqual(len(self.rows()), 2)
        self.assertNotIn("T1", self.html().split("<script>")[1].split("</script>")[0])

    def test_old_noted_entries_read_as_deferred(self):
        at = datetime.now(timezone.utc).isoformat(timespec="seconds")
        with open(self.env["LOG_FILE"], "w") as f:
            f.write(json.dumps({"thread": "T1", "repo": "o/r", "pr": 1, "outcome": "noted", "at": at}) + "\n")
        self.run_cmd("render")
        self.assertEqual(self.rows()[0]["outcome"], "deferred")
        self.assertNotIn('"noted"', open(self.env["LOG_FILE"]).read())
        self.assertEqual([(e["action"], e["objectId"]) for e in self.log()], [("classified", "T1")])

    def test_prunes_entries_older_than_30_days(self):
        old = (datetime.now(timezone.utc) - timedelta(days=31)).isoformat()
        with open(self.env["LOG_FILE"], "w") as f:
            f.write(json.dumps({"thread": "OLD", "repo": "o/r", "pr": 1, "outcome": "fixed", "at": old}) + "\n")
        self.run_cmd("add", "--thread", "NEW", "--repo", "o/r", "--pr", "1", "--outcome", "fixed")
        self.run_cmd("render")
        self.assertEqual([r["thread"] for r in self.rows()], ["NEW"])
        self.assertNotIn("OLD", open(self.env["LOG_FILE"]).read())


if __name__ == "__main__":
    unittest.main()
