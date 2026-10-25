#!/usr/bin/env python3
"""Check the reviewer's verdict: approve with no security findings, or reject.

The reviewer writes `.review/verdict.json`; the workflow runs this to turn that
file into an exit status, 0 when the review approves and 1 when it rejects or
the file is unusable, so the workflow can publish `ok` or the gate from a plain
`if`. The verdict is printed either way.

`.review/review.md` is the reviewer's own text for the job summary. When the
reviewer rejects without writing it, this writes the summary and findings there
so the report still says why.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def error(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log-dir", default=".review")
    args = parser.parse_args(argv)

    log_dir = (Path(__file__).resolve().parent.parent / args.log_dir).resolve()
    verdict_path = log_dir / "verdict.json"
    try:
        verdict = json.loads(verdict_path.read_text())
    except FileNotFoundError:
        error(f"the review agent did not write {verdict_path}")
        return 1
    except json.JSONDecodeError as exc:
        error(f"could not parse {verdict_path}: {exc}")
        return 1
    if not isinstance(verdict.get("approve"), bool):
        error("the verdict has no boolean `approve`")
        return 1
    findings = verdict.get("security_findings")
    if not isinstance(findings, list) or not all(
        isinstance(finding, str) for finding in findings
    ):
        error("the verdict has no `security_findings` list of strings")
        return 1

    approve = verdict["approve"] and not findings
    summary = verdict.get("summary", "")
    print(f"verdict: {'approve' if approve else 'reject'}")
    print(summary)
    if findings:
        print("\nsecurity findings:")
        for finding in findings:
            print(f"- {finding}")

    review = log_dir / "review.md"
    if approve:
        if not review.is_file():
            error(f"the review agent did not write {review}")
            return 1
        return 0

    if not review.is_file():
        body = summary
        if findings:
            body += "\n\nSecurity findings:\n" + "\n".join(
                f"- {finding}" for finding in findings
            )
        review.write_text(body + "\n")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))