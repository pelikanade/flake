#!/usr/bin/env python3
"""Rebuild the packages a repair touched, and fail when one still does not build.

The workflow runs the repair agent first — its prompt lives in the workflow —
and stages the repair, because Nix's git source only sees staged content. This
script then walks `.update-agent/failures.json` and, for each package, checks
that the pinned version is the updated one (a no-op repair must not pass) and
runs `nix build --no-link .#<target>` for the package and any dependent target.
It prints what it rebuilt and exits 1 when something still fails; the workflow
turns that status into the phase's gate.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


def say(message: str) -> None:
    print(f"\n==> {message}")


def error(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)


def run_logged(command: list[str], path: Path, *, cwd: Path, timeout: int) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        try:
            code = subprocess.run(
                command,
                cwd=cwd,
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
    except FileNotFoundError:
        raise SystemExit(f"error: {path} does not exist; run the updater with --keep-failed")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"error: could not parse {path}: {exc}")
    if not isinstance(data, list):
        raise SystemExit(f"error: {path} must contain a JSON list")
    return data


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


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log-dir", default=".update-agent")
    parser.add_argument("--build-timeout", type=int, default=3600)
    args = parser.parse_args(argv)

    repo = Path(__file__).resolve().parent.parent
    log_dir = (repo / args.log_dir).resolve()
    failures = load_failures(log_dir / "failures.json")

    unresolved: list[str] = []
    for failure in failures:
        actual = package_version(repo, failure)
        if actual and actual != failure["new"]:
            error(
                f"{failure['label']}: pinned version is {actual}, "
                f"expected {failure['new']}"
            )
            unresolved.append(failure["label"])
            continue
        targets = [failure["name"]]
        if failure.get("target"):
            targets.append(failure["target"])
        for target in targets:
            say(f"verifying {target}")
            if not build_target(repo, target, log_dir / "logs" / f"{target}-after.log", args.build_timeout):
                error(f"{target}: nix build failed")
                unresolved.append(failure["label"])
                break
        else:
            say(f"{failure['label']} builds again")

    if unresolved:
        error(f"still failing: {', '.join(unresolved)}")
        return 1
    print(f"\nrepaired: {len(failures)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))