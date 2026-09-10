// Exercise the generated compositor engine, including its real QML serializer.
// Run from anywhere: node tests/test-window-close.mjs
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { generate } from "./engine.mjs";

const engine = generate();

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
