"""Shared omp invocation for the update repair and review workflows.

Both agents use omp's built-in DeepSeek provider, whose model named
"DeepSeek V4.1 Flash 1017" is selected as `deepseek/deepseek-flash`. omp reads
the key from `DEEPSEEK_API_KEY`; the workflow maps the repository secret of the
same name to it.
"""

from __future__ import annotations

import os
from pathlib import Path

DEFAULT_MODEL = "deepseek/deepseek-flash"


class ConfigError(Exception):
    """The agent cannot be configured; the message is user-facing."""


def configure(model: str | None, api_key: str | None) -> tuple[str, str | None]:
    """Return (model, api_key); a None key means omp reads the environment."""
    if not api_key and not os.environ.get("DEEPSEEK_API_KEY"):
        raise ConfigError("set the DEEPSEEK_API_KEY repository secret")
    return model or DEFAULT_MODEL, api_key


def command(
    *,
    omp: str,
    repo: Path,
    prompt: Path,
    model: str,
    api_key: str | None,
    session_dir: Path,
    max_time: str,
) -> list[str]:
    result = [
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
        "--no-extensions",
        "--session-dir",
        str(session_dir),
        "--max-time",
        max_time,
    ]
    if api_key:
        result += ["--api-key", api_key]
    result.append(f"@{prompt}")
    return result


def redacted(command: list[str]) -> list[str]:
    """Drop the API key from a command stored in a report."""
    result: list[str] = []
    skip = False
    for arg in command:
        if skip:
            result.append("<redacted>")
            skip = False
        elif arg == "--api-key":
            result.append(arg)
            skip = True
        else:
            result.append(arg)
    return result
