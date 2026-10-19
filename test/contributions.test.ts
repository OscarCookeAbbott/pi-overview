import assert from "node:assert/strict";
import { test } from "node:test";
import { normalizeContribution } from "../src/contributions.ts";

test("contributions preserve all items/sections and full multiline details while sanitising display data", () => {
  const value = normalizeContribution({ id: "tasks", badge: "\x1b[31m3/6 tasks\x1b[0m", sections: Array.from({ length: 5 }, () => ({
    title: "Tasks", items: Array.from({ length: 25 }, () => ({ title: "🥧".repeat(200), detail: "Description\n" + "🥧".repeat(200), state: "running", action: () => {} })),
  })) });
  assert.equal(value.badge, "3/6 tasks");
  assert.equal(value.sections.length, 5);
  assert.equal(value.sections[0].items.length, 25);
  assert.equal([...value.sections[0].items[0].title].length, 80);
  assert.equal(value.sections[0].items[0].detail, "Description\n" + "🥧".repeat(200));
  assert.ok(!JSON.stringify(value).includes("action"));
});

test("invalid API payloads and invisible labels are rejected", () => {
  for (const value of [null, {}, { id: "../bad", badge: "", sections: [] }, { id: "ok", badge: "", sections: [{ title: "x", items: [{ title: "x", state: "arbitrary" }] }] }, { id: "ok", badge: "", sections: [{ title: "\x07", items: [] }] }]) {
    assert.throws(() => normalizeContribution(value), /Overview|overview/);
  }
});
