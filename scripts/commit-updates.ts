#!/usr/bin/env bun
/**
 * Commit the pieces of a unified package update in separate commits.
 *
 * The updater leaves every pin change in the working tree. This script commits
 * them in three phases:
 *
 *   clean   packages whose update built successfully, one commit each. It also
 *           publishes what the later phases read: `clean-tip`, the `gate` when
 *           the build phase did not complete or an update command failed, and
 *           `ok` when nothing needs repair or review.
 *   failed  pins for packages that need repair, one commit each; skipped when
 *           the triage below blocks them.
 *   repair  the agent's patch/substitution changes on top of those pins.
 *
 * `failed` is only used after the clean phase, so the workflow can reset the
 * failed pins if repair or review does not pass.
 */

import { parseArgs } from "node:util";
import { error, output, readJson } from "./lib.ts";

interface Entry {
  name?: string;
  label?: string;
  old: string;
  new: string;
  files?: string[];
  failed?: boolean;
  phase?: string | null;
  target?: string | null;
}

interface Failure {
  phase?: string;
}

async function git(...args: string[]): Promise<{ status: number; stdout: string }> {
  const child = Bun.spawn({ cmd: ["git", ...args], stdin: "ignore", stdout: "pipe", stderr: "inherit" });
  const stdout = await new Response(child.stdout).text();
  return { status: await child.exited, stdout };
}

async function commit(message: string, paths: string[], addAll = false): Promise<boolean> {
  const staged = await git("add", ...(addAll ? ["-A"] : []), "--", ...paths);
  if (staged.status !== 0) throw new Error(`could not stage ${paths.join(", ")}`);
  if ((await git("diff", "--cached", "--quiet")).status === 0) return false;
  if ((await git("commit", "-m", message)).status !== 0) {
    throw new Error(`could not commit: ${message}`);
  }
  console.log(`committed: ${message}`);
  return true;
}

async function head(): Promise<string> {
  const result = await git("rev-parse", "HEAD");
  if (result.status !== 0) throw new Error("could not read HEAD");
  return result.stdout.trim();
}

/** Why the updated pins may not be committed, or null when they may. */
async function triage(
  stateDir: string,
  buildSummary: string,
  report = true,
): Promise<string | null> {
  const manifest = `${stateDir}/updates.json`;
  const failuresPath = `${stateDir}/failures.json`;
  const messages: string[] = [];
  let gate: string | null = null;

  if (Bun.file(failuresPath).size > 0 && !(await Bun.file(manifest).exists())) {
    gate = "repair";
    messages.push("failed updates have no update manifest");
  } else if (Bun.file(manifest).size > 0 && !(await Bun.file(buildSummary).exists())) {
    gate = "build";
    messages.push("the build phase did not complete");
  } else {
    const failures = await readJson<Failure[]>(failuresPath, []);
    const updateFailures = failures.filter((f) => f.phase === "update").length;
    const blocking = await readJson<unknown[]>(`${stateDir}/blocking.json`, []);
    if (updateFailures > 0 || blocking.length > 0) {
      gate = "update";
      messages.push(
        `${updateFailures} update command(s) failed and ${blocking.length} package(s) could not be updated; dropping their pins`,
      );
    }
  }
  if (gate && report) {
    for (const message of messages) console.log(`::error::${message}`);
  }
  return gate;
}

async function commitPins(updates: Entry[], failed: boolean): Promise<void> {
  for (const entry of updates) {
    if (Boolean(entry.failed) !== failed) continue;
    const files = entry.files ?? [];
    if (files.length === 0) continue;
    await commit(`${entry.label}: update ${entry.old} -> ${entry.new}`, files);
  }
}

async function phaseClean(stateDir: string, buildSummary: string): Promise<void> {
  const gate = await triage(stateDir, buildSummary);
  if (gate === null && (await Bun.file(`${stateDir}/updates.json`).exists())) {
    await commitPins(await readJson<Entry[]>(`${stateDir}/updates.json`, []), false);
  }
  if (gate) {
    output("gate", gate);
  } else if (!(await Bun.file(`${stateDir}/failures.json`).exists())) {
    output("ok", "true");
  }
  output("clean-tip", await head());
}

async function phaseFailed(stateDir: string, buildSummary: string): Promise<void> {
  const gate = await triage(stateDir, buildSummary, false);
  if (gate) {
    console.log(`not committing pins that need repair (${gate})`);
    return;
  }
  if (!(await Bun.file(`${stateDir}/failures.json`).exists())) {
    console.log("no pin needs repair");
    return;
  }
  await commitPins(await readJson<Entry[]>(`${stateDir}/updates.json`, []), true);
}

async function phaseRepair(stateDir: string): Promise<void> {
  const changes = await git("status", "--porcelain", "--", "modules/packages");
  if (changes.status !== 0) throw new Error("could not inspect modules/packages");
  if (changes.stdout.trim() === "") {
    console.log("no repair changes");
    return;
  }
  const updates = await readJson<Entry[]>(`${stateDir}/updates.json`, []);
  const labels = [
    ...new Set(updates.filter((e) => e.failed).map((e) => e.label ?? e.name ?? "packages")),
  ].sort();
  const suffix = labels.length > 0 ? ` (${labels.join(", ")})` : "";
  await commit(`packages: adapt updates${suffix}`, ["modules/packages"], true);
}

const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    "state-dir": { type: "string", default: ".update-agent" },
    "build-summary": { type: "string", default: ".ci/build-summary.json" },
    phase: { type: "string" },
  },
  allowPositionals: false,
});

if (!values.phase || !["clean", "failed", "repair"].includes(values.phase)) {
  error("--phase must be clean, failed, or repair");
  process.exit(2);
}

try {
  const stateDir = values["state-dir"];
  if (values.phase === "clean") {
    await phaseClean(stateDir, values["build-summary"]);
  } else if (values.phase === "failed") {
    await phaseFailed(stateDir, values["build-summary"]);
  } else {
    await phaseRepair(stateDir);
  }
} catch (exc) {
  error(exc instanceof Error ? exc.message : String(exc));
  process.exit(1);
}