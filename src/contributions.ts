import { stripVTControlCharacters } from "node:util";

export const PI_OVERVIEW_KEY = Symbol.for("pi.overview");
export type OverviewItemState = "running" | "complete" | "failed" | "waiting" | "pending" | "cancelled" | "unknown";
export interface OverviewItem { title: string; state?: OverviewItemState; detail?: string; children?: OverviewItem[] }
export interface OverviewSection { title: string; items: OverviewItem[] }
export interface OverviewContribution { id: string; badge: string; sections: OverviewSection[] }
export interface OverviewService {
  publish(contribution: OverviewContribution): { success: boolean; error?: string };
  remove(id: string): void;
}

function object(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("Overview contributions must contain objects.");
  return value as Record<string, unknown>;
}
function text(value: unknown, limit: number, optional = false): string {
  if (typeof value !== "string" || (!optional && !value.trim())) throw new Error("Overview labels must be nonblank strings.");
  const cleaned = [...stripVTControlCharacters(value).replace(/[\x00-\x1f\x7f-\x9f]/g, " ").trim()].slice(0, limit).join("");
  if (!optional && !cleaned) throw new Error("Overview labels must contain visible text.");
  return cleaned;
}
function detail(value: unknown): string {
  if (typeof value !== "string") throw new Error("Overview detail must be text.");
  return stripVTControlCharacters(value).replace(/\r\n?/g, "\n").replace(/\t/g, "    ").replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f]/g, " ").trim();
}
function normalizeItem(value: unknown, ancestors: Set<object>): OverviewItem {
  const item = object(value);
  if (ancestors.has(item)) throw new Error("Overview items must not contain cycles.");
  const state = item.state ?? "pending";
  if (!["running", "complete", "failed", "waiting", "pending", "cancelled", "unknown"].includes(state as string)) throw new Error("Invalid overview item state.");
  if (item.children !== undefined && !Array.isArray(item.children)) throw new Error("Overview children must be an array.");
  ancestors.add(item);
  try {
    return {
      title: text(item.title, 80), state: state as OverviewItemState,
      ...(item.detail === undefined ? {} : { detail: detail(item.detail) }),
      ...(item.children === undefined ? {} : { children: (item.children as unknown[]).map((child) => normalizeItem(child, ancestors)) }),
    };
  } finally { ancestors.delete(item); }
}

/** Accept display-only trees, never callbacks or executable actions. */
export function normalizeContribution(value: unknown): OverviewContribution {
  const raw = object(value);
  if (typeof raw.id !== "string" || !/^[a-z][a-z0-9._-]{0,39}$/.test(raw.id) || !Array.isArray(raw.sections)) throw new Error("Overview requires a stable id and sections array.");
  return {
    id: raw.id, badge: text(raw.badge, 40, true),
    sections: raw.sections.map((value) => {
      const section = object(value);
      if (!Array.isArray(section.items)) throw new Error("Overview section items must be an array.");
      return { title: text(section.title, 40), items: section.items.map((item) => normalizeItem(item, new Set())) };
    }),
  };
}
