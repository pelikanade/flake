#!/usr/bin/env bash
# Map the action's inputs onto the omp-agent command line.
#
# The composite action runs this, and the test suite runs it with the same INPUT_
# variables, so the mapping is verified without a workflow run.
set -euo pipefail

args=(--prompt "$INPUT_PROMPT" --log "$INPUT_LOG")
args+=(--max-time "$INPUT_MAX_TIME" --timeout "$INPUT_TIMEOUT")

if [ -n "$INPUT_MODEL" ]; then args+=(--model "$INPUT_MODEL"); fi
if [ -n "$INPUT_OMP" ]; then args+=(--omp "$INPUT_OMP"); fi
if [ -n "$INPUT_CWD" ]; then args+=(--cwd "$INPUT_CWD"); fi
if [ -n "$INPUT_SESSION_DIR" ]; then args+=(--session-dir "$INPUT_SESSION_DIR"); fi
if [ -n "$INPUT_APPROVAL_MODE" ]; then args+=(--approval-mode "$INPUT_APPROVAL_MODE"); fi
if [ "$INPUT_THOUGHTS" = "false" ]; then args+=(--no-thoughts); fi
if [ "$INPUT_NO_SKILLS" = "true" ]; then args+=(--no-skills); fi
if [ "$INPUT_NO_PTY" = "true" ]; then args+=(--no-pty); fi
if [ "$INPUT_NO_LSP" = "true" ]; then args+=(--no-lsp); fi
if [ "$INPUT_NO_TITLE" = "true" ]; then args+=(--no-title); fi
if [ -n "${INPUT_EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2086  # the input is a deliberate argument list
  for extra in ${INPUT_EXTRA_ARGS}; do args+=("--extra-arg=$extra"); done
fi

exec python3 "$GITHUB_ACTION_PATH/omp_agent.py" "${args[@]}"
