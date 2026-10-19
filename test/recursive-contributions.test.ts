import assert from "node:assert/strict";
import { test } from "node:test";
import { normalizeContribution } from "../src/contributions.ts";

test("recursive items retain every note and complete multiline detail without serializing actions", () => {
  const children = Array.from({ length: 50 }, (_, i) => ({ title: `Note ${i}`, detail: `Note text\n${"detail ".repeat(50)}`, onClick() {} }));
  const value = normalizeContribution({ id: "tasks", badge: "1/2 tasks", sections: [{ title: "Tasks", items: [{ title: "Parent", children }] }] });
  const notes = value.sections[0].items[0].children!;
  assert.equal(notes.length, 50);
  assert.equal(notes[49].detail, children[49].detail.trim());
  assert.ok(!JSON.stringify(value).includes("onClick"));
  children[0].detail = "Mutated caller data";
  assert.notEqual(notes[0].detail, children[0].detail);
});

test("cyclic trees and malformed children are rejected instead of dropping descendants", () => {
  const item: { title: string; children: unknown[] } = { title: "Parent", children: [] };
  item.children.push(item);
  const contribution = (value: unknown) => ({ id: "tasks", badge: "", sections: [{ title: "Tasks", items: [value] }] });
  assert.throws(() => normalizeContribution(contribution(item)), /cycles/);
  assert.throws(() => normalizeContribution(contribution({ title: "Parent", children: {} })), /array/);
});
