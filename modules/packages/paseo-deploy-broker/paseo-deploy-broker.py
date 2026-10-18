"""Answer one deployment request with one switch, as root.

The Paseo daemon keeps NoNewPrivileges=true, so nothing it hosts can elevate
itself; this broker is the host's only route from that account to
`nixos-rebuild switch`. systemd starts one instance of this per connection
(`paseo-deploy@.service`, `Accept=yes`) and hands it the connection on standard
input and output, so the deployment and its output travel over the caller's
socket. The caller sends nothing and cannot choose what is deployed: the unit
passes the flake in PASEO_DEPLOY_FLAKE. See docs/paseo-deploy.md.
"""

import fcntl
import os
import subprocess
import sys

MARKER = "__paseo-deploy-exit__"
LOCK = "/run/paseo-deploy.lock"
FLAKE_VARIABLE = "PASEO_DEPLOY_FLAKE"
STDOUT = 1

# The caller reads this connection to its end, so every path out of here has to
# carry the deployment's status on it. scripts/paseo-deploy.py is the other
# half of this protocol:
#
#   * 2  the broker is not configured to deploy anything
#   * 3  another deployment is already running
#   * 4  the broker could not start a deployment
#   * anything else is nixos-rebuild's own exit status
MISCONFIGURED = 2
BUSY = 3
UNAVAILABLE = 4


def say(text: str, stream=None) -> None:
    """Write a line to the connection, tolerating a caller that went away."""
    try:
        print(text, file=sys.stdout if stream is None else stream, flush=True)
    except OSError:
        pass


def report(status: int, message: str | None = None) -> int:
    """End the stream with the deployment's status."""
    if message is not None:
        say(message, sys.stderr)
    say(f"{MARKER}={status}")
    return status


def relay(output) -> None:
    """Forward the deployment's output, dropping it if the caller is gone.

    `systemd-run --pipe` writes the transient unit's output to this process, so
    this side has to keep reading to its end even when nobody reads the socket
    any more: a closed pipe here would reach the deployment itself.
    """
    while True:
        chunk = output.read1(4096)
        if not chunk:
            return
        try:
            os.write(STDOUT, chunk)
        except OSError:
            pass


def take_lock() -> int | None:
    """Hold the deployment lock, or return the status to report instead."""
    try:
        lock = os.open(LOCK, os.O_WRONLY | os.O_CREAT, 0o600)
    except OSError as error:
        return report(UNAVAILABLE, f"cannot open {LOCK}: {error}")

    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return report(BUSY, "another deployment is already running")

    return None


def main() -> int:
    flake = os.environ.get(FLAKE_VARIABLE, "")
    if not flake:
        return report(MISCONFIGURED, f"{FLAKE_VARIABLE} is not set")

    unavailable = take_lock()
    if unavailable is not None:
        return unavailable

    # The switch runs in its own transient unit, outside this connection's
    # cgroup, so a caller that goes away cannot interrupt an activation:
    # `--pipe` streams the unit's output here and `--wait` reports its status.
    # The flake reference carries no attribute, so nixos-rebuild selects the
    # configuration matching the local hostname.
    unit = f"flake-deploy-{os.getpid()}"
    path = os.environ.get("PATH", "/run/current-system/sw/bin")
    argv = [
        "systemd-run",
        "--quiet",
        "--collect",
        "--pipe",
        "--wait",
        f"--unit={unit}",
        f"--description=Deploy {flake}",
        f"--setenv=PATH={path}",
        "nixos-rebuild",
        "switch",
        "--flake",
        flake,
        "-L",
    ]
    say(f"deploying {flake} as {unit}")
    try:
        process = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
    except OSError as error:
        return report(UNAVAILABLE, f"cannot run {argv[0]}: {error}")

    try:
        relay(process.stdout)
    finally:
        process.stdout.close()
    return report(process.wait())


if __name__ == "__main__":
    sys.exit(main())
