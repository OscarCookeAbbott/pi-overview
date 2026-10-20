export interface CompanionBuild {
  version: string;
  build: string;
}

export interface CompanionHeartbeat {
  pid: number;
  heartbeatAt: number;
  instanceId?: string;
  version?: string;
  build?: string;
}

export interface CompanionRuntime {
  read(): Promise<CompanionHeartbeat | undefined>;
  quit(target: CompanionHeartbeat): void;
  exited(target: CompanionHeartbeat): boolean;
  launch(): Promise<void>;
  wait(signal?: AbortSignal): Promise<void>;
  now(): number;
}

function newerVersion(current: string | undefined, expected: string): boolean {
  const parse = (value: string) => /^(\d+)\.(\d+)\.(\d+)(?:-([\w.-]+))?(?:\+[\w.-]+)?$/.exec(value);
  const left = current && parse(current), right = parse(expected);
  if (!left || !right) return false;
  for (let index = 1; index <= 3; index++) {
    if (Number(left[index]) !== Number(right[index])) return Number(left[index]) > Number(right[index]);
  }
  if (left[4] === right[4]) return false;
  if (!left[4] || !right[4]) return !left[4];
  const a = left[4].split("."), b = right[4].split(".");
  for (let index = 0; index < Math.max(a.length, b.length); index++) {
    if (a[index] === b[index]) continue;
    if (a[index] === undefined || b[index] === undefined) return a[index] !== undefined;
    const aNumber = /^\d+$/.test(a[index]), bNumber = /^\d+$/.test(b[index]);
    if (aNumber && bNumber) return Number(a[index]) > Number(b[index]);
    if (aNumber !== bNumber) return !aNumber;
    return a[index] > b[index];
  }
  return false;
}

/** Reconcile only the companion; the native advisory lock arbitrates concurrent launches. */
export async function reconcileCompanion(expected: CompanionBuild, runtime: CompanionRuntime, signal?: AbortSignal): Promise<void> {
  const deadline = runtime.now() + 15000;
  let target: CompanionHeartbeat | undefined;
  let launched = false;
  while (runtime.now() < deadline) {
    signal?.throwIfAborted();
    const current = await runtime.read();
    signal?.throwIfAborted();
    if (current) {
      if ((current.version === expected.version && current.build === expected.build) || newerVersion(current.version, expected.version)) return;
      const identity = `${current.pid}:${current.instanceId ?? "legacy"}`;
      if (target && `${target.pid}:${target.instanceId ?? "legacy"}` !== identity) throw new Error("Another Pi Overview build started during replacement; reload to retry.");
      if (!target) {
        runtime.quit(current);
        target = current;
      }
    } else if (!launched && (!target || runtime.exited(target))) {
      signal?.throwIfAborted();
      await runtime.launch();
      launched = true;
    }
    await runtime.wait(signal);
  }
  throw new Error("Pi Overview did not complete startup/replacement within 15 seconds; the existing companion was not force-stopped. See companion.log.");
}
