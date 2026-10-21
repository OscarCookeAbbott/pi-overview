import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { createEventBus, type ExtensionAPI, type ExtensionCommandContext, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import extension, { PI_OVERVIEW_KEY, type OverviewService } from "../src/index.ts";
import { atomicJSON, type InstanceSnapshot } from "../src/state.ts";

function harness(t: TestContext, overview: Record<string, unknown> = { autoStart: false }) {
  const dir = mkdtempSync(join(tmpdir(), "pi-overview-ext-"));
  const root = join(dir, "overview");
  const oldRoot = process.env.PI_OVERVIEW_DIR;
  process.env.PI_OVERVIEW_DIR = root;
  const handlers = new Map<string, (event: any, ctx: ExtensionContext) => any>();
  const events = createEventBus();
  const globals = globalThis as Record<symbol, unknown>;
  const previousService = globals[PI_OVERVIEW_KEY];
  const notices: string[] = [];
  let command!: { handler(args: string, ctx: ExtensionCommandContext): Promise<void> };
  let aborts = 0, shutdowns = 0, idle = true;
  const ctx = {
    mode: "tui", cwd: dir, isIdle: () => idle,
    abort: () => { aborts++; }, shutdown: () => { shutdowns++; },
    sessionManager: { getSessionId: () => "stable-session-id", getSessionFile: () => join(dir, "exact.jsonl"), getSessionName: () => "Example session" },
    ui: { notify: (text: string) => notices.push(text) },
  } as unknown as ExtensionContext;
  const exitListeners = process.listenerCount("exit");
  extension({
    on: (name: string, handler: (event: any, ctx: ExtensionContext) => any) => handlers.set(name, handler),
    getSettings: () => ({ overview }),
    events,
    registerCommand: (name: string, value: typeof command) => { assert.equal(name, "overview"); command = value; },
  } as unknown as ExtensionAPI);
  const emit = (name: string, event: unknown = {}) => handlers.get(name)?.(event, ctx);
  t.after(() => {
    emit("session_shutdown");
    if (previousService === undefined) delete globals[PI_OVERVIEW_KEY];
    else globals[PI_OVERVIEW_KEY] = previousService;
    assert.equal(process.listenerCount("exit"), exitListeners);
    if (oldRoot === undefined) delete process.env.PI_OVERVIEW_DIR;
    else process.env.PI_OVERVIEW_DIR = oldRoot;
    rmSync(dir, { recursive: true, force: true });
  });
  return {
    root, ctx, notices, emit, events,
    service: globals[PI_OVERVIEW_KEY] as OverviewService,
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

test("non-macOS overview is silent even for invalid settings and explicit commands", async (t) => {
  for (const platform of ["linux", "win32"]) await t.test(platform, async (t) => {
    const descriptor = Object.getOwnPropertyDescriptor(process, "platform")!;
    try {
      Object.defineProperty(process, "platform", { ...descriptor, value: platform });
      const h = harness(t, { unknown: true });
      await h.emit("session_start");
      for (const command of ["status", "start", "stop", "folder"]) await h.command(command);
      assert.deepEqual(h.notices, []);
      assert.equal(existsSync(h.root), false);
      assert.equal(h.service, undefined);
    } finally { Object.defineProperty(process, "platform", descriptor); }
  });
});

test("factory starts no resources; disabled settings do not publish or launch", async (t) => {
  const h = harness(t, { enabled: false });
  assert.equal(existsSync(h.root), false);
  await h.emit("session_start");
  assert.equal(existsSync(h.root), false);
  await h.command("status");
  if (process.platform === "darwin") assert.match(h.notices.at(-1)!, /disabled/);
  else assert.deepEqual(h.notices, []);
});

test("status exposes the live companion version and build without starting GUI resources", macOnly, async (t) => {
  const h = harness(t);
  await h.emit("session_start");
  atomicJSON(join(h.root, "daemon.json"), { pid: process.pid, heartbeatAt: Date.now(), version: "0.6.0", build: "1234567890abcdef", instanceId: "test" });
  await h.command("status");
  assert.match(h.notices.at(-1)!, /companion running v0\.6\.0 \(12345678\)/);
  assert.equal(existsSync(join(h.root, "companion.log")), false);
});

test("parallel tools and intermediate turns remain busy until agent_settled; only assistant text is exposed", macOnly, async (t) => {
  const h = harness(t);
  await h.emit("session_start");
  assert.equal(h.read().status, "Idle");
  assert.equal(h.read().sessionName, "Example session");
  assert.equal(h.read().sessionId, "stable-session-id");
  h.emit("agent_start");
  assert.equal(h.read().status, "Working");
  assert.equal(h.read().lastActivity, "Agent started");
  h.emit("tool_execution_start", { toolCallId: "one", toolName: "read", args: { secret: "PRIVATE_ARGS" } });
  h.emit("tool_execution_start", { toolCallId: "two", toolName: "bash" });
  assert.equal(h.read().status, "Running 2 tools");
  assert.equal(h.read().lastActivity, "Tool started · bash");
  h.emit("tool_execution_end", { toolCallId: "two" });
  assert.equal(h.read().status, "Running: read");
  h.emit("tool_execution_end", { toolCallId: "one", result: { content: [{ type: "text", text: "PRIVATE_RESULT" }] } });
  assert.equal(h.read().status, "Working");
  assert.equal(h.read().lastActivity, "Tool finished · read");
  h.emit("message_end", { message: { role: "toolResult", content: [{ type: "text", text: "PRIVATE_TOOL" }] } });
  h.emit("message_end", { message: { role: "assistant", content: [{ type: "thinking", thinking: "PRIVATE_THINKING" }, { type: "text", text: "Visible\nanswer" }] } });
  h.emit("agent_end", { messages: [] });
  assert.equal(h.read().busy, true);
  assert.equal(h.read().status, "Finishing");
  assert.equal(h.read().lastOutput, "Visible answer");
  assert.equal(h.read().lastActivity, "Message · Visible answer");
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
  assert.equal(h.read().lastActivity, "Agent started");
  assert.ok(!JSON.stringify(h.read()).includes("PRIVATE_OUTPUT"));
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

test("recent tool activity stays bounded and excludes arguments/results; session navigation clears it", macOnly, async (t) => {
  const h = harness(t);
  await h.emit("session_start");
  h.emit("tool_execution_start", { toolCallId: "failed", toolName: "read", args: { text: "PRIVATE_ARGS" } });
  h.emit("tool_execution_end", { toolCallId: "failed", isError: true, result: { text: "PRIVATE_RESULT" } });
  assert.equal(h.read().lastActivity, "Tool failed · read");
  h.emit("tool_execution_start", { toolCallId: "long", toolName: "x".repeat(500) + "\u001b[2A" });
  assert.ok(h.read().lastActivity!.length <= 400);
  assert.ok(!h.read().lastActivity!.includes("\u001b"));
  assert.ok(!JSON.stringify(h.read()).includes("PRIVATE"));
  h.emit("session_tree");
  assert.equal(h.read().lastActivity, "");
  assert.equal(h.read().lastOutput, "");
});

test("overview contributions survive startup ordering, update/remove safely, and use the configured launch directory", macOnly, async (t) => {
  const h = harness(t, { autoStart: false, defaultDirectory: "~/Workspace" });
  const contribution = { id: "tasks", badge: "3/6 tasks", sections: [{ title: "Tasks", items: [{ title: "Example task", state: "running" as const }] }] };
  h.service.publish(contribution);
  const off = h.events.on("overview:collect", () => h.events.emit("overview:publish", contribution));
  t.after(off);
  await h.emit("session_start");
  assert.equal(h.read().contributions?.[0].badge, "3/6 tasks");
  assert.equal(JSON.parse(readFileSync(join(h.root, "launcher.json"), "utf8")).cwd, join(homedir(), "Workspace"));
  contribution.sections[0].items[0].title = "Mutated caller data";
  h.emit("agent_start");
  assert.equal(h.read().contributions?.[0].sections[0].items[0].title, "Example task");
  for (let i = 0; i < 3; i++) assert.equal(h.service.publish({ id: `extra${i}`, badge: "Badge", sections: [] }).success, true);
  assert.equal(h.service.publish({ id: "overflow", badge: "Badge", sections: [] }).success, true);
  assert.equal(h.read().contributions?.length, 5);
  h.events.emit("overview:remove", "extra0");
  assert.equal(h.service.publish({ id: "overflow", badge: "Badge", sections: [] }).success, true);
  h.emit("session_shutdown");
  assert.equal((globalThis as Record<symbol, unknown>)[PI_OVERVIEW_KEY], undefined);
});
