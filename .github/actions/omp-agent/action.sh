#!/usr/bin/env bash
# Map the action's inputs onto the omp-agent command line.
#
# The composite action runs this, and the test suite runs it with the same INPUT_
# variables, so the mapping is verified without a workflow run.
set -euo pipefail

args=(--prompt "$INPUT_PROMPT")
args+=(--max-time "$INPUT_MAX_TIME" --timeout "$INPUT_TIMEOUT")

if [ -n "$INPUT_MODEL" ]; then args+=(--model "$INPUT_MODEL"); fi
if [ -n "$INPUT_OMP" ]; then args+=(--omp "$INPUT_OMP"); fi
if [ -n "$INPUT_CWD" ]; then args+=(--cwd "$INPUT_CWD"); fi
if [ -n "$INPUT_APPROVAL_MODE" ]; then args+=(--approval-mode "$INPUT_APPROVAL_MODE"); fi
if [ "$INPUT_THOUGHTS" = "false" ]; then args+=(--no-thoughts); fi
if [ -n "${INPUT_SKILLS:-}" ]; then
  # shellcheck disable=SC2086  # the input is a deliberate list of skill specs
  for spec in ${INPUT_SKILLS}; do args+=("--skill=$spec"); done
fi
if [ -n "${INPUT_EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2086  # the input is a deliberate argument list
  for extra in ${INPUT_EXTRA_ARGS}; do args+=("--extra-arg=$extra"); done
fi

exec python3 "$GITHUB_ACTION_PATH/omp_agent.py" "${args[@]}"
