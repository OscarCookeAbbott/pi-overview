import { stripVTControlCharacters } from "node:util";

export const PI_OVERVIEW_KEY = Symbol.for("pi.overview");
export type OverviewItemState = "running" | "complete" | "failed" | "waiting" | "pending" | "cancelled" | "unknown";
export interface OverviewItem { title: string; state?: OverviewItemState; detail?: string }
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

/** Accept only bounded display data, never callbacks or executable actions. */
export function normalizeContribution(value: unknown): OverviewContribution {
  const raw = object(value);
  if (typeof raw.id !== "string" || !/^[a-z][a-z0-9._-]{0,39}$/.test(raw.id) || !Array.isArray(raw.sections)) throw new Error("Overview requires a stable id and sections array.");
  return {
    id: raw.id, badge: text(raw.badge, 40, true),
    sections: raw.sections.slice(0, 3).map((value) => {
      const section = object(value);
      if (!Array.isArray(section.items)) throw new Error("Overview section items must be an array.");
      const items: OverviewItem[] = section.items.slice(0, section.items.length > 20 ? 19 : 20).map((value) => {
        const item = object(value);
        const state = item.state ?? "pending";
        if (!["running", "complete", "failed", "waiting", "pending", "cancelled", "unknown"].includes(state as string)) throw new Error("Invalid overview item state.");
        return { title: text(item.title, 80), state: state as OverviewItemState, ...(item.detail === undefined ? {} : { detail: text(item.detail, 120, true) }) };
      });
      if (section.items.length > 20) items.push({ title: `… ${section.items.length - 19} more items`, state: "unknown" });
      return { title: text(section.title, 40), items };
    }),
  };
}
