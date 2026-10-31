#!/usr/bin/env bun
/**
 * A package registers itself with `passthru.update`:
 *
 *   { kind = "nix-update"; file = "modules/packages/<name>.nix"; }
 *   { kind = "rev"; file = "..."; repo = "owner/name"; }
 *   { kind = "script"; label = "..."; script = "..."; files = [ ... ];
 *     versionFile = "..."; }
 *
 * `nix-update` packages let nix-update bump the version and hashes. `rev`
 * packages also need the release tag resolved to a commit before nix-update
 * recomputes the hashes. `script` packages run a local updater and read the new
 * version from a JSON `version` key.
 */

import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { capture, error, failure, runLogged, say, UpdateError, writeJson } from "./lib.ts";

const DISCOVERY_EXPRESSION =
  "pkgs: builtins.mapAttrs (name: pkg: pkg.passthru.update or null) pkgs";

interface Metadata {
  kind?: string;
  label?: string;
  file?: string;
  files?: string[];
  repo?: string;
  script?: string;
  versionFile?: string;
  verify?: string[];
}

interface Entry {
  name: string;
  label: string;
  old: string;
  new: string;
  files: string[];
  failed: boolean;
  phase: string | null;
  target: string | null;
}

interface Failure extends Entry {
  log: string;
}

const state = {
  build: false,
  commit: false,
  keepFailed: false,
  logDir: ".update-agent",
  updated: [] as string[],
  failed: [] as string[],
  failures: [] as Failure[],
  updates: [] as Entry[],
};

function usage(): void {
  process.stderr.write(
    `Usage: scripts/update-packages.ts [--build] [--commit]
                                     [--keep-failed] [--log-dir=DIR] [target...]

Targets: flake, or the name of any exported package that declares
         passthru.update metadata.

Without targets every discovered package is updated. \`flake\` runs \`nix flake
update\` for every input, including nixpkgs and home-manager.

  --build         Build each discovered tool after updating it, and evaluate
                  every machine after updating flake inputs.
  --commit        Commit each successful update with a conventional message.
  --keep-failed   Leave an update in the working tree instead of committing
                  or reverting it. Writes DIR/failures.json for the repair
                  agent, DIR/updates.json for the commit phases, and
                  DIR/blocking.json for failures that have no repair report.
  --log-dir=DIR   Directory for build logs and the reports
                  (default: .update-agent).
`,
  );
}

function logPath(name: string): string {
  const path = join(state.logDir, "logs", `${name}.log`);
  mkdirSync(join(state.logDir, "logs"), { recursive: true });
  return path;
}

function recordUpdate(
  name: string,
  label: string,
  old: string,
  next: string,
  files: string[],
  failed: boolean,
  phase: string | null = null,
  target: string | null = null,
): void {
  state.updates.push({ name, label, old, new: next, files, failed, phase, target });
}

function recordFailure(
  name: string,
  label: string,
  old: string,
  next: string,
  files: string[],
  path: string,
  phase: string,
  target: string | null = null,
): void {
  state.failures.push({ name, label, old, new: next, files, log: path, failed: true, phase, target });
  recordUpdate(name, label, old, next, files, true, phase, target);
}

async function verifyTargets(
  name: string,
  label: string,
  old: string,
  next: string,
  files: string[],
  metadata: Metadata,
): Promise<void> {
  if (!state.build) return;
  for (const target of metadata.verify ?? []) {
    say(`${label}: verifying ${target}`);
    const path = logPath(`${name}-${target}`);
    if ((await runLogged(["nix", "build", "--no-link", `.#${target}`], { log: path })) !== 0) {
      recordFailure(name, label, old, next, files, path, "verify", target);
      if (!state.keepFailed) await restore(...files);
      error(`${label}: ${target} failed to build`);
      throw new UpdateError();
    }
    unlinkSync(path);
  }
}

async function runUpdate(name: string, fn: () => Promise<void>): Promise<void> {
  try {
    await fn();
  } catch (exc) {
    if (exc instanceof UpdateError) {
      if (exc.message) error(exc.message);
      else if (!state.failed.includes(name)) state.failed.push(name);
      return;
    }
    throw exc;
  }
}

async function discoverPackages(): Promise<Record<string, Metadata>> {
  const arch = process.arch === "x64" ? "x86_64" : process.arch === "arm64" ? "aarch64" : process.arch;
  const system = process.env.NIX_SYSTEM ?? `${arch}-linux`;
  const result = await capture(["nix", "eval", "--json", `.#packages.${system}`, "--apply", DISCOVERY_EXPRESSION]);
  if (result.status !== 0) {
    if (result.stderr) process.stderr.write(result.stderr);
    throw new UpdateError();
  }
  let packages: Record<string, Metadata | null>;
  try {
    packages = JSON.parse(result.stdout) as Record<string, Metadata | null>;
  } catch (exc) {
    throw new UpdateError(`could not parse package discovery output: ${exc}`);
  }
  return Object.fromEntries(Object.entries(packages).filter(([, meta]) => meta));
}

async function requireClean(...paths: string[]): Promise<void> {
  for (const path of paths) {
    const result = await capture(["git", "status", "--porcelain", "--", path]);
    if (result.status !== 0) throw new UpdateError(`could not inspect ${path}`);
    if (result.stdout.trim() !== "") {
      throw new UpdateError(`${path} has uncommitted changes; refusing to update it`);
    }
  }
}

async function restore(...paths: string[]): Promise<void> {
  const restored = await capture(["git", "restore", "--worktree", "--", ...paths]);
  if (restored.status !== 0) {
    await capture(["git", "checkout", "--", ...paths]);
  }
}

function requireNixUpdate(): void {
  for (const [tool, pkg] of [
    ["nix-update", "nixpkgs#nix-update"],
    ["nixfmt", "nixpkgs#nixfmt-rfc-style"],
  ]) {
    if (!Bun.which(tool)) {
      throw new UpdateError(`${tool} not found; run inside nix develop or nix shell ${pkg}`);
    }
  }
}

function currentVersion(path: string): string {
  const match = readFileSync(path, "utf8").match(/^[ \t]*version = "([^"]*)";/m);
  return match ? match[1] : "";
}

function currentJsonVersion(path: string): string {
  const data: unknown = JSON.parse(readFileSync(path, "utf8"));
  if (data && typeof data === "object" && "version" in data) return String(data.version);
  return "";
}

async function latestStableVersion(repo: string): Promise<string | null> {
  const result = await capture([
    "git", "ls-remote", "--tags", `https://github.com/${repo}`, "refs/tags/v*",
  ]);
  if (result.status !== 0) return null;
  const versions = new Set<string>();
  for (const line of result.stdout.split("\n")) {
    const match = line.match(/refs\/tags\/v(\d+\.\d+\.\d+)(?:\^\{\})?$/);
    if (match) versions.add(match[1]);
  }
  if (versions.size === 0) return null;
  return [...versions].sort((a, b) => {
    const left = a.split(".").map(Number);
    const right = b.split(".").map(Number);
    for (let i = 0; i < 3; i += 1) {
      if (left[i] !== right[i]) return left[i] - right[i];
    }
    return 0;
  })[versions.size - 1];
}

async function resolveTag(repo: string, tag: string): Promise<string | null> {
  const result = await capture([
    "git", "ls-remote", `https://github.com/${repo}`,
    `refs/tags/${tag}^{}`, `refs/tags/${tag}`,
  ]);
  if (result.status !== 0) return null;
  let peeled: string | null = null;
  let direct: string | null = null;
  for (const line of result.stdout.split("\n")) {
    const parts = line.split(/\s+/);
    if (parts.length < 2) continue;
    if (parts[1].endsWith("^{}")) peeled = parts[0];
    else direct = parts[0];
  }
  return peeled ?? direct;
}

async function unchanged(...paths: string[]): Promise<boolean> {
  return (await capture(["git", "diff", "--quiet", "--", ...paths])).status === 0;
}

async function commitChanges(message: string, ...paths: string[]): Promise<void> {
  if (!state.commit) return;
  const added = await capture(["git", "add", "--", ...paths]);
  if (added.status !== 0) throw new UpdateError(failure(["git", "add", "--", ...paths], added));
  if ((await capture(["git", "diff", "--cached", "--quiet"])).status === 0) return;
  if ((await capture(["git", "commit", "-m", message])).status !== 0) {
    throw new UpdateError(`could not commit: ${message}`);
  }
  state.updated.push(message);
}

async function updateFlakeInputs(): Promise<void> {
  say("flake inputs: all");
  await requireClean("flake.lock");
  const updated = await capture(["nix", "flake", "update"], { timeout: 3600 });
  if (updated.status !== 0) throw new UpdateError(failure(["nix", "flake", "update"], updated));
  if (await unchanged("flake.lock")) {
    console.log("already current");
    return;
  }
  if (state.build) {
    const expression =
      'cs: builtins.concatStringsSep "\\n" ' +
      "(map (n: cs.${n}.config.system.build.toplevel.drvPath) " +
      "(builtins.attrNames cs))";
    const evaluated = await capture(["nix", "eval", "--raw", ".#nixosConfigurations", "--apply", expression]);
    if (evaluated.status !== 0) {
      error(
        `updated flake inputs do not evaluate; reverting\n${failure(["nix", "eval", ".#nixosConfigurations"], evaluated)}`,
      );
      await restore("flake.lock");
      throw new UpdateError();
    }
  }
  await commitChanges("flake: update", "flake.lock");
  if (!state.commit) console.log("updated flake.lock (not committed)");
}

async function updateNixUpdate(name: string, label: string, metadata: Metadata): Promise<void> {
  const path = metadata.file;
  if (!path) throw new UpdateError(`${name}: update metadata is missing 'file'`);
  const files = metadata.files ?? [path];
  await requireClean(...files);
  requireNixUpdate();
  const old = currentVersion(path);
  say(`${label} (${old})`);
  const command = ["nix-update", "--flake", "--format"];
  if (state.build) command.push("--build");
  command.push(name);
  const log = logPath(name);
  if ((await runLogged(command, { log })) !== 0) {
    const next = currentVersion(path) || old;
    const phase = next !== old ? "build" : "update";
    recordFailure(name, label, old, next, files, log, phase);
    error(`${label} update or build failed; ${state.keepFailed ? "kept for repair" : "reverting"}`);
    if (!state.keepFailed) await restore(...files);
    throw new UpdateError();
  }
  if (existsSync(log)) unlinkSync(log);
  if (await unchanged(...files)) {
    console.log("already current");
    return;
  }
  const next = currentVersion(path);
  await verifyTargets(name, label, old, next, files, metadata);
  recordUpdate(name, label, old, next, files, false);
  await commitChanges(`${label}: update ${old} -> ${next}`, ...files);
  if (!state.commit) console.log(`updated ${label} to ${next} (not committed)`);
}

async function updateRevPackage(name: string, label: string, metadata: Metadata): Promise<void> {
  const path = metadata.file;
  const repoName = metadata.repo;
  if (!path || !repoName) {
    throw new UpdateError(`${name}: update metadata is missing 'file' or 'repo'`);
  }
  const files = metadata.files ?? [path];
  await requireClean(...files);
  requireNixUpdate();
  const old = currentVersion(path);
  say(`${label} (${old})`);
  const next = await latestStableVersion(repoName);
  if (!next) {
    error(`could not determine the latest stable tag of ${repoName}`);
    throw new UpdateError();
  }
  if (next === old) {
    console.log("already current");
    return;
  }
  const rev = await resolveTag(repoName, `v${next}`);
  if (!rev) {
    error(`could not resolve v${next} in ${repoName}`);
    throw new UpdateError();
  }
  console.log(`updating ${old} -> ${next} (${rev})`);
  let text = readFileSync(path, "utf8");
  text = text.replace(/^([ \t]*)version = "[^"]*";/m, `$1version = "${next}";`);
  text = text.replace(/^([ \t]*)rev = "[^"]*";/m, `$1rev = "${rev}";`);
  if (!text.includes(`version = "${next}";`) || !text.includes(`rev = "${rev}";`)) {
    error(`could not pin ${label} to ${next} in ${path}; reverting`);
    await restore(path);
    throw new UpdateError();
  }
  writeFileSync(path, text);
  const command = ["nix-update", "--flake", "--version=skip", "--format"];
  if (state.build) command.push("--build");
  command.push(name);
  const log = logPath(name);
  if ((await runLogged(command, { log })) !== 0) {
    recordFailure(name, label, old, next, files, log, "build");
    error(`${label} ${next} failed to update or build; ${state.keepFailed ? "kept for repair" : "reverting"}`);
    if (!state.keepFailed) await restore(...files);
    throw new UpdateError();
  }
  if (existsSync(log)) unlinkSync(log);
  const pinned = currentVersion(path);
  await verifyTargets(name, label, old, pinned, files, metadata);
  recordUpdate(name, label, old, pinned, files, false);
  await commitChanges(`${label}: update ${old} -> ${pinned}`, ...files);
  if (!state.commit) console.log(`updated ${label} to ${pinned} (not committed)`);
}

async function updateScript(name: string, label: string, metadata: Metadata): Promise<void> {
  const files = metadata.files ?? [];
  const versionFile = metadata.versionFile;
  const script = metadata.script;
  if (!versionFile || !script) {
    throw new UpdateError(`${name}: update metadata is missing 'versionFile' or 'script'`);
  }
  await requireClean(...files);
  const old = currentJsonVersion(versionFile);
  say(`${label} (${old})`);
  const log = logPath(`${name}-update`);
  if ((await runLogged(["bash", script], { log })) !== 0) {
    const next = currentJsonVersion(versionFile) || old;
    const phase = next !== old ? "build" : "update";
    recordFailure(name, label, old, next, files, log, phase);
    error(`${label} update failed; ${state.keepFailed ? "kept for repair" : "reverting"}`);
    if (!state.keepFailed) await restore(...files);
    throw new UpdateError();
  }
  if (existsSync(log)) unlinkSync(log);
  if (await unchanged(...files)) {
    console.log("already current");
    return;
  }
  const next = currentJsonVersion(versionFile);
  if (state.build) {
    const buildLog = logPath(`${name}-build`);
    if ((await runLogged(["nix", "build", "--no-link", `.#${name}`], { log: buildLog })) !== 0) {
      recordFailure(name, label, old, next, files, buildLog, "build");
      error(`${label} ${next} failed to build; ${state.keepFailed ? "kept for repair" : "reverting"}`);
      if (!state.keepFailed) await restore(...files);
      throw new UpdateError();
    }
    if (existsSync(buildLog)) unlinkSync(buildLog);
  }
  await verifyTargets(name, label, old, next, files, metadata);
  recordUpdate(name, label, old, next, files, false);
  await commitChanges(`${label}: update ${old} -> ${next}`, ...files);
  if (!state.commit) console.log(`updated ${label} to ${next} (not committed)`);
}

async function updatePackage(name: string, metadata: Metadata): Promise<void> {
  const label = metadata.label ?? name;
  switch (metadata.kind) {
    case "nix-update":
      await updateNixUpdate(name, label, metadata);
      return;
    case "rev":
      await updateRevPackage(name, label, metadata);
      return;
    case "script":
      await updateScript(name, label, metadata);
      return;
    default:
      throw new UpdateError(`${name}: unknown update kind ${JSON.stringify(metadata.kind)}`);
  }
}

async function main(argv: string[]): Promise<number> {
  const requested: string[] = [];
  for (const arg of argv) {
    if (arg === "--build") state.build = true;
    else if (arg === "--commit") state.commit = true;
    else if (arg === "--keep-failed") state.keepFailed = true;
    else if (arg.startsWith("--log-dir=")) {
      state.logDir = arg.slice("--log-dir=".length);
      if (!state.logDir) {
        error("--log-dir must name a directory");
        return 2;
      }
    } else if (arg === "-h" || arg === "--help") {
      usage();
      return 0;
    } else if (arg.startsWith("-")) {
      error(`unknown option: ${arg}`);
      usage();
      return 2;
    } else requested.push(arg);
  }

  const root = await capture(["git", "rev-parse", "--show-toplevel"]);
  if (root.status !== 0) {
    error("not inside a git repository");
    return 1;
  }
  process.chdir(root.stdout.trim());

  let targets: Record<string, Metadata> = {};
  if (requested.length === 0 || requested.some((target) => target !== "flake")) {
    try {
      targets = await discoverPackages();
    } catch (exc) {
      if (exc instanceof UpdateError && exc.message) error(exc.message);
      return 1;
    }
  }

  if (requested.length > 0) {
    for (const target of requested) {
      if (target === "flake") continue;
      const metadata = targets[target];
      if (!metadata) {
        error(`unknown target: ${target}`);
        usage();
        return 2;
      }
      await runUpdate(target, () => updatePackage(target, metadata));
    }
  } else {
    if (Object.keys(targets).length === 0) {
      console.log("no exported packages declare passthru.update");
    }
    for (const target of Object.keys(targets).sort()) {
      await runUpdate(target, () => updatePackage(target, targets[target]));
    }
  }

  if (requested.includes("flake")) {
    await runUpdate("flake inputs", updateFlakeInputs);
  }

  if (state.keepFailed) {
    const report = join(state.logDir, "failures.json");
    if (state.failures.length > 0) {
      await writeJson(report, state.failures);
      console.log(`\nDeferred ${state.failures.length} failed package update(s): ${report}`);
    } else if (existsSync(report)) unlinkSync(report);

    const changes = join(state.logDir, "updates.json");
    if (state.updates.length > 0) {
      await writeJson(changes, state.updates);
      console.log(`Recorded ${state.updates.length} package update(s): ${changes}`);
    } else if (existsSync(changes)) unlinkSync(changes);
  }

  if (state.updated.length > 0) {
    console.log("\nUpdated:");
    for (const message of state.updated) console.log(`  ${message}`);
  }
  if (state.failures.length > 0) {
    console.error("\nDeferred for repair:");
    for (const failure of state.failures) {
      const suffix = failure.target ? ` (${failure.target})` : "";
      console.error(`  ${failure.name}${suffix}`);
    }
  }
  if (!state.commit) {
    console.log("\nUpdates were left uncommitted; pass --commit to create commits.");
  }
  const deferred = new Set(state.failures.map((failure) => failure.name));
  const blocking = state.failed.filter((name) => !deferred.has(name));
  if (state.keepFailed) {
    const blockingFile = join(state.logDir, "blocking.json");
    if (blocking.length > 0) {
      await writeJson(blockingFile, [...blocking].sort());
    } else if (existsSync(blockingFile)) unlinkSync(blockingFile);
  }
  if (blocking.length > 0) {
    console.error("\nFailed:");
    for (const name of blocking) console.error(`  ${name}`);
    if (!(state.keepFailed && state.failures.length > 0)) return 1;
    console.error(
      "\nContinuing with the deferred build failures; the non-build failures above have no repair report.",
    );
  }
  return 0;
}

try {
  process.exit(await main(Bun.argv.slice(2)));
} catch (exc) {
  error(exc instanceof Error ? exc.message : String(exc));
  process.exit(1);
}