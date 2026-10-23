#!/usr/bin/env python3
"""Commit the pieces of a unified package update in separate commits.

The updater leaves every pin change in the working tree. This script commits
them in three phases:

  clean   packages whose update built successfully, one commit each
  failed  pins for packages that need repair, one commit each (kept local
          until the repair and review gates pass)
  repair  the agent's patch/substitution changes on top of those pins

`failed` is only used after the clean phase, so the workflow can record the
clean tip and reset the failed pins if repair or review does not pass.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


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


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", default=".update-agent/updates.json")
    parser.add_argument("--phase", required=True, choices=["clean", "failed", "repair"])
    args = parser.parse_args(argv)

    try:
        updates = json.loads(Path(args.report).read_text())
    except FileNotFoundError:
        raise SystemExit(f"error: {args.report} does not exist")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"error: could not parse {args.report}: {exc}")
    if not isinstance(updates, list):
        raise SystemExit(f"error: {args.report} must contain a JSON list")

    if args.phase == "repair":
        changed = subprocess.run(
            ["git", "status", "--porcelain", "--", "modules/packages"],
            capture_output=True,
            text=True,
        )
        if changed.returncode != 0:
            raise SystemExit("error: could not inspect modules/packages")
        if not changed.stdout.strip():
            print("no repair changes")
            return 0
        labels = sorted(
            {
                entry.get("label") or entry.get("name") or "packages"
                for entry in updates
                if entry.get("failed")
            }
        )
        suffix = f" ({', '.join(labels)})" if labels else ""
        commit(f"packages: adapt updates{suffix}", ["modules/packages"], add_all=True)
        return 0

    wanted = args.phase == "failed"
    for entry in updates:
        if bool(entry.get("failed")) != wanted:
            continue
        files = entry.get("files") or []
        if not files:
            continue
        commit(
            f"{entry['label']}: update {entry['old']} -> {entry['new']}",
            files,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
