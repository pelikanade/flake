#!/usr/bin/env python3
"""Run an omp agent unattended, with its thinking streamed into the job log.

`omp -p` prints the agent's final message and drops thinking blocks unless
`--print-thoughts` is passed, and an unattended run has no other view of what
the agent did. This command builds that invocation, runs it, and writes every
line to the log file and to this process as it arrives: the job log shows the
thinking while the agent works, and the log file keeps the whole transcript for
the job artifact.

`action.yml` in this repository is the workflow-side caller of the same
command, for a step that runs one agent. A pipeline that needs the agent inside
a phase of its own — build a prompt from data it just collected, run the agent,
then verify the result — installs the `omp-agent` command from this
repository's flake and calls it, so both paths run the same code.

Provider configuration stays where omp reads it: `PI_CONFIG_FILES` for
extensions such as `omp-magpie`, and the files those extensions read
(`~/.omp/agent/magpie.yaml` for Magpie's endpoint and key). No provider secret
is passed on the command line or stored in GitHub Actions.

Exit status: the agent's own status, 124 when `--timeout` kills it, 127 when
the omp binary is missing, and 2 when the command line is wrong.
"""

from __future__ import annotations

import argparse
import os
import shlex
import shutil
import signal
import subprocess
import sys
import threading
from pathlib import Path

TIMEOUT_STATUS = 124
MISSING_STATUS = 127
USAGE_STATUS = 2

DEFAULT_LOG = "omp-agent.log"
DEFAULT_MAX_TIME = "45m"
DEFAULT_TIMEOUT = 3600

# How long a killed agent's leftover pipe may hold the command after the kill.
PIPE_GRACE = 5


def publish(name: str, value: str) -> None:
    """Publish a step output; outside GitHub Actions this does nothing."""
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(f"{name}={value}\n")


def tee(process: subprocess.Popen, handle) -> None:
    """Write every line of the agent's output to the log, then to this process.

    The log write comes first so a console that cannot take bytes (no
    `sys.stdout.buffer`) cannot cost the transcript.
    """
    assert process.stdout is not None
    console = getattr(sys.stdout, "buffer", None)
    for line in process.stdout:
        try:
            handle.write(line)
        except ValueError:
            return  # a timeout closed the transcript; the straggler is on its own
        if console is not None:
            console.write(line)
            console.flush()
        else:
            sys.stdout.write(line.decode(errors="replace"))
            sys.stdout.flush()


def kill_group(process: subprocess.Popen) -> None:
    """Kill the agent and the tools it started."""
    try:
        os.killpg(os.getpgid(process.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        process.kill()
    process.wait()


def run(line: list[str], log: Path, *, cwd: Path, timeout: int) -> int:
    """Run the agent, streaming its output to `log` and to this process.

    The agent gets its own process group, so a timeout kills its tools too. A
    straggler that still holds the output pipe is abandoned after a grace
    period rather than waited for: it must not hold the job open.
    """
    with log.open("wb") as handle:
        try:
            process = subprocess.Popen(
                line,
                cwd=cwd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        except FileNotFoundError:
            print(f"omp-agent: cannot run {line[0]}", file=sys.stderr)
            return MISSING_STATUS
        pump = threading.Thread(target=tee, args=(process, handle), daemon=True)
        pump.start()
        killed = False
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            kill_group(process)
            status = TIMEOUT_STATUS
            killed = True
        if killed:
            pump.join(timeout=PIPE_GRACE)
            handle.write(f"\nomp-agent: killed the agent after {timeout}s\n".encode())
        else:
            pump.join()
    return status


def build_command(
    args: argparse.Namespace,
    *,
    omp: str,
    model: str | None,
    prompt: Path,
    session_dir: Path,
) -> list[str]:
    """The unattended omp invocation: print mode, thinking, no interactive surface."""
    line = [omp, "-p"]
    if args.thoughts:
        line.append("--print-thoughts")
    if model:
        line += ["--model", model]
    if args.approval_mode:
        line += ["--approval-mode", args.approval_mode]
    for flag, enabled in (
        ("--no-skills", args.no_skills),
        ("--no-pty", args.no_pty),
        ("--no-lsp", args.no_lsp),
        ("--no-title", args.no_title),
    ):
        if enabled:
            line.append(flag)
    if args.cwd:
        line += ["--cwd", args.cwd]
    if session_dir:
        line += ["--session-dir", str(session_dir)]
    if args.max_time:
        line += ["--max-time", args.max_time]
    line += args.extra_arg
    line.append(f"@{prompt}")
    return line


def parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--prompt", required=True, help="prompt file the agent starts from")
    parser.add_argument("--log", default=DEFAULT_LOG, help="transcript of the whole run")
    parser.add_argument(
        "--omp",
        help="omp binary; defaults to $OMP_AGENT_BIN, then omp on PATH",
    )
    parser.add_argument(
        "--model",
        help="model to run; defaults to $OMP_MODEL, then omp's own default",
    )
    parser.add_argument("--cwd", help="directory the agent works in, and omp's --cwd")
    parser.add_argument(
        "--session-dir",
        help="where omp keeps the session; defaults to <log directory>/sessions",
    )
    parser.add_argument(
        "--max-time",
        default=DEFAULT_MAX_TIME,
        help="omp's own session limit (default: %(default)s)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT,
        help="kill the agent after this many seconds (default: %(default)s)",
    )
    parser.add_argument("--approval-mode", help="pass omp an approval mode, e.g. yolo")
    parser.add_argument("--no-thoughts", dest="thoughts", action="store_false")
    parser.add_argument("--no-skills", action="store_true")
    parser.add_argument("--no-pty", action="store_true")
    parser.add_argument("--no-lsp", action="store_true")
    parser.add_argument("--no-title", action="store_true")
    parser.add_argument(
        "--extra-arg",
        action="append",
        default=[],
        metavar="ARG",
        help="append a literal argument to the omp command (repeatable); "
        "use --extra-arg=ARG when ARG starts with a dash",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print the command and exit without running the agent",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)

    prompt = Path(args.prompt)
    if not prompt.is_file():
        print(f"omp-agent: no prompt file: {prompt}", file=sys.stderr)
        return USAGE_STATUS
    omp = args.omp or os.environ.get("OMP_AGENT_BIN") or shutil.which("omp")
    if not omp:
        print(
            "omp-agent: omp is not on PATH; pass --omp or set OMP_AGENT_BIN",
            file=sys.stderr,
        )
        return MISSING_STATUS
    model = args.model or os.environ.get("OMP_MODEL") or None

    log = Path(args.log)
    log.parent.mkdir(parents=True, exist_ok=True)
    session_dir = Path(args.session_dir) if args.session_dir else log.parent / "sessions"

    line = build_command(args, omp=omp, model=model, prompt=prompt, session_dir=session_dir)
    print(f"omp-agent: {shlex.join(line)}")
    publish("log", str(log))
    publish("session-dir", str(session_dir))
    if args.dry_run:
        return 0

    status = run(line, log, cwd=Path(args.cwd or "."), timeout=args.timeout)
    publish("exit-code", str(status))
    if status:
        print(f"omp-agent: the agent exited {status}; see {log}", file=sys.stderr)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
