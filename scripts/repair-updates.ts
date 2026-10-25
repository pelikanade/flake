#!/usr/bin/env bun
/**
 * Rebuild the packages a repair touched, and fail when one still does not build.
 *
 * The workflow runs the repair agent first — its prompt lives in the workflow —
 * and stages the repair, because Nix's git source only sees staged content.
 * This script then walks `.update-agent/failures.json` and, for each package,
 * checks that the pinned version is the updated one (a no-op repair must not
 * pass) and runs `nix build --no-link .#<target>` for the package and any
 * dependent target. It prints what it rebuilt and exits 1 when something still
 * fails; the workflow turns that status into the phase's gate.
 */

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { error, readJson, runLogged, say, UpdateError } from "./lib.ts";

interface Failure {
  name: string;
  label: string;
  old: string;
  new: string;
  files: string[];
  log: string;
  phase: string;
  target?: string | null;
}

const repo = resolve(import.meta.dir, "..");
const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    "log-dir": { type: "string", default: ".update-agent" },
    "build-timeout": { type: "string", default: "3600" },
  },
  allowPositionals: false,
});
const logDir = resolve(repo, values["log-dir"]);
const buildTimeout = Number(values["build-timeout"]);

function packageVersion(failure: Failure): string | null {
  for (const name of failure.files ?? []) {
    const path = join(repo, name);
    if (!existsSync(path)) continue;
    const text = readFileSync(path, "utf8");
    if (path.endsWith(".json")) {
      let data: unknown;
      try {
        data = JSON.parse(text);
      } catch {
        continue;
      }
      if (data && typeof data === "object" && "version" in data) {
        return String(data.version);
      }
      continue;
    }
    const match = text.match(/^[ \t]*version = "([^"]*)";/m);
    if (match) return match[1];
  }
  return null;
}

async function buildTarget(target: string): Promise<boolean> {
  const status = await runLogged(["nix", "build", "--no-link", `.#${target}`], {
    log: join(logDir, "logs", `${target}-after.log`),
    cwd: repo,
    timeout: buildTimeout,
  });
  return status === 0;
}

async function main(): Promise<number> {
  const failures = await readJson<Failure[]>(join(logDir, "failures.json"), []);
  if (!Array.isArray(failures)) {
    throw new UpdateError(`${logDir}/failures.json must contain a JSON list`);
  }

  const unresolved: string[] = [];
  for (const failure of failures) {
    const actual = packageVersion(failure);
    if (actual && actual !== failure.new) {
      error(`${failure.label}: pinned version is ${actual}, expected ${failure.new}`);
      unresolved.push(failure.label);
      continue;
    }
    const targets = [failure.name, ...(failure.target ? [failure.target] : [])];
    let built = true;
    for (const target of targets) {
      say(`verifying ${target}`);
      if (!(await buildTarget(target))) {
        error(`${target}: nix build failed`);
        unresolved.push(failure.label);
        built = false;
        break;
      }
    }
    if (built) say(`${failure.label} builds again`);
  }

  if (unresolved.length > 0) {
    error(`still failing: ${unresolved.join(", ")}`);
    return 1;
  }
  console.log(`\nrepaired: ${failures.length}`);
  return 0;
}

try {
  process.exit(await main());
} catch (exc) {
  if (exc instanceof UpdateError) {
    if (exc.message) error(exc.message);
    process.exit(1);
  }
  throw exc;
}