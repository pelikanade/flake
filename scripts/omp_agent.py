"""Shared omp invocation for the update repair and review workflows.

Both agents run omp against the Magpie gateway on `neko-sphere` through the
omp-magpie extension. The extension is loaded through `PI_CONFIG_FILES`, and it
reads the gateway endpoint and key from `~/.omp/agent/magpie.yaml`; the update
runner provisions both, so no provider secret is passed to omp or stored in
GitHub Actions.
"""

from __future__ import annotations

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
