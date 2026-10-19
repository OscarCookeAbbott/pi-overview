import assert from "node:assert/strict";
import { test } from "node:test";
import { normalizeContribution } from "../src/contributions.ts";

test("contributions contain bounded, sanitised display data with explicit truncation", () => {
  const value = normalizeContribution({ id: "tasks", badge: "\x1b[31m3/6 tasks\x1b[0m", sections: Array.from({ length: 5 }, () => ({
    title: "Tasks", items: Array.from({ length: 25 }, () => ({ title: "🥧".repeat(200), detail: "🥧".repeat(200), state: "running", action: () => {} })),
  })) });
  assert.equal(value.badge, "3/6 tasks");
  assert.equal(value.sections.length, 3);
  assert.equal(value.sections[0].items.length, 20);
  assert.equal(value.sections[0].items[19].title, "… 6 more items");
  assert.equal([...value.sections[0].items[0].title].length, 80);
  assert.equal([...(value.sections[0].items[0].detail ?? "")].length, 120);
  assert.ok(!JSON.stringify(value).includes("action"));
  assert.ok(Buffer.byteLength(JSON.stringify({ contributions: Array(4).fill(value) })) < 240000);
});

test("invalid API payloads and invisible labels are rejected", () => {
  for (const value of [null, {}, { id: "../bad", badge: "", sections: [] }, { id: "ok", badge: "", sections: [{ title: "x", items: [{ title: "x", state: "arbitrary" }] }] }, { id: "ok", badge: "", sections: [{ title: "\x07", items: [] }] }]) {
    assert.throws(() => normalizeContribution(value), /Overview|overview/);
  }
});
