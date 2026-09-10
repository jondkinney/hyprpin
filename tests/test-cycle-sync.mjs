import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createContext, runInContext } from "node:vm";

// Execute the real QML methods with controlled process completion order.
const source = readFileSync(new URL("../Service.qml", import.meta.url), "utf8");
function method(text, name, spaces) {
  const prefix = " ".repeat(spaces);
  const start = text.indexOf(prefix + "function " + name + "(");
  const end = text.indexOf("\n" + prefix + "}", start);
  assert(start >= 0 && end > start, `${name} must be present`);
  return text.slice(start, end + prefix.length + 2).trim();
}
const start = source.indexOf("        id: rulesReadProc");
const reader = source.slice(start, source.indexOf("        id: sizesReadProc", start));
const rules = placement => [{ class: "^Test$", title: "", placement }];
function harness() {
  const snapshots = [];
  const context = createContext({
    enabled: true, rules: rules("tile-right"), rulesReadOnce: true, rulesRevision: 1,
    cycleReply: null, cycleReadback: null, cycleResync: null, applyReceipt: null, applyFailures: 0, parseState: JSON.parse,
    console: { warn() {} }, settle: { restart() {} },
    applySoon() {}, applyProc: { running: false },
    rulesReadProc: { readSerial: 0, running: false, rerun: false, code: -1, streamDone: false, payload: "" },
    lua() {
      snapshots.push(JSON.parse(JSON.stringify({ rules: context.rules, reply: context.cycleReply })));
      return "generated engine";
    },
  });
  context.root = context;
  runInContext(`${method(source, "finishCycleWrite", 4)}
    ${method(source, "finishApply", 4)}
    ${method(source, "apply", 4)}
    with (rulesReadProc) {
      ${method(reader, "start", 8)}
      ${method(reader, "finishRead", 8)}
      rulesReadProc.start = start;
      rulesReadProc.finishRead = finishRead;
    }`, context);
  return {
    context, snapshots,
    complete(placement, code = 0) {
      const proc = context.rulesReadProc;
      proc.running = false;
      proc.code = code;
      proc.payload = JSON.stringify({ enabled: true, rules: rules(placement) });
      proc.streamDone = true;
      proc.finishRead();
    },
  };
}

// A failed hyprctl reply is ambiguous: keep the receipt until a retry works.
for (const [exitCode, reply] of [[6, "Couldn't read (6)"], [0, ""], [7, "error: failed"]]) {
  const { context: c, complete, snapshots } = harness();
  c.finishCycleWrite(21, 0);
  complete("tile-bottom");
  c.applyProc.running = false;
  c.finishApply(exitCode, reply);
  assert.equal(c.cycleReply.token, 21);
  c.apply();
  assert.deepEqual(snapshots[0].reply, snapshots[1].reply);
  c.applyProc.running = false;
  c.finishApply(0, "ok");
  assert.equal(c.applyReceipt, null);
  assert.equal(c.applyFailures, 0);
  console.log(`ok: failed apply (${exitCode}, ${JSON.stringify(reply)}) retries the same receipt`);
}

{
  const { context: c, complete, snapshots } = harness();
  c.finishCycleWrite(30, 0);
  complete("tile-bottom");
  // Hyprland processed 30 and requested 31, but the reply for 30 was lost.
  c.cycleReply = { token: 31, success: true };
  c.applyProc.running = false;
  c.finishApply(6, "Couldn't read (6)");
  assert.equal(c.cycleReply.token, 31);
  c.apply();
  assert.equal(snapshots.at(-1).reply.token, 31);
  console.log("ok: newer queued confirmation supersedes a lost earlier reply");
}

{
  const { context: c, complete } = harness();
  c.finishCycleWrite(40, 0);
  complete("tile-bottom");
  for (let attempt = 0; attempt < 3; attempt++) {
    c.applyProc.running = false;
    c.finishApply(6, "Couldn't read (6)");
    if (attempt < 2) c.apply();
  }
  assert.equal(c.cycleReply, null);
  assert.equal(c.applyReceipt, null);
  assert.equal(c.applyFailures, 0);
  c.cycleResync = 41;
  c.apply();
  c.applyProc.running = false;
  c.finishApply(6, "Couldn't read (6)");
  assert.equal(c.cycleResync, 41);
  console.log("ok: retries are bounded and later resynchronization remains possible");
}

// A directory-watch read began before the save. Neither it nor an unrelated
// settings apply may acknowledge the request with its old placement.
{
  const { context: c, complete, snapshots } = harness();
  c.rulesReadProc.start();
  c.finishCycleWrite(7, 0);
  c.apply();
  assert.equal(snapshots.at(-1).reply, null);
  c.applyProc.running = false;
  complete("tile-right");
  assert.equal(snapshots.length, 1, "old read must not confirm the save");
  assert(c.cycleReadback && c.rulesReadProc.running, "must queue a fresh read");
  c.apply();
  assert.equal(snapshots.at(-1).reply, null, "interleaved apply must not confirm the save");
  // Fresh read completes while that other apply is still running.
  complete("tile-bottom");
  assert.equal(snapshots.length, 2);
  assert(c.cycleReply && !c.cycleReadback, "ready reply waits for the running apply");
  c.applyProc.running = false;
  c.apply();
  assert.equal(snapshots.at(-1).rules[0].placement, "tile-bottom");
  assert.deepEqual(snapshots.at(-1).reply, { token: 7, success: true });
  assert.equal(c.cycleReply, null);
  console.log("ok: pre-save reads and interleaved applies cannot acknowledge stale placement");
}

for (const [writeCode, readCode, success] of [[0, 0, true], [7, 0, false], [0, 7, false], [0, 3, false]]) {
  const { context: c, complete, snapshots } = harness();
  c.finishCycleWrite(11, writeCode);
  assert.equal(snapshots.length, 0);
  assert.equal(c.cycleReply, null);
  // The process-exit callback alone cannot finish a read before stdout drains.
  c.rulesReadProc.code = readCode;
  c.rulesReadProc.finishRead();
  assert.equal(snapshots.length, 0);
  complete(success ? "tile-bottom" : "tile-right", readCode);
  assert.deepEqual(snapshots[0].reply, { token: 11, success });
  console.log(`ok: write exit ${writeCode}, read exit ${readCode} yields success=${success}`);
}

{
  const { context: c, complete, snapshots } = harness();
  c.rulesReadProc.readSerial = 999999999;
  c.finishCycleWrite(12, 0);
  assert.equal(c.rulesReadProc.readSerial, 0);
  complete("tile-bottom");
  assert.deepEqual(snapshots[0].reply, { token: 12, success: true });
  console.log("ok: read generation rollover still confirms only a fresh read");
}
