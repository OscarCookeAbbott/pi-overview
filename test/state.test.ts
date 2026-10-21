import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { atomicJSON, InstancePublisher, preview, readConfig } from "../src/state.ts";

function setup(t: TestContext) {
  const root = mkdtempSync(join(tmpdir(), "pi-overview-state-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return new InstancePublisher(root, "/tmp/Project 'quoted' 🥧");
}

test("headless input is authenticated, session-bound, bounded, acknowledged and not replayed", (t) => {
  const publisher = setup(t);
  publisher.update({ headless: true, acceptsInput: true, sessionId: "saved-session" });
  const path = join(publisher.root, "inputs", `${publisher.snapshot.id}.json`);
  const receipt = join(publisher.root, "inputs", `${publisher.snapshot.id}.result.json`);
  const messages: string[] = [];
  const request = { id: "77777777-7777-4777-8777-777777777777", token: publisher.snapshot.token, sessionId: "saved-session", message: "Keep working\n🥧", createdAt: Date.now() };
  const send = (text: string) => { messages.push(text); };
  for (const patch of [{ token: "stale" }, { sessionId: "other" }, { createdAt: Date.now() - 11000 }, { createdAt: Date.now() + 1000 }, { message: " " }, { message: "a".repeat(65537) }]) {
    atomicJSON(path, { ...request, ...patch });
    publisher.consumeInput(send);
    assert.deepEqual(messages, []);
  }
  atomicJSON(path, request);
  publisher.consumeInput(send);
  assert.deepEqual(messages, [request.message]);
  assert.equal(JSON.parse(readFileSync(receipt, "utf8")).status, "submitted");
  assert.equal(statSync(receipt).mode & 0o777, 0o600);
  atomicJSON(path, request);
  publisher.consumeInput(send);
  assert.equal(messages.length, 1, "a repeated request must not become another user message");
  atomicJSON(path, { ...request, id: "88888888-8888-4888-8888-888888888888" });
  publisher.consumeInput(() => { throw new Error("dispatch failed"); });
  assert.equal(JSON.parse(readFileSync(receipt, "utf8")).status, "rejected");
});

test("configuration is strict and previews are bounded Unicode text without terminal controls", () => {
  assert.deepEqual(readConfig({}), { enabled: true, autoStart: true, showOutput: true, defaultDirectory: homedir() });
  assert.deepEqual(readConfig({ overview: { autoStart: false } }), { enabled: true, autoStart: false, showOutput: true, defaultDirectory: homedir() });
  assert.equal(readConfig({ overview: { defaultDirectory: "~/work" } }).defaultDirectory, join(homedir(), "work"));
  assert.equal(readConfig({ overview: { defaultDirectory: "project" } }, "/tmp/base").defaultDirectory, "/tmp/base/project");
  for (const overview of [null, [], "yes", { enabled: "no" }, { unknown: true }, { defaultDirectory: " " }, { defaultDirectory: false }]) assert.throws(() => readConfig({ overview }), /overview/);
  assert.equal(preview("\x1b[31mHello\x1b[0m\nworld\x07"), "Hello world");
  assert.equal([...preview("🥧".repeat(500))].length, 400);
});

test("snapshots are private/atomic, keep output across heartbeats and preserve final status", (t) => {
  const publisher = setup(t);
  let now = Date.now();
  t.mock.method(Date, "now", () => now);
  publisher.update({ status: "Completed", lastOutput: "Answer", sessionId: "stable-session-id", sessionFile: "/tmp/exact.jsonl" });
  const changedAt = publisher.snapshot.updatedAt;
  now += 2000;
  publisher.heartbeat();
  const snapshot = JSON.parse(readFileSync(publisher.path, "utf8"));
  assert.equal(snapshot.updatedAt, changedAt);
  assert.equal(snapshot.heartbeatAt, now);
  assert.equal(snapshot.lastOutput, "Answer");
  assert.equal(snapshot.sessionId, "stable-session-id");
  assert.equal(snapshot.sessionFile, "/tmp/exact.jsonl");
  assert.equal(snapshot.projectName, "Project 'quoted' 🥧");
  assert.equal(statSync(publisher.root).mode & 0o777, 0o700);
  assert.equal(statSync(publisher.path).mode & 0o777, 0o600);
  assert.deepEqual(readdirSync(join(publisher.root, "records")), [`${snapshot.id}.json`]);
  publisher.close();
  publisher.close();
  publisher.update({ status: "Thinking", busy: true });
  assert.equal(JSON.parse(readFileSync(publisher.path, "utf8")).closed, true);
  assert.equal(publisher.snapshot.status, "Completed");
});

test("commands require a current token/action/time and are consumed once without signalling a PID", (t) => {
  const publisher = setup(t);
  const request = (patch: Record<string, unknown> = {}) => {
    atomicJSON(publisher.commandPath, { token: publisher.snapshot.token, action: "abort", createdAt: Date.now(), ...patch });
    return publisher.consumeCommand();
  };
  assert.equal(request(), "abort");
  assert.equal(publisher.consumeCommand(), undefined);
  assert.equal(request({ action: "shutdown" }), "shutdown");
  for (const patch of [{ token: "old-token" }, { action: "kill" }, { createdAt: Date.now() - 11000 }, { createdAt: Date.now() + 60000 }, { createdAt: "now" }]) assert.equal(request(patch), undefined);
  writeFileSync(publisher.commandPath, "malformed JSON");
  assert.equal(publisher.consumeCommand(), undefined);
  writeFileSync(publisher.commandPath, "x".repeat(4097));
  assert.equal(publisher.consumeCommand(), undefined);
  assert.deepEqual(readdirSync(join(publisher.root, "commands")), []);
});

test("managed run IDs are validated and fresh tokens reject requests from a previous runtime", (t) => {
  const publisher = setup(t);
  const current = new InstancePublisher(publisher.root, "/tmp", publisher.snapshot.id);
  assert.equal(current.snapshot.id, publisher.snapshot.id);
  assert.notEqual(current.snapshot.token, publisher.snapshot.token);
  assert.equal(current.snapshot.logFile, join(publisher.root, "logs", `${publisher.snapshot.id}.log`));
  atomicJSON(current.commandPath, { token: publisher.snapshot.token, action: "shutdown", createdAt: Date.now() });
  assert.equal(current.consumeCommand(), undefined);
  const invalid = new InstancePublisher(publisher.root, "/tmp", "../../escape");
  assert.notEqual(invalid.snapshot.id, "../../escape");
  assert.equal(invalid.snapshot.logFile, undefined);
});
