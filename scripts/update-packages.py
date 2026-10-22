#!/usr/bin/env python3
"""Update the tools this repository packages itself and flake inputs.

Package targets are discovered from the flake's `packages` outputs: every
package that declares `passthru.update` metadata is updatable. Packages that
track a flake input need no metadata; update every input with the `flake`
target instead (`nix flake update`).

The scheduled GitHub Actions workflow runs this with --commit and does not
build. Interactively, run it from `nix develop`, add --build to build each
tool and evaluate every machine, inspect the diff, and commit selectively.

A package registers itself with `passthru.update`:

  { kind = "nix-update"; file = "modules/packages/<name>.nix"; }
  { kind = "rev"; file = "..."; repo = "owner/name"; }
  { kind = "script"; label = "..."; script = "..."; files = [ ... ];
    versionFile = "..."; }

`nix-update` packages let nix-update bump the version and hashes. `rev`
packages also need the release tag resolved to a commit before nix-update
recomputes the hashes. `script` packages run a local updater and read the new
version from a JSON `version` key.
"""

from __future__ import annotations

import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

build = False
commit = False
updated: list[str] = []
failed: list[str] = []

DISCOVERY_EXPRESSION = (
    "pkgs: builtins.mapAttrs (name: pkg: pkg.passthru.update or null) pkgs"
)


class UpdateError(Exception):
    """An update failed. A non-empty message is reported as an error."""


def usage() -> None:
    print(
        """Usage: scripts/update-packages.py [--build] [--commit] [target...]

Targets: flake, or the name of any exported package that declares
         passthru.update metadata.

Without targets every discovered package is updated. `flake` runs `nix flake
update` for every input, including nixpkgs and home-manager.

  --build   Build each discovered tool after updating it, and evaluate every
            machine after updating flake inputs.
  --commit  Commit each successful update with a conventional message.""",
        file=sys.stderr,
    )


def error(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)


def say(message: str) -> None:
    print(f"\n==> {message}")


def run_update(name: str, function, *args) -> None:
    try:
        function(*args)
    except UpdateError as exc:
        if str(exc):
            error(str(exc))
        failed.append(name)


def discover_packages() -> dict[str, dict]:
    """Return the exported packages that carry `passthru.update` metadata."""
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
        if result.stderr:
            print(result.stderr, file=sys.stderr, end="")
        raise UpdateError("")
    try:
        packages = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise UpdateError(f"could not parse package discovery output: {exc}") from exc
    return {name: metadata for name, metadata in packages.items() if metadata}


def require_clean(*paths: str) -> None:
    for path in paths:
        result = subprocess.run(
            ["git", "status", "--porcelain", "--", path],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise UpdateError(f"could not inspect {path}")
        if result.stdout.strip():
            raise UpdateError(f"{path} has uncommitted changes; refusing to update it")


def restore(*paths: str) -> None:
    result = subprocess.run(
        ["git", "restore", "--worktree", "--", *paths],
        stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        subprocess.run(["git", "checkout", "--", *paths], stderr=subprocess.DEVNULL)


def require_nix_update() -> None:
    for tool, package in (
        ("nix-update", "nixpkgs#nix-update"),
        ("nixfmt", "nixpkgs#nixfmt-rfc-style"),
    ):
        if shutil.which(tool) is None:
            raise UpdateError(
                f"{tool} not found; run inside nix develop or nix shell {package}"
            )


def current_version(path: str) -> str:
    match = re.search(
        r'^[ \t]*version = "([^"]*)";', Path(path).read_text(), re.MULTILINE
    )
    return match.group(1) if match else ""


def current_json_version(path: str) -> str:
    return str(json.loads(Path(path).read_text()).get("version", ""))


def latest_stable_version(repo: str) -> str | None:
    result = subprocess.run(
        ["git", "ls-remote", "--tags", f"https://github.com/{repo}", "refs/tags/v*"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    versions = set()
    for line in result.stdout.splitlines():
        match = re.search(r"refs/tags/v(\d+\.\d+\.\d+)(?:\^\{\})?$", line)
        if match:
            versions.add(match.group(1))
    if not versions:
        return None
    return max(
        versions, key=lambda value: tuple(int(part) for part in value.split("."))
    )


def resolve_tag(repo: str, tag: str) -> str | None:
    result = subprocess.run(
        [
            "git",
            "ls-remote",
            f"https://github.com/{repo}",
            f"refs/tags/{tag}^{{}}",
            f"refs/tags/{tag}",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    peeled = direct = None
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        sha, ref = parts[0], parts[1]
        if ref.endswith("^{}"):
            peeled = sha
        else:
            direct = sha
    return peeled or direct


def unchanged(*paths: str) -> bool:
    return subprocess.run(["git", "diff", "--quiet", "--", *paths]).returncode == 0


def commit_changes(message: str, *paths: str) -> None:
    if not commit:
        return
    if subprocess.run(["git", "add", "--", *paths]).returncode != 0:
        raise UpdateError("")
    if subprocess.run(["git", "diff", "--cached", "--quiet"]).returncode == 0:
        return
    if subprocess.run(["git", "commit", "-m", message]).returncode != 0:
        raise UpdateError(f"could not commit: {message}")
    updated.append(message)


def update_flake_inputs() -> None:
    say("flake inputs: all")
    require_clean("flake.lock")
    if subprocess.run(["nix", "flake", "update"]).returncode != 0:
        raise UpdateError("")
    if unchanged("flake.lock"):
        print("already current")
        return
    if build:
        # A lock update is cheap to commit but expensive to discover broken at
        # the next deploy. Force every machine's toplevel through evaluation
        # before committing it.
        expression = (
            'cs: builtins.concatStringsSep "\\n" '
            "(map (n: cs.${n}.config.system.build.toplevel.drvPath) "
            "(builtins.attrNames cs))"
        )
        result = subprocess.run(
            ["nix", "eval", "--raw", ".#nixosConfigurations", "--apply", expression],
            stdout=subprocess.DEVNULL,
        )
        if result.returncode != 0:
            error("updated flake inputs do not evaluate; reverting")
            restore("flake.lock")
            raise UpdateError("")
    commit_changes("flake: update", "flake.lock")
    if not commit:
        print("updated flake.lock (not committed)")


def update_nix_update(name: str, label: str, path: str) -> None:
    require_clean(path)
    require_nix_update()
    old = current_version(path)
    say(f"{label} ({old})")
    command = ["nix-update", "--flake", "--format"]
    if build:
        command.append("--build")
    command.append(name)
    if subprocess.run(command).returncode != 0:
        if build:
            error(f"{label} update or build failed; reverting")
        else:
            error(f"{label} update failed; reverting")
        restore(path)
        raise UpdateError("")
    if unchanged(path):
        print("already current")
        return
    new = current_version(path)
    commit_changes(f"{label}: update {old} -> {new}", path)
    if not commit:
        print(f"updated {label} to {new} (not committed)")


def update_rev_package(name: str, label: str, path: str, repo: str) -> None:
    """Update an upstream that pins `src.rev` to a commit.

    nix-update alone would change `version` while leaving the old revision in
    place. Resolve the release tag to a commit first, then let nix-update
    recompute the source and dependency hashes from that revision.
    """
    require_clean(path)
    require_nix_update()
    old = current_version(path)
    say(f"{label} ({old})")
    new = latest_stable_version(repo)
    if not new:
        error(f"could not determine the latest stable tag of {repo}")
        raise UpdateError("")
    if new == old:
        print("already current")
        return
    rev = resolve_tag(repo, f"v{new}")
    if not rev:
        error(f"could not resolve v{new} in {repo}")
        raise UpdateError("")
    print(f"updating {old} -> {new} ({rev})")
    text = Path(path).read_text()
    text = re.sub(
        r'(?m)^([ \t]*)version = "[^"]*";',
        lambda match: f'{match.group(1)}version = "{new}";',
        text,
        count=1,
    )
    text = re.sub(
        r'(?m)^([ \t]*)rev = "[^"]*";',
        lambda match: f'{match.group(1)}rev = "{rev}";',
        text,
        count=1,
    )
    if f'version = "{new}";' not in text or f'rev = "{rev}";' not in text:
        error(f"could not pin {label} to {new} in {path}; reverting")
        restore(path)
        raise UpdateError("")
    Path(path).write_text(text)
    command = ["nix-update", "--flake", "--version=skip", "--format"]
    if build:
        command.append("--build")
    command.append(name)
    if subprocess.run(command).returncode != 0:
        if build:
            error(f"{label} {new} failed to update or build; reverting")
        else:
            error(f"{label} {new} failed to update; reverting")
        restore(path)
        raise UpdateError("")
    commit_changes(f"{label}: update {old} -> {new}", path)
    if not commit:
        print(f"updated {label} to {new} (not committed)")


def update_script(name: str, label: str, metadata: dict) -> None:
    files = tuple(metadata["files"])
    version_file = metadata["versionFile"]
    script = metadata["script"]
    require_clean(*files)
    old = current_json_version(version_file)
    say(f"{label} ({old})")
    if subprocess.run(["bash", script]).returncode != 0:
        raise UpdateError("")
    if unchanged(*files):
        print("already current")
        return
    new = current_json_version(version_file)
    if (
        build
        and subprocess.run(["nix", "build", f".#{name}", "--no-link"]).returncode != 0
    ):
        error(f"{label} {new} failed to build; reverting")
        restore(*files)
        raise UpdateError("")
    commit_changes(f"{label}: update {old} -> {new}", *files)
    if not commit:
        print(f"updated {label} to {new} (not committed)")


def update_package(name: str, metadata: dict) -> None:
    kind = metadata.get("kind")
    label = metadata.get("label", name)
    try:
        if kind == "nix-update":
            update_nix_update(name, label, metadata["file"])
        elif kind == "rev":
            update_rev_package(name, label, metadata["file"], metadata["repo"])
        elif kind == "script":
            update_script(name, label, metadata)
        else:
            raise UpdateError(f"{name}: unknown update kind {kind!r}")
    except KeyError as exc:
        raise UpdateError(
            f"{name}: update metadata is missing {exc.args[0]!r}"
        ) from exc


def main(argv: list[str]) -> int:
    global build, commit

    requested: list[str] = []
    for arg in argv:
        if arg == "--build":
            build = True
        elif arg == "--commit":
            commit = True
        elif arg in ("-h", "--help"):
            usage()
            return 0
        elif arg.startswith("-"):
            error(f"unknown option: {arg}")
            usage()
            return 2
        else:
            requested.append(arg)

    repo_root = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
    )
    if repo_root.returncode != 0:
        error("not inside a git repository")
        return 1
    os.chdir(repo_root.stdout.strip())

    targets: dict[str, dict] = {}
    if not requested or any(target != "flake" for target in requested):
        try:
            targets = discover_packages()
        except UpdateError as exc:
            if str(exc):
                error(str(exc))
            return 1

    if requested:
        for target in requested:
            if target == "flake":
                continue
            if target not in targets:
                error(f"unknown target: {target}")
                usage()
                return 2
            run_update(target, update_package, target, targets[target])
    else:
        if not targets:
            print("no exported packages declare passthru.update")
        for target in sorted(targets):
            run_update(target, update_package, target, targets[target])

    if "flake" in requested:
        run_update("flake inputs", update_flake_inputs)

    if updated:
        print("\nUpdated:")
        for message in updated:
            print(f"  {message}")
    if not commit:
        print("\nUpdates were left uncommitted; pass --commit to create commits.")
    if failed:
        print("\nFailed:", file=sys.stderr)
        for name in failed:
            print(f"  {name}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
