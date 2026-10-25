#!/usr/bin/env python3
"""Commit the pieces of a unified package update in separate commits.

The updater leaves every pin change in the working tree. This script commits
them in three phases:

  clean   packages whose update built successfully, one commit each. It also
          publishes what the later phases read: `clean-tip`, the `gate` when
          the build phase did not complete or an update command failed, and
          `ok` when nothing needs repair or review.
  failed  pins for packages that need repair, one commit each; skipped when
          the triage below blocks them.
  repair  the agent's patch/substitution changes on top of those pins.

`failed` is only used after the clean phase, so the workflow can reset the
failed pins if repair or review does not pass.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def output(name: str, value: str) -> None:
    """Publish a step output; outside GitHub Actions this does nothing."""
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(f"{name}={value}\n")


def commit(message: str, paths: list[str], *, add_all: bool = False) -> bool:
    if add_all:
        result = subprocess.run(["git", "add", "-A", "--", *paths])
    else:
        result = subprocess.run(["git", "add", "--", *paths])
    if result.returncode != 0:
        raise SystemExit(f"error: could not stage {', '.join(paths)}")
    if subprocess.run(["git", "diff", "--cached", "--quiet"]).returncode == 0:
        return False
    if subprocess.run(["git", "commit", "-m", message]).returncode != 0:
        raise SystemExit(f"error: could not commit: {message}")
    print(f"committed: {message}")
    return True


def read_json(path: Path, default: list) -> list:
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        return default
    except json.JSONDecodeError as exc:
        raise SystemExit(f"error: could not parse {path}: {exc}")
    if not isinstance(data, list):
        raise SystemExit(f"error: {path} must contain a JSON list")
    return data


def head() -> str:
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"], capture_output=True, text=True
    )
    if result.returncode != 0:
        raise SystemExit("error: could not read HEAD")
    return result.stdout.strip()


def triage(state_dir: Path, build_summary: Path, *, report: bool = True) -> str | None:
    """Why the updated pins may not be committed, or None when they may.

    Both commit phases triage; `report` keeps the annotation to the first one.
    """
    manifest = state_dir / "updates.json"
    failures_path = state_dir / "failures.json"
    messages: list[str] = []
    gate = None
    if failures_path.exists() and not manifest.exists():
        gate = "repair"
        messages.append("failed updates have no update manifest")
    elif manifest.exists() and not build_summary.exists():
        gate = "build"
        messages.append("the build phase did not complete")
    else:
        update_failures = sum(
            1
            for failure in read_json(failures_path, [])
            if failure.get("phase") == "update"
        )
        blocking = read_json(state_dir / "blocking.json", [])
        if update_failures or blocking:
            gate = "update"
            messages.append(
                f"{update_failures} update command(s) failed and "
                f"{len(blocking)} package(s) could not be updated; dropping their pins"
            )
    if gate and report:
        for message in messages:
            print(f"::error::{message}")
    return gate


def commit_pins(updates: list[dict], *, failed: bool) -> None:
    for entry in updates:
        if bool(entry.get("failed")) != failed:
            continue
        files = entry.get("files") or []
        if not files:
            continue
        commit(
            f"{entry['label']}: update {entry['old']} -> {entry['new']}",
            files,
        )


def phase_clean(state_dir: Path, build_summary: Path) -> None:
    """Commit the pins that built and publish what the later phases read."""
    manifest = state_dir / "updates.json"
    gate = triage(state_dir, build_summary)
    if gate is None and manifest.exists():
        commit_pins(read_json(manifest, []), failed=False)

    if gate:
        output("gate", gate)
    elif not (state_dir / "failures.json").exists():
        output("ok", "true")
    output("clean-tip", head())


def phase_failed(state_dir: Path, build_summary: Path) -> None:
    gate = triage(state_dir, build_summary, report=False)
    if gate:
        print(f"not committing pins that need repair ({gate})")
        return
    if not (state_dir / "failures.json").exists():
        print("no pin needs repair")
        return
    commit_pins(read_json(state_dir / "updates.json", []), failed=True)


def phase_repair(state_dir: Path) -> None:
    changes = subprocess.run(
        ["git", "status", "--porcelain", "--", "modules/packages"],
        capture_output=True,
        text=True,
    )
    if changes.returncode != 0:
        raise SystemExit("error: could not inspect modules/packages")
    if not changes.stdout.strip():
        print("no repair changes")
        return
    labels = sorted(
        {
            entry.get("label") or entry.get("name") or "packages"
            for entry in read_json(state_dir / "updates.json", [])
            if entry.get("failed")
        }
    )
    suffix = f" ({', '.join(labels)})" if labels else ""
    commit(f"packages: adapt updates{suffix}", ["modules/packages"], add_all=True)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--state-dir",
        default=".update-agent",
        help="directory holding updates.json and the updater's reports",
    )
    parser.add_argument("--build-summary", default=".ci/build-summary.json")
    parser.add_argument("--phase", required=True, choices=["clean", "failed", "repair"])
    args = parser.parse_args(argv)

    state_dir = Path(args.state_dir)
    if args.phase == "clean":
        phase_clean(state_dir, Path(args.build_summary))
    elif args.phase == "failed":
        phase_failed(state_dir, Path(args.build_summary))
    else:
        phase_repair(state_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
