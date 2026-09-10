import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";

const source = readFileSync(new URL("../Service.qml", import.meta.url), "utf8");
const start = source.indexOf("    function luaString(");
const end = source.indexOf("    // ------------------------------------------------------------------ apply", start);
assert(start >= 0 && end > start, "QML engine generator must be present");

export function generate(overrides = {}) {
  return runInNewContext(`${source.slice(start, end)}\nlua()`, {
    rules: [], sizes: [], enabled: true,
    cornerWidthPercent: 22, cornerMinWidth: 420, margin: 20,
    fallbackPlacement: "bottom-right", edgeSizePercent: 34,
    sizesPath: "/unused/hyprpin-test.json",
    cycleSession: "test", rulesRevision: 0, cycleReply: null, cycleResync: null, ...overrides,
  }, { timeout: 1000 });
}

export function parseSizes(raw) {
  const a = source.indexOf("    function parseSizes(");
  const b = source.indexOf("    // ---------------------------------------------------------------- file io", a);
  return JSON.parse(JSON.stringify(runInNewContext(`${source.slice(a, b)}\nparseSizes(raw)`, {
    raw, console: { warn() {} },
  }, { timeout: 1000 })));
}
