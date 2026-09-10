import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { generate, parseSizes } from "./engine.mjs";

const legacy = { class: "^Test$", title: "", w: 600, h: 1000 };
const floating = { placement: "free", x: 0.5, y: 0.1, w: 960, h: 270 };
const encoded = (entry) => JSON.stringify({ version: 1, entries: [entry] });
assert.deepEqual(parseSizes(encoded(legacy)), [legacy]);
assert.deepEqual(parseSizes(encoded({ ...legacy, floating })), [{ ...legacy, floating }]);
for (const raw of [null, 2, [], {}, "", "{", "null", "false", "42", '"string"', "[]", "{}", '{"entries":{}}', " ".repeat(32769)]) {
  assert.deepEqual(parseSizes(raw), []);
}
for (const bad of [null, [], "bad", 9, {},
  ...["x", "y", "w", "h"].flatMap(key => [null, "2", -1, 20000].map(value => ({ ...floating, [key]: value }))),
  { ...floating, placement: 'free"; error("injected")' },
  { ...floating, x: 1.01 }, { ...floating, w: 99 }, { ...floating, h: 59 },
]) {
  assert.deepEqual(parseSizes(encoded({ ...legacy, floating: bad })), [legacy]);
}
assert.deepEqual(parseSizes(encoded({ ...legacy, floating }).replace('"x":0.5', '"x":1e999')), [legacy]);
assert.equal(parseSizes(JSON.stringify({ entries: Array(100).fill(legacy) })).length, 64);
assert.equal(parseSizes(encoded({ ...legacy, class: "x".repeat(257) })).length, 0);
const valid = encoded({ ...legacy, floating });
assert.equal(parseSizes(valid.padEnd(32768)).length, 1);
assert.equal(parseSizes(valid.padEnd(32769)).length, 0);
console.log("ok: legacy state and floating geometry boundary checks");

const directory = mkdtempSync(join(tmpdir(), "hyprpin-floating-test-"));
try {
  const engine = join(directory, "engine.lua");
  const state = join(directory, "sizes.json");
  const run = (mode) => {
    const result = spawnSync("lua", [fileURLToPath(new URL("floating.lua", import.meta.url)), engine, mode], {
      encoding: "utf8", timeout: 10000,
    });
    process.stdout.write(result.stdout || "");
    process.stderr.write(result.stderr || "");
    if (result.error) throw result.error;
    assert.equal(result.status, 0, `${mode} floating tests failed`);
  };
  writeFileSync(engine, generate({ sizesPath: state }));
  run("transitions");
  const saved = parseSizes(readFileSync(state, "utf8"));
  assert(saved[0]?.floating, "engine-written geometry survives the actual QML parser");
  writeFileSync(engine, generate({ sizesPath: state, sizes: saved }));
  run("reopen");
  // Escaped, maximum-length identities still produce a file the bounded reader accepts.
  const hostile = Array.from({ length: 64 }, (_, i) => ({
    class: `${i}`.padEnd(256, '"'), title: "\\".repeat(256), w: 600, h: 1000, floating,
  }));
  writeFileSync(engine, generate({ sizesPath: state, sizes: hostile }));
  run("bounded");
  assert(statSync(state).size <= 32768);
  assert(parseSizes(readFileSync(state, "utf8")).length > 0);
  console.log("ok: persisted output stays within the 32 KiB reader contract");
} finally {
  rmSync(directory, { recursive: true, force: true });
}
