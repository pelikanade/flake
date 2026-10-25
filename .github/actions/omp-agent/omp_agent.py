#!/usr/bin/env python3
"""Run an omp agent unattended, with its thinking streamed into the job log.

`omp -p` prints the agent's final message and drops thinking blocks unless
`--print-thoughts` is passed, and an unattended run has no other view of what
the agent did. This command builds that invocation and streams every line of
the agent's output into the job log as it arrives: the job log *is* the
transcript.

The caller hands over the prompt itself, not a file, and `--skill` installs a
skill with `omp skill install` before the agent starts. Provider configuration
stays where omp reads it: `PI_CONFIG_FILES` for extensions such as
`omp-magpie`, and the files those extensions read (`~/.omp/agent/magpie.yaml`
for Magpie's endpoint and key). No provider secret is passed on the command
line or stored in GitHub Actions.

`action.yml` in this repository is the workflow-side caller of the same
command, for a step that runs one agent.

Exit status: the agent's own status, 124 when `--timeout` killed it, 127 when
the agent never started (no omp binary, or a skill that would not install), and
2 when the command line is wrong.
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
NO_AGENT_STATUS = 127
USAGE_STATUS = 2

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


def tee(process: subprocess.Popen) -> None:
    """Echo the agent's output into this process, line by line."""
    assert process.stdout is not None
    console = getattr(sys.stdout, "buffer", None)
    for line in process.stdout:
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


def run(line: list[str], *, cwd: Path, timeout: int) -> int:
    """Run a command, streaming its output into the job log.

    The command gets its own process group, so a timeout kills its tools too. A
    straggler that still holds the output pipe is abandoned after a grace
    period rather than waited for: it must not hold the job open.
    """
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
        return NO_AGENT_STATUS
    pump = threading.Thread(target=tee, args=(process,), daemon=True)
    pump.start()
    killed = False
    try:
        status = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_group(process)
        status = TIMEOUT_STATUS
        killed = True
    pump.join(PIPE_GRACE if killed else None)
    if killed:
        print(f"\nomp-agent: killed after {timeout}s", file=sys.stderr)
    return status


def build_command(
    args: argparse.Namespace,
    *,
    omp: str,
    model: str | None,
    prompt: str,
) -> list[str]:
    """The unattended omp invocation: print mode, thinking, no session title."""
    line = [omp, "-p"]
    if args.thoughts:
        line.append("--print-thoughts")
    if model:
        line += ["--model", model]
    if args.approval_mode:
        line += ["--approval-mode", args.approval_mode]
    # A generated session title has nowhere to be shown in an unattended run.
    line.append("--no-title")
    if args.cwd:
        line += ["--cwd", args.cwd]
    if args.max_time:
        line += ["--max-time", args.max_time]
    line += args.extra_arg
    line.append(prompt)
    return line


def install_skills(
    omp: str, skills: list[str], *, cwd: Path, timeout: int
) -> int:
    """Install each skill before the agent starts; the user-global set, so the
    workspace and the diff the pipeline reviews stay untouched."""
    for spec in skills:
        print(f"omp-agent: installing skill {spec}", flush=True)
        status = run([omp, "skill", "install", "-y", "-g", spec], cwd=cwd, timeout=timeout)
        if status != 0:
            print(
                f"omp-agent: could not install skill {spec} (exit {status})",
                file=sys.stderr,
            )
            return NO_AGENT_STATUS
    return 0


def parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--prompt", required=True, help="the agent's prompt, as text")
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
        "--skill",
        action="append",
        default=[],
        metavar="SPEC",
        help="skill to install with `omp skill install` before the agent (repeatable)",
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
        help="kill the agent and its tools after this many seconds; it is the "
        "backstop for a hung omp, so keep it above --max-time (default: %(default)s)",
    )
    parser.add_argument("--approval-mode", help="pass omp an approval mode, e.g. yolo")
    parser.add_argument("--no-thoughts", dest="thoughts", action="store_false")
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
        help="print the command and the prompt, run nothing",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)

    prompt = args.prompt
    if not prompt.strip():
        print("omp-agent: the prompt is empty", file=sys.stderr)
        return USAGE_STATUS
    omp = args.omp or os.environ.get("OMP_AGENT_BIN") or shutil.which("omp")
    if not omp:
        print(
            "omp-agent: omp is not on PATH; pass --omp or set OMP_AGENT_BIN",
            file=sys.stderr,
        )
        return NO_AGENT_STATUS
    model = args.model or os.environ.get("OMP_MODEL") or None
    cwd = Path(args.cwd or ".")

    if not args.dry_run:
        status = install_skills(omp, args.skill, cwd=cwd, timeout=args.timeout)
        if status != 0:
            return status

    line = build_command(args, omp=omp, model=model, prompt=prompt)
    print(f"omp-agent: {shlex.join(line[:-1])} <prompt: {len(prompt)} chars>")
    print("omp-agent: prompt")
    print(prompt)
    print("omp-agent: end of prompt")
    if args.dry_run:
        return 0

    status = run(line, cwd=cwd, timeout=args.timeout)
    publish("exit-code", str(status))
    if status:
        print(f"omp-agent: the agent exited {status}", file=sys.stderr)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
