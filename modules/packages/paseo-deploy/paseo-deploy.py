"""Deploy the newest revision of this machine's flake, through its root broker.

The Paseo daemon keeps NoNewPrivileges=true, so `sudo`, `pkexec` and setuid
helpers cannot elevate a terminal it hosts. This client instead asks the host's
`paseo-deploy.socket`, whose per-connection unit runs as root, fetches the
flake and switches to it. It sends nothing, because the broker decides what
gets deployed. See docs/paseo-deploy.md.
"""

import os
import socket
import stat
import sys

MARKER = "__paseo-deploy-exit__"
SOCKET = os.environ.get("PASEO_DEPLOY_SOCKET", "/run/paseo-deploy.sock")

NO_BROKER = f"""No deploy broker at {SOCKET}.

Its privileged half is a NixOS service, and nothing the Paseo account can do
installs it: the daemon runs with NoNewPrivileges=true, which disables setuid
helpers, sudo and pkexec alike. An administrator has to deploy a configuration
that imports the paseo-deploy aspect once; see docs/paseo-deploy.md.
"""

AFTER_DISCONNECT = (
    "a deployment may still be running; follow it with: "
    'journalctl -f -u "flake-deploy-*"'
)

USAGE = """Ask this machine's deploy broker for a deployment.

    paseo-deploy

It takes no options: the broker already knows which flake to fetch and deploy,
and asking is the whole request. Set PASEO_DEPLOY_SOCKET to point a test at a
different socket. See docs/paseo-deploy.md.
"""


def has_broker() -> bool:
    """Whether something is listening where the broker belongs."""
    try:
        return stat.S_ISSOCK(os.stat(SOCKET).st_mode)
    except OSError:
        return False


def request() -> int | None:
    """Stream the deployment and return the status the broker reports."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect(SOCKET)
        connection.shutdown(socket.SHUT_WR)
        with connection.makefile(
            "r", encoding="utf-8", errors="replace"
        ) as stream:
            for line in stream:
                line = line.rstrip("\n")
                if line.startswith(f"{MARKER}="):
                    return int(line[len(MARKER) + 1:])
                print(line, flush=True)
    return None


def main(argv: list[str]) -> int:
    if argv:
        if argv in (["-h"], ["--help"]):
            print(USAGE, end="")
            return 0
        print(USAGE, end="", file=sys.stderr)
        print(
            f"paseo-deploy takes no arguments, got: {' '.join(argv)}",
            file=sys.stderr,
        )
        return 2

    if not has_broker():
        print(NO_BROKER, file=sys.stderr)
        return 1

    try:
        status = request()
    except BrokenPipeError:
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        return 1
    except KeyboardInterrupt:
        print(
            f"\nthe request was interrupted; {AFTER_DISCONNECT}",
            file=sys.stderr,
        )
        return 1
    except OSError as error:
        print(f"could not reach {SOCKET}: {error}", file=sys.stderr)
        return 1

    if status is None:
        print(
            "the broker closed the connection without reporting a status",
            file=sys.stderr,
        )
        print(AFTER_DISCONNECT, file=sys.stderr)
        return 1
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
