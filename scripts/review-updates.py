#!/usr/bin/env python3
"""Review the repair changes of a unified package update with a second agent.

The workflow commits the clean update pins, then the pins that need repair,
then leaves the agent's repair changes uncommitted. This reviewer reads the
working-tree repair diff, the update manifest, the repair report, and the
final build summary. It writes:

  .review/verdict.json   {"approve": bool, "summary": "...",
                          "security_findings": [...]}
  .review/review.md      the review shown in the workflow summary

It publishes `gate` (`review`) when the agent fails, rejects, or changes the
working tree, and `ok` when it approves. It reports nothing when the repair
changed nothing to review. It does not edit, commit, or push.

The agent's output, thinking included, is streamed to the workflow log and kept
in `.review/omp.log`.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import omp_agent
import update_state


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


def tree_digest(repo: Path) -> str:
    """Everything the reviewer could change: the tree against HEAD."""
    diff = subprocess.run(
        ["git", "diff", "HEAD", "--binary"],
        cwd=repo,
        capture_output=True,
    )
    status = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        cwd=repo,
        capture_output=True,
    )
    return hashlib.sha256(diff.stdout + status.stdout).hexdigest()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log-dir", default=".review")
    parser.add_argument(
        "--state-dir",
        default=".update-agent",
        help="directory holding updates.json and the updater's reports",
    )
    parser.add_argument("--build-summary", default=".ci/build-summary.json")
    parser.add_argument(
        "--omp",
        default=os.environ.get("OMP_BIN") or shutil.which("omp"),
    )
    parser.add_argument("--model", default=os.environ.get("OMP_REVIEW_MODEL"))
    parser.add_argument(
        "--base",
        required=True,
        help="commit the failed pins and the repair sit on (the build phase's clean-tip)",
    )
    parser.add_argument("--max-time", default="20m")
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    repo = Path(__file__).resolve().parent.parent
    log_dir = (repo / args.log_dir).resolve()
    state_dir = (repo / args.state_dir).resolve()
    build_summary = (repo / args.build_summary).resolve()

    if not update_state.repair_changes(repo).strip():
        print("no repair changes to review")
        return 0

    prompt = write_prompt(
        log_dir,
        base=args.base,
        updates=state_dir / "updates.json",
        repair=state_dir / "report.json",
        build_summary=build_summary,
    )
    model = omp_agent.resolve_model(args.model)

    if not args.omp:
        print("error: omp is not on PATH; pass --omp or set OMP_BIN", file=sys.stderr)
        update_state.output("gate", "review")
        return 1

    command = omp_agent.command(
        omp=args.omp,
        repo=repo,
        prompt=prompt,
        model=model,
        session_dir=log_dir / "omp-sessions",
        max_time=args.max_time,
    )
    print("agent command:", " ".join(command))
    if args.dry_run:
        print(f"prompt: {prompt}")
        return 0

    before = tree_digest(repo)
    log = log_dir / "omp.log"
    code = omp_agent.run_streaming(command, log, cwd=repo, timeout=args.timeout)
    print(f"log: {log}")
    if code != 0:
        print(f"::error::the review agent exited {code}")
        update_state.output("gate", "review")
        return 1

    verdict_path = log_dir / "verdict.json"
    try:
        verdict = json.loads(verdict_path.read_text())
    except FileNotFoundError:
        print(f"::error::the review agent did not write {verdict_path}")
        update_state.output("gate", "review")
        return 1
    except json.JSONDecodeError as exc:
        print(f"::error::could not parse {verdict_path}: {exc}")
        update_state.output("gate", "review")
        return 1
    if not isinstance(verdict.get("approve"), bool):
        print("::error::the verdict has no boolean `approve`")
        update_state.output("gate", "review")
        return 1
    findings = verdict.get("security_findings")
    if not isinstance(findings, list) or not all(
        isinstance(finding, str) for finding in findings
    ):
        print("::error::the verdict has no `security_findings` list of strings")
        update_state.output("gate", "review")
        return 1

    approve = verdict["approve"] and not findings
    summary = verdict.get("summary", "")
    print(f"\nverdict: {'approve' if approve else 'reject'}")
    print(summary)
    if findings:
        print("\nsecurity findings:")
        for finding in findings:
            print(f"- {finding}")

    outside = update_state.outside_changes(repo)
    if outside:
        print("::error::the review agent changed files outside modules/packages")
        print(outside)
        update_state.output("gate", "review")
        return 1
    if tree_digest(repo) != before:
        print("::error::the review agent changed the working tree")
        update_state.output("gate", "review")
        return 1

    review = log_dir / "review.md"
    if approve and not review.is_file():
        print(f"::error::the review agent did not write {review}")
        update_state.output("gate", "review")
        return 1
    if approve:
        update_state.output("ok", "true")
        return 0

    if not review.is_file():
        body = summary
        if findings:
            body += "\n\nSecurity findings:\n" + "\n".join(
                f"- {finding}" for finding in findings
            )
        review.write_text(body + "\n")
    update_state.output("gate", "review")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
