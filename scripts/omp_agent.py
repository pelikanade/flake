"""Shared omp invocation for the update repair and review workflows.

Both agents run omp against the Magpie gateway on `neko-sphere` through the
omp-magpie extension. The extension is loaded through `PI_CONFIG_FILES`, and it
reads the gateway endpoint and key from `~/.omp/agent/magpie.yaml`; the update
runner provisions both, so no provider secret is passed to omp or stored in
GitHub Actions.

Print mode drops thinking blocks unless `--print-thoughts` is passed, and both
agents run unattended, so the workflow log is the only view of their work.
`command` therefore asks for the thinking and `run_streaming` writes every line
to the log file and to this process as it arrives.
"""

from __future__ import annotations

import subprocess
import sys
import threading
from pathlib import Path

DEFAULT_MODEL = "magpie/deepseek/deepseek-flash"


def resolve_model(model: str | None) -> str:
    return model or DEFAULT_MODEL


def command(
    *,
    omp: str,
    repo: Path,
    prompt: Path,
    model: str,
    session_dir: Path,
    max_time: str,
) -> list[str]:
    return [
        omp,
        "-p",
        "--print-thoughts",
        "--model",
        model,
        "--cwd",
        str(repo),
        "--approval-mode",
        "yolo",
        "--no-skills",
        "--no-pty",
        "--no-lsp",
        "--no-title",
        "--session-dir",
        str(session_dir),
        "--max-time",
        max_time,
        f"@{prompt}",
    ]


def run_streaming(command: list[str], log: Path, *, cwd: Path, timeout: int) -> int:
    """Run the agent, echoing each output line to `log` and to stdout.

    The workflow log shows the agent while it works; the log file keeps the
    whole transcript for the run artifact. A timeout kills the agent and
    returns 124.
    """
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("wb") as handle:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )

        def tee() -> None:
            """Write every line to the transcript, then echo it to this process."""
            assert process.stdout is not None
            console = getattr(sys.stdout, "buffer", None)
            for line in process.stdout:
                handle.write(line)
                if console is not None:
                    console.write(line)
                    console.flush()
                else:
                    sys.stdout.write(line.decode(errors="replace"))
                    sys.stdout.flush()

        pump = threading.Thread(target=tee, daemon=True)
        pump.start()
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            code = 124
        pump.join()
        if code == 124:
            handle.write(f"\nagent: timed out after {timeout}s\n".encode())
    return code
