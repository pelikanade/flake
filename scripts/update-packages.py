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
keep_failed = False
log_dir = ".update-agent"
updated: list[str] = []
failed: list[str] = []
failures: list[dict] = []

DISCOVERY_EXPRESSION = (
    "pkgs: builtins.mapAttrs (name: pkg: pkg.passthru.update or null) pkgs"
)


class UpdateError(Exception):
    """An update failed. A non-empty message is reported as an error."""


def usage() -> None:
    print(
        """Usage: scripts/update-packages.py [--build] [--commit]
                                    [--keep-failed] [--log-dir=DIR] [target...]

Targets: flake, or the name of any exported package that declares
         passthru.update metadata.

Without targets every discovered package is updated. `flake` runs `nix flake
update` for every input, including nixpkgs and home-manager.

  --build         Build each discovered tool after updating it, and evaluate
                  every machine after updating flake inputs.
  --commit        Commit each successful update with a conventional message.
  --keep-failed   Leave a failed update in the working tree instead of
                  reverting it, and write its log to --log-dir. The failures
                  report is written to DIR/failures.json for the repair agent.
  --log-dir=DIR   Directory for build logs and the failures report
                  (default: .update-agent).""",
        file=sys.stderr,
    )


def error(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)


def say(message: str) -> None:
    print(f"\n==> {message}")


def log_path(name: str) -> Path:
    path = Path(log_dir) / "logs" / f"{name}.log"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def run_logged(command: list[str], path: Path, timeout: int = 3600) -> int:
    """Run a command with its output in `path`, then show the tail."""
    with path.open("wb") as handle:
        try:
            code = subprocess.run(
                command,
                stdout=handle,
                stderr=subprocess.STDOUT,
                timeout=timeout,
            ).returncode
        except subprocess.TimeoutExpired:
            handle.write(f"\nupdate-packages: timed out after {timeout}s\n".encode())
            code = 124
    print(f"log: {path}")
    lines = path.read_text(errors="replace").splitlines()
    for line in lines[-80:]:
        print(line)
    return code


def record_failure(
    name: str,
    label: str,
    old: str,
    new: str,
    files: tuple[str, ...],
    path: Path,
    phase: str,
    target: str | None = None,
) -> None:
    failures.append(
        {
            "name": name,
            "label": label,
            "old": old,
            "new": new,
            "files": list(files),
            "log": str(path),
            "phase": phase,
            "target": target,
        }
    )


def verify_targets(
    name: str,
    label: str,
    old: str,
    new: str,
    files: tuple[str, ...],
    metadata: dict,
) -> None:
    """Build packages that consume the updated package.

    A package can build while a dependent that shares its source tree does not.
    The repair agent needs that failure attached to the same update.
    """
    if not build:
        return
    for target in metadata.get("verify", []):
        say(f"{label}: verifying {target}")
        path = log_path(f"{name}-{target}")
        if run_logged(["nix", "build", "--no-link", f".#{target}"], path) != 0:
            record_failure(name, label, old, new, files, path, "verify", target)
            if not keep_failed:
                restore(*files)
            error(f"{label}: {target} failed to build")
            raise UpdateError("")
        path.unlink(missing_ok=True)


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


def update_nix_update(name: str, label: str, metadata: dict) -> None:
    path = metadata["file"]
    files = tuple(metadata.get("files", [path]))
    require_clean(*files)
    require_nix_update()
    old = current_version(path)
    say(f"{label} ({old})")
    command = ["nix-update", "--flake", "--format"]
    if build:
        command.append("--build")
    command.append(name)
    log = log_path(name)
    if run_logged(command, log) != 0:
        new = current_version(path) or old
        record_failure(name, label, old, new, files, log, "update")
        action = "kept for repair" if keep_failed else "reverting"
        error(f"{label} update or build failed; {action}")
        if not keep_failed:
            restore(*files)
        raise UpdateError("")
    log.unlink(missing_ok=True)
    if unchanged(*files):
        print("already current")
        return
    new = current_version(path)
    verify_targets(name, label, old, new, files, metadata)
    commit_changes(f"{label}: update {old} -> {new}", *files)
    if not commit:
        print(f"updated {label} to {new} (not committed)")


def update_rev_package(name: str, label: str, metadata: dict) -> None:
    """Update an upstream that pins `src.rev` to a commit.

    nix-update alone would change `version` while leaving the old revision in
    place. Resolve the release tag to a commit first, then let nix-update
    recompute the source and dependency hashes from that revision.
    """
    path = metadata["file"]
    repo = metadata["repo"]
    files = tuple(metadata.get("files", [path]))
    require_clean(*files)
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
    log = log_path(name)
    if run_logged(command, log) != 0:
        record_failure(name, label, old, new, files, log, "update")
        action = "kept for repair" if keep_failed else "reverting"
        error(f"{label} {new} failed to update or build; {action}")
        if not keep_failed:
            restore(*files)
        raise UpdateError("")
    log.unlink(missing_ok=True)
    new = current_version(path)
    verify_targets(name, label, old, new, files, metadata)
    commit_changes(f"{label}: update {old} -> {new}", *files)
    if not commit:
        print(f"updated {label} to {new} (not committed)")


def update_script(name: str, label: str, metadata: dict) -> None:
    files = tuple(metadata["files"])
    version_file = metadata["versionFile"]
    script = metadata["script"]
    require_clean(*files)
    old = current_json_version(version_file)
    say(f"{label} ({old})")
    log = log_path(f"{name}-update")
    if run_logged(["bash", script], log) != 0:
        new = current_json_version(version_file) or old
        record_failure(name, label, old, new, files, log, "update")
        action = "kept for repair" if keep_failed else "reverting"
        error(f"{label} update failed; {action}")
        if not keep_failed:
            restore(*files)
        raise UpdateError("")
    log.unlink(missing_ok=True)
    if unchanged(*files):
        print("already current")
        return
    new = current_json_version(version_file)
    if build:
        build_log = log_path(f"{name}-build")
        if run_logged(["nix", "build", "--no-link", f".#{name}"], build_log) != 0:
            record_failure(name, label, old, new, files, build_log, "build")
            action = "kept for repair" if keep_failed else "reverting"
            error(f"{label} {new} failed to build; {action}")
            if not keep_failed:
                restore(*files)
            raise UpdateError("")
        build_log.unlink(missing_ok=True)
    verify_targets(name, label, old, new, files, metadata)
    commit_changes(f"{label}: update {old} -> {new}", *files)
    if not commit:
        print(f"updated {label} to {new} (not committed)")


def update_package(name: str, metadata: dict) -> None:
    kind = metadata.get("kind")
    label = metadata.get("label", name)
    try:
        if kind == "nix-update":
            update_nix_update(name, label, metadata)
        elif kind == "rev":
            update_rev_package(name, label, metadata)
        elif kind == "script":
            update_script(name, label, metadata)
        else:
            raise UpdateError(f"{name}: unknown update kind {kind!r}")
    except KeyError as exc:
        raise UpdateError(
            f"{name}: update metadata is missing {exc.args[0]!r}"
        ) from exc


def main(argv: list[str]) -> int:
    global build, commit, keep_failed, log_dir

    requested: list[str] = []
    for arg in argv:
        if arg == "--build":
            build = True
        elif arg == "--commit":
            commit = True
        elif arg == "--keep-failed":
            keep_failed = True
        elif arg.startswith("--log-dir="):
            log_dir = arg.split("=", 1)[1]
            if not log_dir:
                error("--log-dir must name a directory")
                return 2
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

    if keep_failed:
        report = Path(log_dir) / "failures.json"
        if failures:
            report.parent.mkdir(parents=True, exist_ok=True)
            report.write_text(json.dumps(failures, indent=2) + "\n")
            print(f"\nDeferred {len(failures)} failed package update(s): {report}")
        elif report.exists():
            report.unlink()

    if updated:
        print("\nUpdated:")
        for message in updated:
            print(f"  {message}")
    if failures:
        print("\nDeferred for repair:", file=sys.stderr)
        for failure in failures:
            suffix = f" ({failure['target']})" if failure["target"] else ""
            print(f"  {failure['name']}{suffix}", file=sys.stderr)
    if not commit:
        print("\nUpdates were left uncommitted; pass --commit to create commits.")
    deferred = {failure["name"] for failure in failures}
    blocking = [name for name in failed if name not in deferred]
    if blocking:
        print("\nFailed:", file=sys.stderr)
        for name in blocking:
            print(f"  {name}", file=sys.stderr)
        if not (keep_failed and failures):
            return 1
        print(
            "\nContinuing with the deferred build failures; the non-build "
            "failures above have no repair report.",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
