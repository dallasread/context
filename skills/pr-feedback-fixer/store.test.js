const { test } = require("node:test")
const assert = require("node:assert/strict")
const PFF = require("./store.js")

const ME = "me"
const T0 = Date.parse("2026-10-20T00:00:00Z")
const classified = (id, data, time) => PFF.event(id, "classified", { thread: id, repo: "o/r", pr: 1, outcome: "deferred", at: new Date(time).toISOString(), ...data }, time)
const comment = (id, author, extra) => ({ id, author, body: `${author} says ${id}`, at: "2026-10-20T00:00:00Z", url: `https://c/${id}`, reactions: [], ...extra })
const observed = (id, ctx, time) => PFF.event(id, "observed", { resolved: false, outdated: false, line: 1, start_line: null, path: "a.rb", hunk: "", comments: [], ...ctx }, time)
const state = events => { const s = new PFF.EventStore(); s.restore(events); return s.state() }

test("an event carries its key, collection, action, and version", () => {
  const e = PFF.event("T1", "classified", { outcome: "fixed" }, T0)
  assert.deepEqual(e, { key: `${T0}/threads/T1/classified/v1`, time: T0, collection: "threads", objectId: "T1", action: "classified", data: { outcome: "fixed" }, version: "v1" })
})

test("the latest classification of a thread wins", () => {
  const [t] = PFF.threads(state([classified("T1", { outcome: "question" }, T0), classified("T1", { outcome: "fixed", sha: "abc" }, T0 + 1)]))
  assert.equal(t.thread, "T1")
  assert.equal(t.outcome, "fixed")
  assert.equal(t.sha, "abc")
})

test("an old log line reads as a classified event, and noted reads as deferred", () => {
  const e = PFF.fromLine({ thread: "T1", repo: "o/r", pr: 1, outcome: "noted", at: "2026-10-20T00:00:00+00:00" })
  assert.equal(e.action, "classified")
  assert.equal(e.objectId, "T1")
  assert.equal(e.time, T0)
  assert.equal(PFF.threads(state([e]))[0].outcome, "deferred")
})

test("parsing a log skips blank and broken lines", () => {
  const text = JSON.stringify(classified("T1", {}, T0)) + "\n\nnot json\n" + JSON.stringify({ thread: "T2", repo: "o/r", pr: 2, outcome: "fixed", at: "2026-10-20T00:00:00Z" }) + "\n"
  assert.deepEqual(PFF.parseJsonl(text).map(e => e.objectId), ["T1", "T2"])
})

test("restoring the same events twice adds nothing", () => {
  const s = new PFF.EventStore()
  const events = [classified("T1", {}, T0), observed("T1", {}, T0 + 1)]
  assert.equal(s.restore(events), 2)
  assert.equal(s.restore(events), 0)
  assert.equal(s.all().length, 2)
})

test("threads come newest first, and a thread with no classification is left out", () => {
  const ts = PFF.threads(state([classified("T1", {}, T0), classified("T2", {}, T0 + 5), observed("T3", {}, T0 + 9)]))
  assert.deepEqual(ts.map(t => t.thread), ["T2", "T1"])
})

test("the latest snapshot from GitHub is the thread's context", () => {
  const [t] = PFF.threads(state([classified("T1", {}, T0), observed("T1", { comments: [comment("C1", "rev")] }, T0 + 1), observed("T1", { resolved: true, comments: [comment("C1", "rev")] }, T0 + 2)]))
  assert.equal(t.ctx.resolved, true)
  assert.equal(t.ctx.comments.length, 1)
})

test("a thread is handled when it is resolved or my comment is the latest", () => {
  const waiting = { ctx: { resolved: false, comments: [comment("C1", "rev")] } }
  assert.equal(PFF.handled({}, ME), false)
  assert.equal(PFF.handled(waiting, ME), false)
  assert.equal(PFF.handled({ ctx: { resolved: true, comments: [comment("C1", "rev")] } }, ME), true)
  assert.equal(PFF.handled({ ctx: { resolved: false, comments: [comment("C1", "rev"), comment("C2", ME)] } }, ME), true)
})

test("needsYou lists only the threads that are not handled", () => {
  const s = state([classified("T1", {}, T0), classified("T2", {}, T0 + 1), observed("T2", { resolved: true }, T0 + 2)])
  assert.deepEqual(PFF.needsYou(s, ME).map(t => t.thread), ["T1"])
})

test("byPullRequest groups threads by pull request and keeps their order", () => {
  const ts = PFF.threads(state([classified("T1", { pr: 1 }, T0), classified("T2", { pr: 2 }, T0 + 1), classified("T3", { pr: 1 }, T0 + 2)]))
  const groups = PFF.byPullRequest(ts)
  assert.deepEqual([...groups.keys()], ["o/r#1", "o/r#2"])
  assert.deepEqual(groups.get("o/r#1").map(t => t.thread), ["T3", "T1"])
})

test("history starts at the second snapshot and lists only my changes", () => {
  const s = state([classified("T1", {}, T0),
    observed("T1", { comments: [comment("C1", "rev")] }, T0 + 1),
    observed("T1", { comments: [comment("C1", "rev"), comment("C2", "rev")] }, T0 + 2)])
  assert.deepEqual(PFF.history(s, ME), [])
})

test("history lists my reply, and stops offering undo once it is gone", () => {
  const before = [classified("T1", {}, T0), observed("T1", { comments: [comment("C1", "rev")] }, T0 + 1),
    observed("T1", { comments: [comment("C1", "rev"), comment("C2", ME)] }, T0 + 2)]
  const [reply] = PFF.history(state(before), ME)
  assert.deepEqual({ kind: reply.kind, thread: reply.thread, comment: reply.comment, url: reply.url, undoable: reply.undoable }, { kind: "reply", thread: "T1", comment: "C2", url: "https://c/C2", undoable: true })
  assert.equal(reply.body, "me says C2")
  assert.equal(reply.at, new Date(T0 + 2).toISOString())
  const after = PFF.history(state([...before, observed("T1", { comments: [comment("C1", "rev")] }, T0 + 3)]), ME)
  assert.deepEqual(after.map(h => [h.kind, h.undoable]), [["unreply", false], ["reply", false]])
})

test("history lists resolving and unresolving, newest first", () => {
  const s = state([classified("T1", {}, T0), observed("T1", {}, T0 + 1), observed("T1", { resolved: true }, T0 + 2), observed("T1", {}, T0 + 3)])
  assert.deepEqual(PFF.history(s, ME).map(h => [h.kind, h.undoable]), [["unresolve", false], ["resolve", false]])
})

test("history lists my reactions, and an undo puts the old state back", () => {
  const plain = comment("C1", "rev"), rocket = comment("C1", "rev", { reactions: [{ content: "ROCKET", count: 1, mine: true }] })
  const s = state([classified("T1", {}, T0), observed("T1", { comments: [plain] }, T0 + 1), observed("T1", { comments: [rocket] }, T0 + 2)])
  const [h] = PFF.history(s, ME)
  assert.deepEqual({ kind: h.kind, comment: h.comment, content: h.content, undoable: h.undoable }, { kind: "react", comment: "C1", content: "ROCKET", undoable: true })
  const others = state([classified("T1", {}, T0), observed("T1", { comments: [plain] }, T0 + 1),
    observed("T1", { comments: [comment("C1", "rev", { reactions: [{ content: "EYES", count: 1, mine: false }] })] }, T0 + 2)])
  assert.deepEqual(PFF.history(others, ME), [])
  const removed = PFF.history(state([...s.events, observed("T1", { comments: [plain] }, T0 + 3)]), ME)
  assert.deepEqual(removed.map(h => [h.kind, h.undoable]), [["unreact", true], ["react", false]])
})

test("stable stringifies objects the same whatever their key order", () => {
  assert.equal(PFF.stable({ b: 1, a: [{ d: 2, c: 3 }] }), PFF.stable({ a: [{ c: 3, d: 2 }], b: 1 }))
})
