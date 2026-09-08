// Exercise the generated compositor engine, including its real QML serializer.
// Run from anywhere: node tests/test-window-close.mjs
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { runInNewContext } from "node:vm";

const source = readFileSync(new URL("../Service.qml", import.meta.url), "utf8");
const start = source.indexOf("    function luaString(");
const end = source.indexOf("    // ------------------------------------------------------------------ apply", start);
assert(start >= 0 && end > start, "QML engine generator must be present");
const engine = runInNewContext(`${source.slice(start, end)}\nlua()`, {
  rules: [], sizes: [], enabled: true,
  cornerWidthPercent: 22, cornerMinWidth: 420, margin: 20,
  fallbackPlacement: "bottom-right", edgeSizePercent: 34,
  sizesPath: "/unused/hyprpin-close-test.json",
}, { timeout: 1000 });

const directory = mkdtempSync(join(tmpdir(), "hyprpin-close-test-"));
try {
  const path = join(directory, "engine.lua");
  writeFileSync(path, engine);
  const result = spawnSync("lua", [
    fileURLToPath(new URL("window-close.lua", import.meta.url)), path,
  ], { encoding: "utf8", timeout: 10000 });
  process.stdout.write(result.stdout || "");
  process.stderr.write(result.stderr || "");
  if (result.error) throw result.error;
  assert.equal(result.status, 0, "window-close regression tests failed");
} finally {
  rmSync(directory, { recursive: true, force: true });
}
