import { basename, join, resolve } from "node:path";
import { readFileSync } from "node:fs";
import { execFile } from "node:child_process";
import { getAgentDir, type ExtensionAPI, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { startCompanion, writeLauncher } from "./companion.ts";
import { atomicJSON, InstancePublisher, preview, readConfig } from "./state.ts";
import { normalizeContribution, PI_OVERVIEW_KEY, type OverviewContribution, type OverviewService } from "./contributions.ts";

export { PI_OVERVIEW_KEY } from "./contributions.ts";
export type { OverviewContribution, OverviewItem, OverviewItemState, OverviewSection, OverviewService } from "./contributions.ts";

export default function overviewExtension(pi: ExtensionAPI): void {
  const root = resolve(process.env.PI_OVERVIEW_DIR ?? join(getAgentDir(), "overview"));
  const globals = globalThis as Record<symbol, unknown>;
  const contributions = new Map<string, OverviewContribution>();
  let contributionSubscriptions: Array<() => void> = [];
  const launchId = process.env.PI_OVERVIEW_LAUNCH_ID;
  // This ID belongs to this launched runtime, not Pi processes it may spawn later.
  delete process.env.PI_OVERVIEW_LAUNCH_ID;
  let config = readConfig({});
  let publisher: InstancePublisher | undefined;
  let context: ExtensionContext | undefined;
  let timer: NodeJS.Timeout | undefined;
  let removeExitHook: (() => void) | undefined;
  let startup: Promise<void> | undefined;
  let controller = new AbortController();
  let warned = false;
  let failed = false;
  const tools = new Map<string, string>();

  function warn(error: unknown): void {
    if (warned) return;
    warned = true;
    try { context?.ui.notify(`Pi Overview: ${error instanceof Error ? error.message : String(error)}`, "warning"); } catch { /* Headless operation does not require UI. */ }
  }

  function sync(patch: Parameters<InstancePublisher["update"]>[0] = {}, ctx = context): void {
    if (!publisher || !ctx) return;
    context = ctx;
    try {
      publisher.update({ cwd: ctx.cwd, projectName: basename(ctx.cwd) || ctx.cwd, sessionFile: ctx.sessionManager.getSessionFile(), sessionName: ctx.sessionManager.getSessionName(), contributions: [...contributions.values()], ...patch });
    } catch (error) { warn(error); }
  }

  const service: OverviewService = {
    publish(value) {
      try {
        const contribution = normalizeContribution(value);
        if (!contributions.has(contribution.id) && contributions.size >= 4) return { success: false, error: "Overview supports at most four contribution sources per instance." };
        contributions.set(contribution.id, contribution);
        sync();
        return { success: true };
      } catch (error) { return { success: false, error: error instanceof Error ? error.message : String(error) }; }
    },
    remove(id) { if (contributions.delete(id)) sync(); },
  };

  function subscribeContributions(): void {
    if (!contributionSubscriptions.length) contributionSubscriptions = [
      pi.events.on("overview:publish", (value) => { service.publish(value as OverviewContribution); }),
      pi.events.on("overview:remove", (id) => { if (typeof id === "string") service.remove(id); }),
    ];
    globals[PI_OVERVIEW_KEY] = service;
  }
  subscribeContributions();

  function cleanup(): void {
    controller.abort();
    if (timer) clearInterval(timer);
    timer = undefined;
    removeExitHook?.();
    removeExitHook = undefined;
    try { publisher?.close(); } catch (error) { warn(error); }
    publisher = undefined;
    context = undefined;
    tools.clear();
    startup = undefined;
    contributionSubscriptions.forEach((off) => off());
    contributionSubscriptions = [];
    contributions.clear();
    if (globals[PI_OVERVIEW_KEY] === service) delete globals[PI_OVERVIEW_KEY];
  }

  function start(): Promise<void> {
    if (!startup) {
      const pending = startCompanion(root, controller.signal);
      startup = pending;
      const finished = () => { if (startup === pending) startup = undefined; };
      void pending.then(finished, finished);
    }
    return startup;
  }

  function toolStatus(): string {
    const first = tools.values().next().value;
    if (tools.size === 1 && first) return `Running: ${preview(first)}`;
    return tools.size ? `Running ${tools.size} tools` : "Thinking";
  }

  pi.on("session_start", async (_event, ctx) => {
    cleanup();
    controller = new AbortController();
    context = ctx;
    subscribeContributions();
    warned = false;
    failed = false;
    try { config = readConfig(pi.getSettings(), ctx.cwd); } catch (error) { config = { ...readConfig({}), enabled: false }; warn(error); }
    if (!config.enabled || process.platform !== "darwin") return;
    try {
      publisher = new InstancePublisher(root, ctx.cwd, launchId);
      sync({}, ctx);
      const current = publisher;
      const onExit = () => { try { current.close(); } catch { /* Best-effort exit snapshot. */ } };
      process.on("exit", onExit);
      removeExitHook = () => process.removeListener("exit", onExit);
      timer = setInterval(() => {
        try {
          const action = current.consumeCommand();
          if (action === "abort" && context && !context.isIdle()) { sync({ status: "Aborting" }); context.abort(); }
          if (action === "shutdown") { sync({ status: "Stopping" }); context?.shutdown(); }
          current.heartbeat();
        } catch (error) { warn(error); }
      }, 1000);
      timer.unref();
      pi.events.emit("overview:collect", undefined);
      await writeLauncher(root, config.defaultDirectory);
      if (publisher === current && config.autoStart && ctx.mode === "tui") {
        const signal = controller.signal;
        void start().catch((error) => { if (publisher === current && !signal.aborted) warn(error); });
      }
    } catch (error) { warn(error); }
  });
  pi.on("session_shutdown", cleanup);
  pi.on("session_info_changed", (_event, ctx) => sync({}, ctx));
  pi.on("session_tree", (_event, ctx) => sync({ lastOutput: "" }, ctx));
  pi.on("agent_start", (_event, ctx) => {
    tools.clear();
    failed = false;
    sync({ status: "Thinking", busy: true, lastOutput: "" }, ctx);
  });
  pi.on("tool_execution_start", (event, ctx) => {
    tools.set(event.toolCallId, event.toolName);
    sync({ status: toolStatus(), busy: true }, ctx);
  });
  pi.on("tool_execution_end", (event, ctx) => {
    tools.delete(event.toolCallId);
    sync({ status: toolStatus(), busy: true }, ctx);
  });
  pi.on("message_end", (event, ctx) => {
    if (event.message.role !== "assistant" || !config.showOutput) return;
    const text = event.message.content.flatMap((part) => part.type === "text" ? [part.text] : []).join("\n");
    sync({ lastOutput: preview(text) }, ctx);
  });
  pi.on("agent_end", (event, ctx) => {
    const assistant = event.messages.findLast((message) => message.role === "assistant");
    failed = assistant?.stopReason === "error";
    sync({ status: "Finishing", busy: true }, ctx);
  });
  pi.on("agent_settled", (event, ctx) => {
    tools.clear();
    let status = "Completed";
    if (event.aborted) status = "Aborted";
    else if (failed) status = "Error";
    sync({ status, busy: false }, ctx);
  });

  pi.registerCommand("overview", {
    description: "Pi menu bar: status, start, stop, or folder",
    async handler(args, ctx) {
      const action = args.trim() || "status";
      if (process.platform !== "darwin") { ctx.ui.notify("Pi Overview's native companion requires macOS.", "warning"); return; }
      if (!publisher) { ctx.ui.notify("Pi Overview is disabled or could not initialise; check overview settings and session warnings.", "warning"); return; }
      try {
        if (action === "start") { await writeLauncher(root, config.defaultDirectory); await start(); ctx.ui.notify("Pi Overview launch requested. An existing companion is reused.", "info"); }
        else if (action === "stop") {
          controller.abort();
          controller = new AbortController();
          startup = undefined;
          atomicJSON(join(root, "daemon-command.json"), { action: "quit", createdAt: Date.now() });
          ctx.ui.notify("Pi Overview quit requested; Pi sessions are not stopped.", "info");
        }
        else if (action === "folder") await new Promise<void>((done, reject) => execFile("/usr/bin/open", [root], { timeout: 5000 }, (error) => error ? reject(error) : done()));
        else if (action === "status") {
          let running = false;
          try {
            const info = JSON.parse(readFileSync(join(root, "daemon.json"), "utf8")) as { heartbeatAt?: number };
            running = typeof info.heartbeatAt === "number" && Date.now() - info.heartbeatAt < 10000;
          } catch { /* Missing or stale companion metadata is not a session error. */ }
          let status = startup ? "companion building/starting" : "companion not running";
          if (running) status = "companion running";
          ctx.ui.notify(`Pi Overview: ${status}\nState: ${publisher.snapshot.status}\nDirectory: ${root}`, "info");
        } else ctx.ui.notify("Usage: /overview [status|start|stop|folder]", "warning");
      } catch (error) { ctx.ui.notify(`Pi Overview: ${error instanceof Error ? error.message : String(error)}`, "warning"); }
    },
  });
}
