import assert from "node:assert/strict";
import { test } from "node:test";
import { reconcileCompanion, type CompanionHeartbeat, type CompanionRuntime } from "../src/lifecycle.ts";

const expected = { version: "0.6.0", build: "current" };

function fixture(initial?: CompanionHeartbeat) {
  let current = initial;
  let now = 0;
  const events: string[] = [];
  const runtime: CompanionRuntime = {
    async read() { events.push("read"); return current; },
    quit(target) { events.push(`quit:${target.instanceId ?? target.pid}`); },
    exited: () => true,
    async launch() { events.push("launch"); current = { ...expected, pid: 20, instanceId: "replacement", heartbeatAt: now }; },
    async wait() { now += 1000; },
    now: () => now,
  };
  return { runtime, events, advance() { now += 1000; }, setCurrent(value?: CompanionHeartbeat) { current = value; } };
}

test("matching and newer companions are reused, including numeric and prerelease version ordering", async () => {
  for (const version of [expected.version, "0.10.0", "1.0.0-beta.2"]) {
    const h = fixture({ pid: 10, heartbeatAt: 0, version, build: version === expected.version ? expected.build : "newer" });
    await reconcileCompanion(expected, h.runtime);
    assert.deepEqual(h.events, ["read"]);
  }
  for (const [current, desired] of [["0.6.0", "0.6.0-beta.1"], ["0.6.0-beta.10", "0.6.0-beta.2"], ["0.6.0-rc.1", "0.6.0-beta.10"]]) {
    const h = fixture({ pid: 10, heartbeatAt: 0, version: current, build: "newer" });
    await reconcileCompanion({ version: desired, build: "older" }, h.runtime);
    assert.deepEqual(h.events, ["read"]);
  }
});

test("outdated, changed-source and legacy companions quit cooperatively before replacement", async () => {
  for (const identity of [{ version: "0.5.2", build: "old", instanceId: "old" }, { ...expected, build: "modified" }, {}]) {
    const old = { ...identity, pid: 10, heartbeatAt: 0 };
    const h = fixture(old);
    h.runtime.quit = (target) => { assert.deepEqual(target, old); h.events.push("quit"); };
    let quitting = true;
    h.runtime.wait = async () => { h.advance(); if (quitting) { h.setCurrent(); quitting = false; } };
    await reconcileCompanion(expected, h.runtime);
    assert.equal(h.events.filter((event) => event === "quit").length, 1);
    assert.equal(h.events.filter((event) => event === "launch").length, 1);
    assert.ok(h.events.indexOf("quit") < h.events.indexOf("launch"));
  }
});

test("first startup launches once, and a concurrent matching replacement is reused", async () => {
  const absent = fixture();
  await reconcileCompanion(expected, absent.runtime);
  assert.equal(absent.events.filter((event) => event === "launch").length, 1);
  const h = fixture({ pid: 10, instanceId: "old", heartbeatAt: 0 });
  h.runtime.quit = () => h.setCurrent({ ...expected, pid: 20, instanceId: "winner", heartbeatAt: 0 });
  await reconcileCompanion(expected, h.runtime);
  assert.ok(!h.events.includes("launch"));
});

test("replacement waits for the old process to release its lock after removing its heartbeat", async () => {
  const h = fixture({ pid: 10, heartbeatAt: 0 });
  let exited = false, waits = 0;
  h.runtime.quit = () => h.setCurrent();
  h.runtime.exited = () => exited;
  h.runtime.wait = async () => { h.advance(); waits++; if (waits === 3) exited = true; };
  h.runtime.launch = async () => {
    assert.ok(exited);
    h.events.push("launch");
    h.setCurrent({ ...expected, pid: 20, heartbeatAt: 0 });
  };
  await reconcileCompanion(expected, h.runtime);
  assert.equal(h.events.filter((event) => event === "launch").length, 1);
});

test("a different concurrent build is not repeatedly stopped", async () => {
  const h = fixture({ pid: 10, instanceId: "old", heartbeatAt: 0 });
  h.runtime.quit = () => h.setCurrent({ version: expected.version, build: "other", pid: 20, instanceId: "winner", heartbeatAt: 0 });
  await assert.rejects(reconcileCompanion(expected, h.runtime), /Another Pi Overview build/);
  assert.ok(!h.events.includes("launch"));
});

test("hung replacements time out without repeated quit/launch, and cancellation stops pending work", async () => {
  const h = fixture({ pid: 10, instanceId: "stuck", heartbeatAt: 0 });
  await assert.rejects(reconcileCompanion(expected, h.runtime), /15 seconds/);
  assert.equal(h.events.filter((event) => event.startsWith("quit:")).length, 1);
  assert.ok(!h.events.includes("launch"));
  const controller = new AbortController();
  controller.abort();
  const cancelled = fixture();
  await assert.rejects(reconcileCompanion(expected, cancelled.runtime, controller.signal), { name: "AbortError" });
  assert.deepEqual(cancelled.events, []);
  const pending = fixture({ pid: 10, heartbeatAt: 0 });
  const active = new AbortController();
  pending.runtime.wait = async () => { active.abort(); active.signal.throwIfAborted(); };
  await assert.rejects(reconcileCompanion(expected, pending.runtime, active.signal), { name: "AbortError" });
  assert.ok(!pending.events.includes("launch"));
});
