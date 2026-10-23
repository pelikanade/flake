#!/usr/bin/env python3
"""Build the packages changed by an update PR.

The repair agent's local verification is not the gate: this runs from the PR
workflow on the merge revision. A package is selected when a changed path is
one of its `passthru.update.files`, or lies under its package directory.
Packages that declare `passthru.update.verify` bring those dependents with
them.

If a `modules/packages/` change matches no update metadata, every updatable
package is built. That keeps a newly added or renamed package from escaping
the PR gate.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
from pathlib import Path

DISCOVERY_EXPRESSION = (
    "pkgs: builtins.mapAttrs (name: pkg: pkg.passthru.update or null) pkgs"
)


def run_logged(command: list[str], log: Path, timeout: int = 3600) -> int:
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("wb") as handle:
        try:
            code = subprocess.run(
                command,
                stdout=handle,
                stderr=subprocess.STDOUT,
                timeout=timeout,
            ).returncode
        except subprocess.TimeoutExpired:
            handle.write(f"\nverify-packages: timed out after {timeout}s\n".encode())
            code = 124
    print(f"log: {log}")
    for line in log.read_text(errors="replace").splitlines()[-80:]:
        print(line)
    return code


def discover_packages() -> dict[str, dict]:
    system = os.environ.get("NIX_SYSTEM") or f"{platform.machine()}-linux"
    result = subprocess.run(
        [
            "nix",
            "eval",
            "--json",
            f".#packages.{system}",
            "--apply",
            DISCOVERY_EXPRESSION,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr, end="")
        raise SystemExit("error: could not discover packages")
    packages = json.loads(result.stdout)
    return {name: metadata for name, metadata in packages.items() if metadata}


def package_paths(metadata: dict) -> tuple[set[str], set[Path]]:
    declared = metadata.get("files")
    if declared is None:
        declared = [metadata["file"]]
    files = set(declared)
    directories: set[Path] = set()
    for name in files:
        parts = Path(name).parts
        if len(parts) >= 4 and parts[:2] == ("modules", "packages"):
            directories.add(Path(*parts[:3]))
    return files, directories


def changed_paths(base: str, head: str) -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", base, head],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr, end="")
        raise SystemExit(f"error: could not diff {base}..{head}")
    return [line for line in result.stdout.splitlines() if line]


def matches(changed: str, files: set[str], directories: set[Path]) -> bool:
    if changed in files:
        return True
    return any(
        Path(changed).is_relative_to(directory) for directory in directories
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--log-dir", default=".ci")
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    packages = discover_packages()
    changed = changed_paths(args.base, args.head)
    selected: dict[str, dict] = {}
    for name, metadata in sorted(packages.items()):
        files, directories = package_paths(metadata)
        if any(matches(path, files, directories) for path in changed):
            selected[name] = metadata

    if not selected and any(path.startswith("modules/packages/") for path in changed):
        print("no package metadata matched; building every updatable package")
        selected = dict(packages)

    targets: list[str] = []
    for name, metadata in selected.items():
        for target in [name, *metadata.get("verify", [])]:
            if target not in targets:
                targets.append(target)

    log_dir = Path(args.log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)
    if args.dry_run:
        print(f"changed: {', '.join(changed) or '(none)'}")
        print(f"packages: {', '.join(sorted(selected)) or '(none)'}")
        print(f"targets: {', '.join(targets) or '(none)'}")
        summary = {
            "changed": changed,
            "packages": sorted(selected),
            "targets": targets,
            "results": [],
            "passed": True,
            "dry_run": True,
        }
        (log_dir / "build-summary.json").write_text(
            json.dumps(summary, indent=2) + "\n"
        )
        return 0

    results: list[dict] = []
    for target in targets:
        print(f"\n==> {target}")
        log = log_dir / "logs" / f"{target}.log"
        code = run_logged(
            ["nix", "build", "--no-link", f".#{target}"],
            log,
            timeout=args.timeout,
        )
        results.append({"target": target, "passed": code == 0, "log": str(log)})
        if code != 0:
            break

    summary = {
        "changed": changed,
        "packages": sorted(selected),
        "results": results,
        "passed": all(result["passed"] for result in results),
    }
    (log_dir / "build-summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    lines = [
        "## Package build",
        "",
        f"Changed files: {len(changed)}",
        "",
        "| Target | Result |",
        "| --- | --- |",
    ]
    for result in results:
        lines.append(
            f"| `{result['target']}` | {'passed' if result['passed'] else 'failed'} |"
        )
    if not results:
        lines += ["", "No updatable package changed."]
    (log_dir / "build-summary.md").write_text("\n".join(lines) + "\n")
    print("\n" + "\n".join(lines))

    if not summary["passed"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
