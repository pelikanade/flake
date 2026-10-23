#!/usr/bin/env python3
"""Build every package touched by a unified update run.

With `--updates`, the package names come from the updater's `updates.json`;
build failures are appended to `--failures-file` and the manifest is marked so
the commit phases can separate clean updates from pins needing repair. The
manifest is rewritten even when a previously failed pin now builds. Without
`--updates`, the packages are selected from a git diff, which is useful when
checking a branch by hand.

Packages that declare `passthru.update.verify` bring those dependents with
them. If a `modules/packages/` diff matches no update metadata, every
updatable package is built, so a newly added or renamed package cannot escape
the gate.
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
    parser.add_argument("--updates")
    parser.add_argument("--failures-file", default=".update-agent/failures.json")
    parser.add_argument("--log-dir", default=".ci")
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    packages = discover_packages()
    selected: dict[str, dict] = {}
    entries_by_name: dict[str, dict] = {}
    if args.updates:
        try:
            entries = json.loads(Path(args.updates).read_text())
        except FileNotFoundError:
            raise SystemExit(f"error: {args.updates} does not exist")
        except json.JSONDecodeError as exc:
            raise SystemExit(f"error: could not parse {args.updates}: {exc}")
        if not isinstance(entries, list):
            raise SystemExit(f"error: {args.updates} must contain a JSON list")
        changed = sorted(
            {
                path
                for entry in entries
                for path in entry.get("files", [])
                if isinstance(path, str)
            }
        )
        for entry in entries:
            name = entry.get("name")
            if isinstance(name, str):
                entries_by_name[name] = entry
            if name in packages:
                selected[name] = packages[name]
    else:
        changed = changed_paths(args.base, args.head)
        for name, metadata in sorted(packages.items()):
            files, directories = package_paths(metadata)
            if any(matches(path, files, directories) for path in changed):
                selected[name] = metadata
        if not selected and any(
            path.startswith("modules/packages/") for path in changed
        ):
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
    build_failures: list[dict] = []
    entry_changed = False
    for name, metadata in selected.items():
        targets_for_package = [name, *metadata.get("verify", [])]
        for target in targets_for_package:
            print(f"\n==> {target}")
            log = log_dir / "logs" / f"{target}.log"
            code = run_logged(
                ["nix", "build", "--no-link", f".#{target}"],
                log,
                timeout=args.timeout,
            )
            results.append(
                {"target": target, "passed": code == 0, "log": str(log)}
            )
            primary = target == name
            entry = entries_by_name.get(name)
            if code == 0:
                # A pin whose update command failed but now builds is a clean
                # update, not a repair. Keep the failure log for the repair
                # pass, but put the pin in the clean commit.
                if (
                    primary
                    and entry is not None
                    and entry.get("failed")
                    and entry.get("phase") == "build"
                ):
                    entry["failed"] = False
                    entry["phase"] = None
                    entry["target"] = None
                    entry_changed = True
                continue

            if entry is not None:
                entry["failed"] = True
                entry["phase"] = "build" if primary else "verify"
                entry["target"] = None if primary else target
                entry_changed = True
                build_failures.append(
                    {
                        "name": name,
                        "label": entry.get("label", name),
                        "old": entry.get("old", ""),
                        "new": entry.get("new", ""),
                        "files": entry.get("files", []),
                        "log": str(log),
                        "phase": "build" if primary else "verify",
                        "target": None if primary else target,
                    }
                )
            if primary:
                # The package did not build; its verify targets cannot add
                # information about the update.
                break

    if args.updates and entry_changed:
        if build_failures:
            failures_path = Path(args.failures_file)
            existing: list[dict] = []
            if failures_path.exists():
                try:
                    existing = json.loads(failures_path.read_text())
                except json.JSONDecodeError as exc:
                    raise SystemExit(
                        f"error: could not parse {failures_path}: {exc}"
                    )
                if not isinstance(existing, list):
                    raise SystemExit(
                        f"error: {failures_path} must contain a JSON list"
                    )
            seen = {
                (entry.get("name"), entry.get("phase"), entry.get("target"))
                for entry in existing
            }
            for failure in build_failures:
                key = (failure["name"], failure["phase"], failure["target"])
                if key not in seen:
                    existing.append(failure)
                    seen.add(key)
            failures_path.parent.mkdir(parents=True, exist_ok=True)
            failures_path.write_text(json.dumps(existing, indent=2) + "\n")
        Path(args.updates).write_text(json.dumps(entries, indent=2) + "\n")

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
