#!/usr/bin/env bun

import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve, sep } from "node:path";
import { parseArgs } from "node:util";
import { capture, error, readJson, runLogged, writeJson } from "./lib.ts";

const DISCOVERY_EXPRESSION =
  "pkgs: builtins.mapAttrs (name: pkg: pkg.passthru.update or null) pkgs";

interface Metadata {
  file?: string;
  files?: string[];
  verify?: string[];
}

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
  name: string;
  label: string;
  old: string;
  new: string;
  files: string[];
  log: string;
  phase: string;
  target: string | null;
}

const repo = resolve(import.meta.dir, "..");

async function discoverPackages(): Promise<Record<string, Metadata>> {
  const arch = process.arch === "x64" ? "x86_64" : process.arch === "arm64" ? "aarch64" : process.arch;
  const system = process.env.NIX_SYSTEM ?? `${arch}-linux`;
  const result = await capture([
    "nix", "eval", "--json", `.#packages.${system}`, "--apply", DISCOVERY_EXPRESSION,
  ]);
  if (result.status !== 0) {
    process.stderr.write(result.stderr);
    throw new Error("could not discover packages");
  }
  const packages = JSON.parse(result.stdout) as Record<string, Metadata | null>;
  return Object.fromEntries(
    Object.entries(packages).filter(([, metadata]) => metadata !== null && metadata !== undefined),
  ) as Record<string, Metadata>;
}

function packagePaths(metadata: Metadata): { files: Set<string>; directories: Set<string> } {
  const declared = metadata.files ?? (metadata.file ? [metadata.file] : []);
  const files = new Set(declared);
  const directories = new Set<string>();
  for (const name of files) {
    const parts = name.split("/");
    if (parts.length >= 4 && parts[0] === "modules" && parts[1] === "packages") {
      directories.add(parts.slice(0, 3).join("/"));
    }
  }
  return { files, directories };
}

function packageVersion(files: string[]): string | null {
  for (const name of files) {
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

async function changedPaths(base: string, head: string): Promise<string[]> {
  const result = await capture(["git", "diff", "--name-only", base, head]);
  if (result.status !== 0) {
    process.stderr.write(result.stderr);
    throw new Error(`could not diff ${base}..${head}`);
  }
  return result.stdout.split("\n").filter((line) => line !== "");
}

function matches(changed: string, files: Set<string>, directories: Set<string>): boolean {
  if (files.has(changed)) return true;
  return [...directories].some(
    (directory) => changed === directory || changed.startsWith(`${directory}${sep}`),
  );
}

const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    base: { type: "string", default: "origin/main" },
    head: { type: "string", default: "HEAD" },
    updates: { type: "string" },
    "failures-file": { type: "string", default: ".update-agent/failures.json" },
    "log-dir": { type: "string", default: ".ci" },
    timeout: { type: "string", default: "3600" },
    "dry-run": { type: "boolean", default: false },
  },
  allowPositionals: false,
});

const timeout = Number(values.timeout);
const logDir = resolve(repo, values["log-dir"]);
const updatesPath = values.updates ? resolve(repo, values.updates) : undefined;
const failuresPath = resolve(repo, values["failures-file"]);

async function main(): Promise<number> {
  const packages = await discoverPackages();
  const selected: Record<string, Metadata> = {};
  const entriesByName: Record<string, Entry> = {};
  let changed: string[];

  if (updatesPath) {
    if (!existsSync(updatesPath)) throw new Error(`${updatesPath} does not exist`);
    const entries = await readJson<Entry[]>(updatesPath, []);
    if (!Array.isArray(entries)) throw new Error(`${updatesPath} must contain a JSON list`);
    changed = [...new Set(entries.flatMap((entry) => entry.files ?? []).filter((f) => typeof f === "string"))].sort();
    for (const entry of entries) {
      if (typeof entry.name === "string") entriesByName[entry.name] = entry;
      if (entry.name && entry.name in packages) selected[entry.name] = packages[entry.name];
    }
  } else {
    changed = await changedPaths(values.base, values.head);
    for (const [name, metadata] of Object.entries(packages).sort(([a], [b]) => a.localeCompare(b))) {
      const { files, directories } = packagePaths(metadata);
      if (changed.some((path) => matches(path, files, directories))) selected[name] = metadata;
    }
    if (Object.keys(selected).length === 0 && changed.some((p) => p.startsWith("modules/packages/"))) {
      console.log("no package metadata matched; building every updatable package");
      Object.assign(selected, packages);
    }
  }

  const targets: string[] = [];
  for (const [name, metadata] of Object.entries(selected)) {
    for (const target of [name, ...(metadata.verify ?? [])]) {
      if (!targets.includes(target)) targets.push(target);
    }
  }

  if (values["dry-run"]) {
    console.log(`changed: ${changed.join(", ") || "(none)"}`);
    console.log(`packages: ${Object.keys(selected).sort().join(", ") || "(none)"}`);
    console.log(`targets: ${targets.join(", ") || "(none)"}`);
    await writeJson(join(logDir, "build-summary.json"), {
      changed,
      packages: Object.keys(selected).sort(),
      targets,
      results: [],
      passed: true,
      dry_run: true,
    });
    return 0;
  }

  const results: { target: string; passed: boolean; log: string }[] = [];
  const buildFailures: Failure[] = [];
  const reverted: string[] = [];
  let entryChanged = false;

  for (const [name, metadata] of Object.entries(selected)) {
    const targetsForPackage = [name, ...(metadata.verify ?? [])];
    for (const target of targetsForPackage) {
      console.log(`\n==> ${target}`);
      const log = join(logDir, "logs", `${target}.log`);
      const status = await runLogged(["nix", "build", "--no-link", `.#${target}`], {
        log,
        cwd: repo,
        timeout,
      });
      results.push({ target, passed: status === 0, log });
      const primary = target === name;
      const entry = entriesByName[name];
      if (status === 0) {
        if (primary && entry?.failed && entry.phase === "build") {
          const pinned = packageVersion(entry.files ?? []);
          if (pinned !== null && pinned !== entry.new) {
            error(
              `${entry.label ?? name}: the repair reverted the update (pinned ${pinned}, expected ${entry.new})`,
            );
            entry.phase = "revert";
            entry.target = null;
            entryChanged = true;
            reverted.push(name);
          } else {
            entry.failed = false;
            entry.phase = null;
            entry.target = null;
            entryChanged = true;
          }
        }
        continue;
      }
      if (entry) {
        entry.failed = true;
        entry.phase = primary ? "build" : "verify";
        entry.target = primary ? null : target;
        entryChanged = true;
        buildFailures.push({
          name,
          label: entry.label ?? name,
          old: entry.old ?? "",
          new: entry.new ?? "",
          files: entry.files ?? [],
          log,
          phase: primary ? "build" : "verify",
          target: primary ? null : target,
        });
      }
      if (primary) break;
    }
  }

  if (updatesPath && entryChanged) {
    if (buildFailures.length > 0) {
      const existing = await readJson<Failure[]>(failuresPath, []);
      if (!Array.isArray(existing)) throw new Error(`${failuresPath} must contain a JSON list`);
      const seen = new Set(existing.map((entry) => `${entry.name}|${entry.phase}|${entry.target}`));
      for (const failure of buildFailures) {
        const key = `${failure.name}|${failure.phase}|${failure.target}`;
        if (seen.has(key)) continue;
        existing.push(failure);
        seen.add(key);
      }
      await writeJson(failuresPath, existing);
    }
    await writeJson(updatesPath, (await readJson<Entry[]>(updatesPath, [])));
  }

  const passed = results.every((result) => result.passed) && reverted.length === 0;
  await writeJson(join(logDir, "build-summary.json"), {
    changed,
    packages: Object.keys(selected).sort(),
    results,
    reverted,
    passed,
  });

  const lines = [
    "## Package build",
    "",
    `Changed files: ${changed.length}`,
    "",
    "| Target | Result |",
    "| --- | --- |",
    ...results.map((result) => `| \`${result.target}\` | ${result.passed ? "passed" : "failed"} |`),
  ];
  if (results.length === 0) lines.push("", "No updatable package changed.");
  if (reverted.length > 0) lines.push("", `**Reverted updates:** ${reverted.join(", ")}`);
  const markdown = `${lines.join("\n")}\n`;
  await Bun.write(join(logDir, "build-summary.md"), markdown);
  console.log(`\n${markdown}`);
  return passed ? 0 : 1;
}

try {
  process.exit(await main());
} catch (exc) {
  const message = exc instanceof Error ? exc.message : String(exc);
  error(message);
  process.exit(1);
}