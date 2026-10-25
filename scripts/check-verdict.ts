#!/usr/bin/env bun
/**
 * Check the reviewer's verdict: approve with no security findings, or reject.
 *
 * The reviewer writes `.review/verdict.json`; the workflow runs this to turn
 * that file into an exit status, 0 when the review approves and 1 when it
 * rejects or the file is unusable, so the workflow can publish `ok` or the gate
 * from a plain `if`. The verdict is printed either way.
 *
 * `.review/review.md` is the reviewer's own text for the job summary. When the
 * reviewer rejects without writing it, this writes the summary and findings
 * there so the report still says why.
 */

import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { error } from "./lib.ts";

interface Verdict {
  approve?: unknown;
  summary?: unknown;
  security_findings?: unknown;
}

const repo = resolve(import.meta.dir, "..");
const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: { "log-dir": { type: "string", default: ".review" } },
  allowPositionals: false,
});
const logDir = join(repo, values["log-dir"]);
const verdictPath = join(logDir, "verdict.json");

async function main(): Promise<number> {
  const file = Bun.file(verdictPath);
  if (!(await file.exists())) {
    error(`the review agent did not write ${verdictPath}`);
    return 1;
  }
  let verdict: Verdict;
  try {
    verdict = (await file.json()) as Verdict;
  } catch (exc) {
    error(`could not parse ${verdictPath}: ${exc}`);
    return 1;
  }
  if (typeof verdict.approve !== "boolean") {
    error("the verdict has no boolean `approve`");
    return 1;
  }
  const findings = verdict.security_findings;
  if (
    !Array.isArray(findings) ||
    !findings.every((finding) => typeof finding === "string")
  ) {
    error("the verdict has no `security_findings` list of strings");
    return 1;
  }

  const approve = verdict.approve && findings.length === 0;
  const summary = typeof verdict.summary === "string" ? verdict.summary : "";
  console.log(`verdict: ${approve ? "approve" : "reject"}`);
  console.log(summary);
  if (findings.length > 0) {
    console.log("\nsecurity findings:");
    for (const finding of findings) console.log(`- ${finding}`);
  }

  const review = join(logDir, "review.md");
  if (approve) {
    if (!(await Bun.file(review).exists())) {
      error(`the review agent did not write ${review}`);
      return 1;
    }
    return 0;
  }
  if (!(await Bun.file(review).exists())) {
    let body = summary;
    if (findings.length > 0) {
      body += `\n\nSecurity findings:\n${findings.map((f) => `- ${f}`).join("\n")}`;
    }
    await Bun.write(review, `${body}\n`);
  }
  return 1;
}

process.exit(await main());