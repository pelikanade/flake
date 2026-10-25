#!/usr/bin/env python3
"""Review the repair changes of a unified package update with a second agent.

The workflow commits the clean update pins, then the pins that need repair,
then leaves the agent's repair changes uncommitted. This script runs in two
steps, with the agent step (`.github/actions/omp-agent`) between them:

  --mode prepare   record the working tree, write `.review/prompt.md`, and
                   publish `needs-review` and `prompt` for the agent step
  --mode verify    check what the agent wrote and publish `gate` or `ok`

The reviewer reads the working-tree repair diff, the update manifest, the
repair report, and the final build summary. It writes:

  .review/verdict.json   {"approve": bool, "summary": "...",
                          "security_findings": [...]}
  .review/review.md      the review shown in the workflow summary

`--base` is the clean-tip the build phase published, and `--agent-exit` is the
agent step's status (from the action's `exit-code` output).

The verify phase publishes `gate` (`review`) when the agent did not finish,
rejected, or changed the working tree, and `ok` when it approved. It reports
nothing when the repair changed nothing to review. It does not edit, commit,
or push.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

import update_state


def error(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)


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


def prepare(args: argparse.Namespace, repo: Path, state_dir: Path, log_dir: Path) -> int:
    """Hand the repair diff to the agent step."""
    if not update_state.repair_changes(repo).strip():
        print("no repair changes to review")
        update_state.output("needs-review", "false")
        return 0

    # The reviewer must leave the tree as it found it; verify compares this.
    (log_dir / "tree.sha").write_text(tree_digest(repo) + "\n")

    prompt = write_prompt(
        log_dir,
        base=args.base,
        updates=state_dir / "updates.json",
        repair=state_dir / "report.json",
        build_summary=(repo / args.build_summary).resolve(),
    )
    update_state.output("needs-review", "true")
    update_state.output("prompt", str(prompt))
    print(f"reviewing the repair: {prompt}")
    return 0


def verify(args: argparse.Namespace, repo: Path, log_dir: Path) -> int:
    """Check the verdict and publish this phase's outcome."""
    gate = "review"
    if args.agent_exit != "0":
        error(f"the review agent did not finish (exit {args.agent_exit or 'nothing'})")
        update_state.output("gate", gate)
        return 1

    verdict_path = log_dir / "verdict.json"
    try:
        verdict = json.loads(verdict_path.read_text())
    except FileNotFoundError:
        error(f"the review agent did not write {verdict_path}")
        update_state.output("gate", gate)
        return 1
    except json.JSONDecodeError as exc:
        error(f"could not parse {verdict_path}: {exc}")
        update_state.output("gate", gate)
        return 1
    if not isinstance(verdict.get("approve"), bool):
        error("the verdict has no boolean `approve`")
        update_state.output("gate", gate)
        return 1
    findings = verdict.get("security_findings")
    if not isinstance(findings, list) or not all(
        isinstance(finding, str) for finding in findings
    ):
        error("the verdict has no `security_findings` list of strings")
        update_state.output("gate", gate)
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
        error("the review agent changed files outside modules/packages")
        print(outside)
        update_state.output("gate", gate)
        return 1
    recorded = log_dir / "tree.sha"
    if recorded.read_text().strip() != tree_digest(repo):
        error("the review agent changed the working tree")
        update_state.output("gate", gate)
        return 1

    review = log_dir / "review.md"
    if approve and not review.is_file():
        error(f"the review agent did not write {review}")
        update_state.output("gate", gate)
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
    update_state.output("gate", gate)
    return 1


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", required=True, choices=["prepare", "verify"])
    parser.add_argument("--log-dir", default=".review")
    parser.add_argument(
        "--state-dir",
        default=".update-agent",
        help="directory holding updates.json and the updater's reports",
    )
    parser.add_argument("--build-summary", default=".ci/build-summary.json")
    parser.add_argument(
        "--base",
        help="commit the failed pins and the repair sit on (the build phase's clean-tip)",
    )
    parser.add_argument(
        "--agent-exit",
        default="",
        metavar="STATUS",
        help="the agent step's status, from the action's exit-code output",
    )
    args = parser.parse_args(argv)

    repo = Path(__file__).resolve().parent.parent
    log_dir = (repo / args.log_dir).resolve()
    state_dir = (repo / args.state_dir).resolve()
    log_dir.mkdir(parents=True, exist_ok=True)

    if args.mode == "prepare":
        if not args.base:
            error("prepare needs --base, the clean-tip the build phase published")
            update_state.output("gate", "review")
            return 1
        return prepare(args, repo, state_dir, log_dir)
    return verify(args, repo, log_dir)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
