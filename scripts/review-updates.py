#!/usr/bin/env python3
"""Review the repair changes of a unified package update with a second agent.

The workflow commits the clean update pins, then the pins that need repair,
then leaves the agent's repair changes uncommitted. This reviewer reads the
working-tree repair diff, the update manifest, the repair report, and the
final build summary. It writes:

  .review/verdict.json   {"approve": bool, "summary": "...",
                          "security_findings": [...]}
  .review/review.md      the review shown in the workflow summary

It does not edit, commit, or push. Any security finding forces a rejection.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import omp_agent


def write_prompt(
    log_dir: Path,
    *,
    base: str,
    updates: Path,
    repair: Path,
    build_summary: Path,
) -> Path:
    lines = [
        "# Review package update repairs",
        "",
        "You are the second reviewer of a unified package update. The workflow",
        "committed the clean update pins, committed the pins whose first build",
        "failed, and left the repair agent's changes uncommitted. The final build",
        "of every updated package has already run.",
        "",
        f"- Failed pins and repair: `git diff {base}`",
        "- Repair only: `git diff HEAD`",
        "- Untracked repair files: `git status --porcelain`",
        f"- Update manifest: `{updates}`",
        f"- Repair report: `{repair}`",
        f"- Final build summary: `{build_summary}`",
        f"- Build logs: `{build_summary.parent / 'logs'}`",
        "",
        "Read `AGENTS.md`, the repair diff, every package expression it touches,",
        "and the update manifest. Do not edit repository files; only write the",
        "two output files named below.",
        "",
        "Check all of the following:",
        "",
        "1. The final build summary says every target passed. If it does not,",
        "   reject.",
        "2. The repair preserves the Nix-specific behavior the package comments",
        "   describe. A workaround removed because upstream made it unnecessary",
        "   is fine only if the diff and comments agree.",
        "3. The version and source hashes in the update manifest are consistent",
        "   with each other and with the upstream revision named in the",
        "   expression.",
        "4. The repair touches only the failing packages and their patches. It",
        "   must not contain unrelated changes, weakened checks, or disabled",
        "   tests.",
        "",
        "5. Security. Inspect the diff, the added patch lines, and the build",
        "   logs for any of these, and record every one in `security_findings`:",
        "",
        "   - secrets, tokens, private keys, credentials, or unredacted logs;",
        "   - new network downloads, install scripts, or time-of-check races at",
        "     build or run time that the package did not already document;",
        "   - disabled or weakened sandboxing, `--no-sandbox`, setuid/setgid,",
        "     world-writable files, or privilege escalation;",
        "   - arbitrary shell execution or command injection from untrusted",
        "     input, especially in a wrapper or install phase;",
        "   - new untrusted sources or dependencies, or hashes that do not match",
        "     the pinned upstream revision;",
        "   - changes to CI workflows, repository permissions, secret handling,",
        "     or anything that could exfiltrate data;",
        "   - hidden content in a patch (invisible characters, unexpected",
        "     binary diffs, or hunks outside the package's stated purpose).",
        "",
        "   If you find any security risk, set `approve` to false even if every",
        "   build passed. A finding is a reason to stop, not a note to ignore.",
        "",
        f"Write `{log_dir / 'verdict.json'}` with exactly this shape:",
        "",
        '  {"approve": true, "summary": "one paragraph",',
        '   "security_findings": []}',
        "",
        "   `security_findings` must be a JSON list of concrete findings; it",
        "   must be empty for approval. Do not omit it.",
        "",
        f"Write `{log_dir / 'review.md'}` with the review in Markdown: what changed,",
        "what you verified, a **Security** section that says either \"no findings\"",
        "or lists each finding, and any risk the merger should know. Be specific",
        "and conservative. Approve only when you would commit it yourself.",
        "",
    ]
    path = log_dir / "prompt.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines))
    return path


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log-dir", default=".review")
    parser.add_argument(
        "--omp",
        default=os.environ.get("OMP_BIN") or shutil.which("omp"),
    )
    parser.add_argument("--model", default=os.environ.get("OMP_REVIEW_MODEL"))
    parser.add_argument("--api-key", default=None)
    parser.add_argument("--base", required=True)
    parser.add_argument("--updates", default=".update-agent/updates.json")
    parser.add_argument("--repair", default=".update-agent/report.json")
    parser.add_argument("--build-summary", default=".ci/build-summary.json")
    parser.add_argument("--max-time", default="20m")
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    repo = Path(__file__).resolve().parent.parent
    log_dir = (repo / args.log_dir).resolve()
    log_dir.mkdir(parents=True, exist_ok=True)
    updates = (repo / args.updates).resolve()
    repair = (repo / args.repair).resolve()
    build_summary = (repo / args.build_summary).resolve()

    prompt = write_prompt(
        log_dir,
        base=args.base,
        updates=updates,
        repair=repair,
        build_summary=build_summary,
    )

    try:
        model, api_key = omp_agent.configure(args.model, args.api_key)
    except omp_agent.ConfigError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if not args.omp:
        print("error: omp is not on PATH; pass --omp or set OMP_BIN", file=sys.stderr)
        return 1

    command = omp_agent.command(
        omp=args.omp,
        repo=repo,
        prompt=prompt,
        model=model,
        api_key=api_key,
        session_dir=log_dir / "omp-sessions",
        max_time=args.max_time,
    )
    print("agent command:", " ".join(omp_agent.redacted(command)))
    if args.dry_run:
        print(f"prompt: {prompt}")
        return 0

    log = log_dir / "omp.log"
    with log.open("wb") as handle:
        try:
            code = subprocess.run(
                command,
                cwd=repo,
                stdout=handle,
                stderr=subprocess.STDOUT,
                timeout=args.timeout,
            ).returncode
        except subprocess.TimeoutExpired:
            handle.write(f"\nreview-updates: timed out after {args.timeout}s\n".encode())
            code = 124

    print(f"log: {log}")
    for line in log.read_text(errors="replace").splitlines()[-80:]:
        print(line)
    if code != 0:
        print(f"error: the review agent exited {code}", file=sys.stderr)
        return 1

    verdict_path = log_dir / "verdict.json"
    try:
        verdict = json.loads(verdict_path.read_text())
    except FileNotFoundError:
        print(f"error: the review agent did not write {verdict_path}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as exc:
        print(f"error: could not parse {verdict_path}: {exc}", file=sys.stderr)
        return 1
    if not isinstance(verdict.get("approve"), bool):
        print("error: the verdict has no boolean `approve`", file=sys.stderr)
        return 1
    findings = verdict.get("security_findings")
    if not isinstance(findings, list) or not all(
        isinstance(finding, str) for finding in findings
    ):
        print(
            "error: the verdict has no `security_findings` list of strings",
            file=sys.stderr,
        )
        return 1
    approve = verdict["approve"] and not findings
    summary = verdict.get("summary", "")
    print(f"\nverdict: {'approve' if approve else 'reject'}")
    print(summary)
    if findings:
        print("\nsecurity findings:")
        for finding in findings:
            print(f"- {finding}")

    review = log_dir / "review.md"
    if approve and not review.is_file():
        print(f"error: the review agent did not write {review}", file=sys.stderr)
        return 1
    if not approve:
        if not review.is_file():
            body = summary
            if findings:
                body += "\n\nSecurity findings:\n" + "\n".join(
                    f"- {finding}" for finding in findings
                )
            review.write_text(body + "\n")
    return 0 if approve else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
