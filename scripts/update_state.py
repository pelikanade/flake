"""How a package update phase reports its outcome to the workflow.

The workflow runs one script per phase and lets each phase decide its own
outcome. A phase publishes that decision as step outputs, and the workflow
reads them back in the conditions of the later phases and in the publish
decision:

  gate       the reason this phase rejected the run (`update`, `build`,
             `repair`, `outside`, `review`). A phase that publishes a gate
             never publishes `ok`.
  ok         this phase verified everything it owns and the run may be
             published so far. A run where no phase publishes `ok` is never
             published.
  clean-tip  the commit the clean update pins ended at; a rejected run resets
             to it so the clean updates still land.

Outside GitHub Actions (`GITHUB_OUTPUT` unset) a phase only prints its
decision, and the later phases take what they need as options.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

# The paths an update agent may touch. Everything else is a gate.
AGENT_PATHS = ["modules/packages", ".update-agent", ".ci", ".review"]


def output(name: str, value: str) -> None:
    """Publish a step output; outside GitHub Actions this does nothing."""
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(f"{name}={value}\n")


def _status(repo: Path, pathspecs: list[str]) -> str:
    result = subprocess.run(
        ["git", "status", "--porcelain", "--", *pathspecs],
        cwd=repo,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit("error: could not inspect the working tree")
    return result.stdout


def repair_changes(repo: Path) -> str:
    """Working-tree changes to the package tree; what the repair produced."""
    return _status(repo, ["modules/packages"])


def outside_changes(repo: Path) -> str:
    """Working-tree changes outside the paths an update agent may touch."""
    return _status(repo, [".", *(f":(exclude){path}" for path in AGENT_PATHS)])
