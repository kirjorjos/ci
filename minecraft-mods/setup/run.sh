#!/usr/bin/env bash
# Runs the consumer's declared setup steps, one shell per entry, in order.
#
# The shared image is the same for every consumer, so it can only carry what they all need. What one
# line needs on top - a GL stack so its client can open a window, a JDK its toolchain pins - is in
# its own `.github/metadata.json` under `setup`, which keeps this repository from growing a branch
# per consumer and keeps a missing package visible where it belongs.
set -euo pipefail

file=.github/metadata.json
if [[ ! -f $file ]]; then
  echo "::error::no $file; nothing declares setup steps"
  exit 1
fi

mapfile -t steps < <(jq -r '(.setup // [])[]' "$file")
for step in "${steps[@]}"; do
  # A blank entry is a formatting accident, not a command.
  [[ -n ${step//[[:space:]]/} ]] || continue
  echo "::group::setup: $step"
  bash -euo pipefail -c "$step"
  echo "::endgroup::"
done
