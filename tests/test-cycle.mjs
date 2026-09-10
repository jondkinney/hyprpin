import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { generate } from "./engine.mjs";
import { runInNewContext } from "node:vm";

const service = readFileSync(new URL("../Service.qml", import.meta.url), "utf8");
const handlerStart = service.indexOf("    function handleCycle(");
const handlerEnd = service.indexOf("    Process {", handlerStart);
const handler = service.slice(handlerStart, handlerEnd);
const event = { session: "test", revision: 1, index: 0, token: 1, previous: "tile-right", next: "tile-bottom" };
function receive(raw, extra = {}) {
  const context = { raw, cycleSession: "test", rulesRevision: 1, cycleReply: null,
    cycleWriteProc: { running: false }, rules: [{ class: '^Test["\\]$', title: 'A "quoted" call', placement: "tile-right" }], ...extra };
  runInNewContext(`${handler}\nhandleCycle(raw)`, context, { timeout: 1000 });
  return context.cycleWriteProc;
}
assert.deepEqual(JSON.parse(receive(JSON.stringify(event)).payload), {
  class: '^Test["\\]$', title: 'A "quoted" call', previous: "tile-right", next: "tile-bottom",
});
for (const raw of [null, [], 9, "{", "null", "[]", '"text"', " ".repeat(1025),
  ...[{ session: "old" }, { revision: 0 }, { index: -1 }, { index: 0.1 }, { index: 64 },
    { token: 0 }, { token: 1000000001 }, { token: "1" }, { previous: "top-left" }, { next: "fill" }, { next: "special" },
    { next: 'tile-right";os.execute("bad")' }].map(part => JSON.stringify({ ...event, ...part })),
]) assert.equal(receive(raw).running, false, `must refuse ${raw}`);
assert.equal(receive(JSON.stringify(event), { cycleReply: { token: 1, success: true } }).running, false);
console.log("ok: compositor event schema, snapshot identity, and stdin serialization checks");

const laps = [
  ["tile-right", "tile-bottom", "tile-left", "tile-top"],
  ["top-right", "bottom-right", "bottom-left", "top-left"],
];
const directory = mkdtempSync(join(tmpdir(), "hyprpin-cycle-test-"));
try {
  const initial = join(directory, "engine.lua");
  writeFileSync(initial, generate({ sizesPath: join(directory, "sizes.json") }));
  for (const [caseIndex, start] of laps.flat().entries()) {
    const group = caseIndex < 4 ? 0 : 1;
    const lap = laps[group];
    const at = lap.indexOf(start);
    const remaining = Array.from({ length: 3 }, (_, i) => lap[(at + i + 1) % 4]);
    const rest = group === 0 ? [...laps[1], "tile-right", "tile-bottom"] : [...laps[0], "top-right", "bottom-right"];
    [...remaining, ...rest].forEach((placement, i) => {
      writeFileSync(join(directory, `${caseIndex + 1}-${i + 1}.lua`), generate({
        sizesPath: join(directory, "sizes.json"), rulesRevision: i + 1,
        rules: [{ class: "^Test$", title: "", monitor: "", placement, stay: true }],
        cycleReply: { token: i + 1, success: true },
      }));
    });
  }
  writeFileSync(join(directory, "from-scratchpad.lua"), generate({
    sizesPath: join(directory, "sizes.json"), rulesRevision: 1,
    rules: [{ class: "^Test$", title: "", monitor: "", placement: "tile-right", stay: true }],
    cycleReply: { token: 1, success: true },
  }));
  const result = spawnSync("lua", [fileURLToPath(new URL("floating.lua", import.meta.url)), initial, "cycle", directory], {
    encoding: "utf8", timeout: 10000,
  });
  process.stdout.write(result.stdout || "");
  process.stderr.write(result.stderr || "");
  if (result.error) throw result.error;
  assert.equal(result.status, 0, "cycle regression tests failed");
} finally {
  rmSync(directory, { recursive: true, force: true });
}
