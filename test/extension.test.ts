import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import extension from "../src/index.ts";
import { atomicJSON, type InstanceSnapshot } from "../src/state.ts";

function harness(t: TestContext, overview: Record<string, unknown> = { autoStart: false }) {
  const dir = mkdtempSync(join(tmpdir(), "pi-overview-ext-"));
  const root = join(dir, "overview");
  const oldRoot = process.env.PI_OVERVIEW_DIR;
  process.env.PI_OVERVIEW_DIR = root;
  const handlers = new Map<string, (event: any, ctx: ExtensionContext) => any>();
  const notices: string[] = [];
  let command!: { handler(args: string, ctx: ExtensionCommandContext): Promise<void> };
  let aborts = 0, shutdowns = 0, idle = true;
  const ctx = {
    mode: "tui", cwd: dir, isIdle: () => idle,
    abort: () => { aborts++; }, shutdown: () => { shutdowns++; },
    sessionManager: { getSessionFile: () => join(dir, "exact.jsonl"), getSessionName: () => "Example session" },
    ui: { notify: (text: string) => notices.push(text) },
  } as unknown as ExtensionContext;
  const exitListeners = process.listenerCount("exit");
  extension({
    on: (name: string, handler: (event: any, ctx: ExtensionContext) => any) => handlers.set(name, handler),
    getSettings: () => ({ overview }),
    registerCommand: (name: string, value: typeof command) => { assert.equal(name, "overview"); command = value; },
  } as unknown as ExtensionAPI);
  const emit = (name: string, event: unknown = {}) => handlers.get(name)?.(event, ctx);
  t.after(() => {
    emit("session_shutdown");
    assert.equal(process.listenerCount("exit"), exitListeners);
    if (oldRoot === undefined) delete process.env.PI_OVERVIEW_DIR;
    else process.env.PI_OVERVIEW_DIR = oldRoot;
    rmSync(dir, { recursive: true, force: true });
  });
  return {
    root, ctx, notices, emit,
    command: (args: string) => command.handler(args, ctx as ExtensionCommandContext),
    setIdle(value: boolean) { idle = value; },
    get aborts() { return aborts; }, get shutdowns() { return shutdowns; },
    read(): InstanceSnapshot {
      const files = readdirSync(join(root, "records")).filter((name) => name.endsWith(".json"));
      assert.equal(files.length, 1);
      return JSON.parse(readFileSync(join(root, "records", files[0]), "utf8"));
    },
  };
}

const macOnly = { skip: process.platform !== "darwin" };

test("factory starts no resources; disabled settings do not publish or launch", async (t) => {
  const h = harness(t, { enabled: false });
  assert.equal(existsSync(h.root), false);
  await h.emit("session_start");
  assert.equal(existsSync(h.root), false);
  await h.command("status");
  assert.match(h.notices.at(-1)!, /disabled|macOS/);
});

test("parallel tools and intermediate turns remain busy until agent_settled; only assistant text is exposed", macOnly, async (t) => {
  const h = harness(t);
  await h.emit("session_start");
  assert.equal(h.read().status, "Ready");
  assert.equal(h.read().sessionName, "Example session");
  h.emit("agent_start");
  h.emit("tool_execution_start", { toolCallId: "one", toolName: "read", args: { secret: "PRIVATE_ARGS" } });
  h.emit("tool_execution_start", { toolCallId: "two", toolName: "bash" });
  assert.equal(h.read().status, "Running 2 tools");
  h.emit("tool_execution_end", { toolCallId: "two" });
  assert.equal(h.read().status, "Running: read");
  h.emit("tool_execution_end", { toolCallId: "one" });
  h.emit("message_end", { message: { role: "toolResult", content: [{ type: "text", text: "PRIVATE_TOOL" }] } });
  h.emit("message_end", { message: { role: "assistant", content: [{ type: "thinking", thinking: "PRIVATE_THINKING" }, { type: "text", text: "Visible\nanswer" }] } });
  h.emit("agent_end", { messages: [] });
  assert.equal(h.read().busy, true);
  assert.equal(h.read().status, "Finishing");
  assert.equal(h.read().lastOutput, "Visible answer");
  assert.ok(!JSON.stringify(h.read()).includes("PRIVATE"));
  h.emit("agent_settled", { aborted: false });
  assert.equal(h.read().status, "Completed");
  assert.equal(h.read().busy, false);
  await h.command("status");
  assert.match(h.notices.at(-1)!, /Completed/);
  h.emit("session_shutdown");
  h.emit("session_shutdown");
  assert.equal(h.read().closed, true);
  assert.equal(h.read().status, "Completed");
});

test("private mailbox requests abort/shutdown through Pi APIs; hidden previews stay hidden", macOnly, async (t) => {
  const h = harness(t, { autoStart: false, showOutput: false });
  t.mock.timers.enable({ apis: ["setInterval"] });
  await h.emit("session_start");
  const snapshot = h.read();
  const command = join(h.root, "commands", `${snapshot.id}.json`);
  h.setIdle(false);
  h.emit("agent_start");
  h.emit("message_end", { message: { role: "assistant", content: [{ type: "text", text: "PRIVATE_OUTPUT" }] } });
  assert.equal(h.read().lastOutput, "");
  atomicJSON(command, { token: snapshot.token, action: "abort", createdAt: Date.now() });
  t.mock.timers.tick(1000);
  assert.equal(h.aborts, 1);
  h.emit("agent_settled", { aborted: true });
  assert.equal(h.read().status, "Aborted");
  atomicJSON(command, { token: "wrong-token", action: "shutdown", createdAt: Date.now() });
  t.mock.timers.tick(1000);
  assert.equal(h.shutdowns, 0);
  atomicJSON(command, { token: snapshot.token, action: "shutdown", createdAt: Date.now() });
  t.mock.timers.tick(1000);
  assert.equal(h.shutdowns, 1);
  h.emit("session_shutdown");
  assert.equal(h.read().closed, true);
});
