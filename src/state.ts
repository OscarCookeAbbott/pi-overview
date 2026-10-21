import { randomUUID } from "node:crypto";
import { chmodSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { stripVTControlCharacters } from "node:util";
import { homedir } from "node:os";
import type { OverviewContribution } from "./contributions.ts";

export interface OverviewConfig {
  enabled: boolean;
  autoStart: boolean;
  showOutput: boolean;
  defaultDirectory: string;
}

export function readConfig(settings: unknown, cwd = process.cwd()): OverviewConfig {
  const raw = (settings as { overview?: unknown } | undefined)?.overview;
  const config = { enabled: true, autoStart: true, showOutput: true, defaultDirectory: homedir() };
  if (raw === undefined) return config;
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) throw new Error("overview must be an object.");
  for (const [key, value] of Object.entries(raw)) {
    if (key === "defaultDirectory") {
      if (typeof value !== "string" || !value.trim()) throw new Error("overview.defaultDirectory must be a nonblank path.");
      const path = value === "~" ? homedir() : value.startsWith("~/") ? join(homedir(), value.slice(2)) : value;
      config.defaultDirectory = resolve(cwd, path);
    } else if (key === "enabled" || key === "autoStart" || key === "showOutput") {
      if (typeof value !== "boolean") throw new Error(`overview.${key} must be a boolean.`);
      config[key] = value;
    } else throw new Error(`Unknown overview setting: ${key}`);
  }
  return config;
}

export function preview(text: string): string {
  return [...stripVTControlCharacters(text).replace(/[\x00-\x1f\x7f-\x9f]/g, " ").replace(/\s+/g, " ").trim()].slice(0, 400).join("");
}

export function ensureDirectories(root: string): void {
  for (const path of [root, ...["records", "commands", "inputs", "logs", "sessions", "bin"].map((name) => join(root, name))]) {
    mkdirSync(path, { recursive: true, mode: 0o700 });
    chmodSync(path, 0o700);
  }
}

export function atomicJSON(path: string, value: unknown): void {
  const temporary = `${path}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, JSON.stringify(value), { mode: 0o600, flag: "wx" });
    renameSync(temporary, path);
  } finally {
    rmSync(temporary, { force: true });
  }
}

export interface InstanceSnapshot {
  version: 1;
  id: string;
  token: string;
  pid: number;
  cwd: string;
  projectName: string;
  sessionId?: string;
  sessionFile?: string;
  sessionName?: string;
  logFile?: string;
  status: string;
  busy: boolean;
  closed: boolean;
  lastOutput: string;
  lastActivity?: string;
  headless?: boolean;
  acceptsInput?: boolean;
  contributions?: OverviewContribution[];
  updatedAt: number;
  heartbeatAt: number;
}

type Update = Partial<Pick<InstanceSnapshot, "cwd" | "projectName" | "sessionId" | "sessionFile" | "sessionName" | "status" | "busy" | "lastOutput" | "lastActivity" | "contributions" | "headless" | "acceptsInput">>;
export type ControlAction = "abort" | "shutdown";

export class InstancePublisher {
  readonly root: string;
  readonly path: string;
  readonly commandPath: string;
  snapshot: InstanceSnapshot;
  private readonly inputResults = new Map<string, string>();

  constructor(root: string, cwd: string, launchId?: string) {
    this.root = root;
    ensureDirectories(root);
    const managed = launchId !== undefined && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(launchId);
    const id = managed ? launchId : randomUUID();
    this.path = join(root, "records", `${id}.json`);
    this.commandPath = join(root, "commands", `${id}.json`);
    this.snapshot = {
      version: 1, id, token: randomUUID(), pid: process.pid, cwd: resolve(cwd), projectName: basename(resolve(cwd)) || cwd,
      status: "Idle", busy: false, closed: false, lastOutput: "", lastActivity: "", updatedAt: Date.now(), heartbeatAt: Date.now(),
      ...(managed ? { logFile: join(root, "logs", `${id}.log`) } : {}),
    };
    this.update({});
  }

  update(patch: Update): void {
    if (this.snapshot.closed) return;
    this.snapshot = { ...this.snapshot, ...patch, updatedAt: Date.now(), heartbeatAt: Date.now() };
    atomicJSON(this.path, this.snapshot);
  }

  heartbeat(): void {
    if (this.snapshot.closed) return;
    this.snapshot.heartbeatAt = Date.now();
    atomicJSON(this.path, this.snapshot);
  }

  consumeCommand(): ControlAction | undefined {
    if (this.snapshot.closed) return;
    const claimed = `${this.commandPath}.${randomUUID()}.processing`;
    try {
      renameSync(this.commandPath, claimed);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
      throw error;
    }
    try {
      if (statSync(claimed).size > 4096) return;
      const command: unknown = JSON.parse(readFileSync(claimed, "utf8"));
      if (typeof command !== "object" || command === null) return;
      const { token, action, createdAt } = command as Record<string, unknown>;
      if (token !== this.snapshot.token || (action !== "abort" && action !== "shutdown") || typeof createdAt !== "number" || !Number.isFinite(createdAt)) return;
      const age = Date.now() - createdAt;
      if (age < 0 || age > 10000) return;
      return action;
    } catch (error) {
      if (error instanceof SyntaxError) return;
      throw error;
    } finally {
      rmSync(claimed, { force: true });
    }
  }

  consumeInput(send: (message: string) => void): void {
    if (this.snapshot.closed || !this.snapshot.headless || !this.snapshot.acceptsInput) return;
    const path = join(this.root, "inputs", `${this.snapshot.id}.json`);
    const claimed = `${path}.${randomUUID()}.processing`;
    try { renameSync(path, claimed); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
      throw error;
    }
    try {
      if (statSync(claimed).size > 400000) return;
      const request: unknown = JSON.parse(readFileSync(claimed, "utf8"));
      if (!request || typeof request !== "object") return;
      const { id, token, sessionId, sessionFile, createdAt, message } = request as Record<string, unknown>;
      if (token !== this.snapshot.token || typeof id !== "string" || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id)) return;
      const receipt = join(this.root, "inputs", `${this.snapshot.id}.result.json`);
      const previous = this.inputResults.get(id);
      if (previous) { atomicJSON(receipt, { id, token, status: previous }); return; }
      const age = typeof createdAt === "number" ? Date.now() - createdAt : NaN;
      let status = "rejected";
      if (sessionId === this.snapshot.sessionId && sessionFile === this.snapshot.sessionFile && Number.isFinite(age) && age >= 0 && age <= 10000 &&
          typeof message === "string" && message.trim() && Buffer.byteLength(message) <= 65536) {
        this.inputResults.set(id, status);
        try { send(message); status = "submitted"; } catch { /* Receipt reports a synchronous dispatch failure without exposing prompt data. */ }
        this.inputResults.set(id, status);
      }
      atomicJSON(receipt, { id, token, status });
    } catch (error) {
      if (!(error instanceof SyntaxError)) throw error;
    } finally { rmSync(claimed, { force: true }); }
  }

  close(): void {
    if (this.snapshot.closed) return;
    let status = this.snapshot.status;
    if (this.snapshot.busy) status = "Exited";
    else if (!["Completed", "Aborted", "Error"].includes(status)) status = "Closed";
    this.snapshot = { ...this.snapshot, status, busy: false, closed: true, updatedAt: Date.now(), heartbeatAt: Date.now() };
    atomicJSON(this.path, this.snapshot);
    rmSync(this.commandPath, { force: true });
    rmSync(join(this.root, "inputs", `${this.snapshot.id}.json`), { force: true });
  }
}
