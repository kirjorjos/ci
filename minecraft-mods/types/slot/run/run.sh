#!/usr/bin/env bash
# Runs test_slot.py for one mode. Inputs arrive as env from action.yml.
#
# GH_TOKEN and REPO must be set by the caller: the queue is an orphan branch, so writing it needs a
# token with `contents: write`, which a pull_request_target caller can only get from the app.
set -euo pipefail

: "${MODE:?}" "${REPO:?}" "${GH_TOKEN:?}"

script="${GITHUB_ACTION_PATH}/test_slot.py"

# A workflow expression cannot slice a ref, so the version line is derived here (and again inside the
# script, which is what maps an unversioned target onto its shared line).
mc="${MC:-}"
if [[ -z "$mc" && -n "${TARGET:-}" ]]; then
  mc="${TARGET%%/*}"
fi

args=()
case "$MODE" in
  event)
    args=(event)
    ;;
  reconcile)
    args=(reconcile)
    [[ -n "$mc" ]] && args+=(--mc "$mc")
    [[ "${FORCE:-false}" == "true" ]] && args+=(--force)
    ;;
  take | take-chore)
    kind=pr
    [[ "$MODE" == "take-chore" ]] && kind=chore
    args=(
      take --kind "$kind" --pr "${PR:-}" --sha "${SHA:?}" --target "${TARGET:-}"
      --compare "${COMPARE:-}" --fork "${FORK:-false}" --head-repo "${HEAD_REPO:-}"
      --minutes "${MINUTES:-90}"
    )
    ;;
  release)
    args=(release --pr "${PR:-}" --sha "${SHA:?}" --target "${TARGET:-}")
    ;;
  status)
    args=(status)
    [[ -n "$mc" ]] && args+=(--mc "$mc")
    ;;
  hold)
    args=(hold --mc "${mc:?}" --pr "${PR:-}")
    ;;
  free)
    args=(free --mc "${mc:?}")
    ;;
  *)
    echo "::error::unknown mode '$MODE'" >&2
    exit 1
    ;;
esac

python3 "$script" "${args[@]}"
