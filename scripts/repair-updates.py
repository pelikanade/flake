#!/usr/bin/env python3
"""Adapt package updates that failed to build with an omp agent.

`update-packages.py --build --keep-failed` writes `.update-agent/failures.json`
and leaves each failed pin in the working tree. The workflow commits those
pins, then runs this script. It gives the failures to an omp agent, verifies
every repaired package with `nix build`, builds every updated package again as
the build gate the reviewer reads, and writes `.update-agent/report.json` plus
a report body. The repair changes stay uncommitted; the workflow commits them
only after an independent review.

The script publishes its outcome as step outputs: `gate` (`repair` when the
agent did not leave every package building, `outside` when it changed files
outside `modules/packages`, `build` when the final build fails) or `ok` when
the repair changed nothing and left nothing to review. It reports nothing when
no package needs repair.

The agent's output, thinking included, is streamed to the workflow log and kept
in `.update-agent/logs/omp.log`. It runs through the Magpie gateway with omp's
`magpie` provider and the default model `magpie/deepseek/deepseek-flash`. The
omp-magpie extension comes from `PI_CONFIG_FILES`, and its endpoint and key
come from `$HOME/.omp/agent/magpie.yaml`, which the update runner provisions.

Use --dry-run to write the prompt and the command without calling the agent or
building anything.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import omp_agent
import update_state


def say(message: str) -> None:
    print(f"\n==> {message}")


def error(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)


def run_logged(
    command: list[str],
    path: Path,
    *,
    cwd: Path,
    env: dict[str, str] | None = None,
    timeout: int | None,
) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        try:
            code = subprocess.run(
                command,
                cwd=cwd,
                env=env,
                stdout=handle,
                stderr=subprocess.STDOUT,
                timeout=timeout,
            ).returncode
        except subprocess.TimeoutExpired:
            handle.write(f"\nrepair-updates: timed out after {timeout}s\n".encode())
            code = 124
    print(f"log: {path}")
    for line in path.read_text(errors="replace").splitlines()[-80:]:
        print(line)
    return code


def load_failures(path: Path) -> list[dict]:
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise SystemExit(f"error: {path} does not exist; run the updater with --keep-failed")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"error: could not parse {path}: {exc}")
    if not isinstance(data, list):
        raise SystemExit(f"error: {path} must contain a JSON list")
    return data


def write_prompt(log_dir: Path, failures: list[dict]) -> Path:
    lines = [
        "# Repair failed package updates",
        "",
        "The scheduled updater changed the package pins below and their builds",
        "failed. Adapt this repository's local patches and substitutions to the",
        "new upstream revisions. The version bumps are intentional; do not undo",
        "them, restore the old files, or change unrelated packages.",
        "",
        "Read `AGENTS.md` and the package expression before editing. Keep the",
        "Nix-specific behavior the patch or substitution provides. If upstream",
        "made a workaround unnecessary, remove it deliberately and say why.",
        "",
        "Do not commit, push, open a pull request, or run deployment, secret,",
        "garbage-collection, or remote-machine commands. The workflow commits",
        "the verified result. Do not introduce credentials, network downloads,",
        "disabled sandboxes, or privilege escalation; if the fix would require",
        "one, stop and explain instead.",
        "",
        "## Failing updates",
        "",
    ]
    for failure in failures:
        name = failure["name"]
        label = failure["label"]
        lines += [
            f"### {label} (`{name}`), {failure['old']} -> {failure['new']}",
            "",
            f"- Files changed by the updater: {', '.join(failure['files'])}",
            f"- Failure phase: {failure['phase']}",
            f"- Build log: `{failure['log']}`",
        ]
        if failure.get("target"):
            lines += [
                f"- The package itself built; dependent `{failure['target']}` failed.",
                f"- Verify with: `nix build --no-link .#{failure['target']}`",
            ]
        else:
            lines += [f"- Verify with: `nix build --no-link .#{name}`"]
        lines.append("")

    lines += [
        "## What to do",
        "",
        "1. Read the failing package expression and every patch or substitution",
        "   it applies.",
        "2. Reproduce the failure with the verify command above and read the log.",
        "3. Edit only files that belong to the failing packages. New files must",
        "   stay beside their package; run `git add` on a new file so Nix sees",
        "   it during the build.",
        "4. Re-run every verify command until it succeeds. A successful build is",
        "   the only completion criterion.",
        "5. Finish with a short summary: what changed, why, and the exact",
        "   commands you ran.",
        "",
        "If the repair needs an upstream change outside this repository, say so",
        "clearly instead of weakening the package.",
        "",
    ]
    path = log_dir / "prompt.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines))
    return path


def build_target(repo: Path, target: str, log: Path, timeout: int) -> bool:
    return run_logged(
        ["nix", "build", "--no-link", f".#{target}"],
        log,
        cwd=repo,
        timeout=timeout,
    ) == 0


def package_version(repo: Path, failure: dict) -> str | None:
    """Read the pinned version so a no-op repair cannot pass the gate."""
    for name in failure.get("files", []):
        path = repo / name
        if not path.is_file():
            continue
        if path.suffix == ".json":
            try:
                data = json.loads(path.read_text())
            except json.JSONDecodeError:
                continue
            if isinstance(data, dict) and "version" in data:
                return str(data["version"])
            continue
        match = re.search(
            r'(?m)^[ \t]*version = "([^"]*)";',
            path.read_text(errors="replace"),
        )
        if match:
            return match.group(1)
    return None


def report_body(report: dict, prompt: Path) -> str:
    lines = [
        "## Automated package update repair",
        "",
        "The scheduled updater could not build these package updates, so an omp",
        "agent adapted the repository's local patches and substitutions.",
        "",
        "| Package | Update | Result |",
        "| --- | --- | --- |",
    ]
    for entry in report["repaired"]:
        lines.append(
            f"| `{entry['label']}` | {entry['old']} -> {entry['new']} | "
            "`nix build` passed |"
        )
    for entry in report["unresolved"]:
        lines.append(
            f"| `{entry['label']}` | {entry['old']} -> {entry['new']} | "
            "still failing |"
        )
    lines += [
        "",
        f"The agent prompt is `.update-agent/prompt.md` (source `{prompt}`).",
    ]
    if not report["agent"]["ran"]:
        lines += [
            "",
            f"The agent did not run: {report['agent']['reason']}",
        ]
    if report["unresolved"]:
        lines += [
            "",
            "At least one package still fails, so its pin is not committed.",
            "Read the `update-agent` workflow artifact for the full build logs",
            "before continuing.",
        ]
    lines += [
        "",
        "The workflow commits clean update pins first. These repair changes",
        "are committed separately, only after an independent omp review",
        "approves them with no security findings. The builds do not exercise",
        "the applications at runtime.",
        "",
    ]
    return "\n".join(lines)


def write_report(log_dir: Path, report: dict, prompt: Path) -> None:
    (log_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    (log_dir / "report-body.md").write_text(report_body(report, prompt))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log-dir", default=".update-agent")
    parser.add_argument("--build-log-dir", default=".ci")
    parser.add_argument(
        "--omp",
        default=os.environ.get("OMP_BIN") or shutil.which("omp"),
    )
    parser.add_argument("--model", default=os.environ.get("OMP_MODEL"))
    parser.add_argument("--max-time", default="45m")
    parser.add_argument("--build-timeout", type=int, default=3600)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    repo = Path(__file__).resolve().parent.parent
    log_dir = (repo / args.log_dir).resolve()
    build_log_dir = (repo / args.build_log_dir).resolve()
    log_dir.mkdir(parents=True, exist_ok=True)

    gate: str | None = None
    failures_path = log_dir / "failures.json"
    if not failures_path.exists():
        print("no package update needs repair")
        return 0
    failures = load_failures(failures_path)
    if not failures:
        print("no package update needs repair")
        return 0

    prompt = write_prompt(log_dir, failures)

    model = omp_agent.resolve_model(args.model)

    if not args.omp:
        reason = "omp is not on PATH; pass --omp or set OMP_BIN"
        report = {
            "agent": {"ran": False, "exit": None, "reason": reason, "model": model},
            "repaired": [],
            "unresolved": failures,
        }
        write_report(log_dir, report, prompt)
        update_state.output("gate", "repair")
        error(reason)
        return 0

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
        report = {
            "agent": {
                "ran": False,
                "exit": None,
                "reason": "dry run",
                "model": model,
                "command": command,
            },
            "repaired": [],
            "unresolved": failures,
        }
        write_report(log_dir, report, prompt)
        print(f"prompt: {prompt}")
        return 0

    say(f"repairing {len(failures)} package update(s) with {model}")
    exit_code = omp_agent.run_streaming(
        command,
        log_dir / "logs" / "omp.log",
        cwd=repo,
        timeout=args.build_timeout,
    )

    # Nix's git source includes staged content. The updater leaves tracked
    # changes dirty and the agent may have created a new patch file; stage
    # both before verifying so the build sees exactly what the PR will carry.
    staged = subprocess.run(
        ["git", "add", "--all", "--", "modules/packages"],
        cwd=repo,
        capture_output=True,
        text=True,
    )
    if staged.returncode != 0:
        error(staged.stderr.strip() or "could not stage package changes")
        update_state.output("gate", "repair")
        return 1

    repaired: list[dict] = []
    unresolved: list[dict] = []
    for failure in failures:
        actual = package_version(repo, failure)
        if actual and actual != failure["new"]:
            entry = dict(failure)
            entry["reason"] = (
                f"pinned version is {actual}, expected {failure['new']}"
            )
            unresolved.append(entry)
            continue
        targets = [failure["name"]]
        if failure.get("target"):
            targets.append(failure["target"])
        after: list[str] = []
        failed = False
        for target in targets:
            log = log_dir / "logs" / f"{target}-after.log"
            say(f"verifying {target}")
            if build_target(repo, target, log, args.build_timeout):
                after.append(target)
            else:
                failed = True
                entry = dict(failure)
                entry["afterLog"] = str(log)
                unresolved.append(entry)
                break
        if not failed:
            entry = dict(failure)
            entry["after"] = after
            repaired.append(entry)

    report = {
        "agent": {
            "ran": True,
            "exit": exit_code,
            "reason": None,
            "model": model,
            "command": command,
        },
        "repaired": repaired,
        "unresolved": unresolved,
    }
    write_report(log_dir, report, prompt)
    print(f"\nrepaired: {len(repaired)}")
    print(f"unresolved: {len(unresolved)}")

    if not report["agent"]["ran"] or unresolved:
        error("some package updates still fail; see report.json")
        gate = "repair"
    outside = update_state.outside_changes(repo)
    if outside:
        print("::error::the repair agent changed files outside modules/packages")
        print(outside)
        gate = "outside"

    if gate is None:
        say("building every updated package")
        code = run_logged(
            [
                sys.executable,
                str(repo / "scripts" / "verify-packages.py"),
                "--updates",
                str(log_dir / "updates.json"),
                "--log-dir",
                str(build_log_dir),
            ],
            build_log_dir / "final-build.log",
            cwd=repo,
            timeout=None,
        )
        if code != 0:
            print("::error::the final build of the updated packages failed")
            gate = "build"

    if gate:
        update_state.output("gate", gate)
    elif update_state.repair_changes(repo).strip():
        print("repair changes are waiting for review")
    else:
        print("the repair changed nothing to review")
        update_state.output("ok", "true")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
