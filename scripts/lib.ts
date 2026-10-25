import { appendFileSync, closeSync, mkdirSync, openSync, readFileSync } from "node:fs";
import { dirname } from "node:path";

const TIMEOUT_STATUS = 124;

export class UpdateError extends Error {}

export function error(message: string): void {
  console.error(`error: ${message}`);
}

export function say(message: string): void {
  console.log(`\n==> ${message}`);
}

export function output(name: string, value: string): void {
  const path = process.env.GITHUB_OUTPUT;
  if (!path) return;
  appendFileSync(path, `${name}=${value}\n`);
}

export interface Result {
  status: number;
  stdout: string;
  stderr: string;
}

export async function capture(
  command: string[],
  { cwd, timeout = 0 }: { cwd?: string; timeout?: number } = {},
): Promise<Result> {
  const child = Bun.spawn({
    cmd: ["setsid", ...command],
    cwd,
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  const timer = timeout > 0 ? setTimeout(() => killGroup(child.pid), timeout) : undefined;
  const stdout = new Response(child.stdout).text();
  const stderr = new Response(child.stderr).text();
  const status = await child.exited;
  clearTimeout(timer);
  return { status, stdout: await stdout, stderr: await stderr };
}

export async function runLogged(
  command: string[],
  { log, cwd, timeout = 3600 }: { log: string; cwd?: string; timeout?: number },
): Promise<number> {
  mkdirSync(dirname(log), { recursive: true });
  const fd = openSync(log, "w");
  const child = Bun.spawn({
    cmd: ["setsid", ...command],
    cwd,
    stdin: "ignore",
    stdout: fd,
    stderr: fd,
  });
  let killed = false;
  const timer =
    timeout > 0
      ? setTimeout(() => {
          killed = true;
          killGroup(child.pid);
        }, timeout)
      : undefined;
  const status = await child.exited;
  clearTimeout(timer);
  closeSync(fd);
  if (killed) {
    appendFileSync(log, `\n${process.argv[1] ?? "script"}: timed out after ${timeout}s\n`);
  }
  console.log(`log: ${log}`);
  const lines = readFileSync(log, "utf8").split("\n");
  console.log(lines.slice(-80).join("\n"));
  return killed ? TIMEOUT_STATUS : status;
}

function killGroup(pid: number): void {
  try {
    process.kill(-pid, "SIGKILL");
  } catch {
    try {
      process.kill(pid, "SIGKILL");
    } catch {
    }
  }
}

export async function readJson<T>(path: string, fallback: T): Promise<T> {
  const file = Bun.file(path);
  if (!(await file.exists())) return fallback;
  try {
    return (await file.json()) as T;
  } catch (exc) {
    throw new UpdateError(`could not parse ${path}: ${exc}`);
  }
}

export async function writeJson(path: string, value: unknown): Promise<void> {
  mkdirSync(dirname(path), { recursive: true });
  await Bun.write(path, `${JSON.stringify(value, null, 2)}\n`);
}