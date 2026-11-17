#!/usr/bin/env bash
# Start/stop self-hosted runners on this laptop. Uses the host's `gh` login for all API calls.
#
#   ./runner.sh up     [owner/repo ...]   build, register, start; point CI at this laptop
#   ./runner.sh down   [owner/repo ...]   stop, deregister; CI falls back to GitHub-hosted
#   ./runner.sh status [owner/repo ...]
#   ./runner.sh logs   owner/repo
#
# Repos default to REPOS in .env.
set -euo pipefail
cd "$(dirname "$0")"

[[ -f .env ]] && source .env
: "${REPOS:=}"
: "${LABEL:=laptop}"
: "${RUNNERS_PER_REPO:=3}"
: "${RUNS_ON_VAR:=CI_RUNS_ON}"
: "${FALLBACK_TO_HOSTED:=true}"

die() { echo "error: $*" >&2; exit 1; }
project() { echo "ghr-$(tr '/A-Z' '-a-z' <<<"$1")"; }
compose() { docker compose -p "$(project "$1")" "${@:2}"; }

repos() {
  local list=("$@")
  ((${#list[@]})) || read -ra list <<<"$REPOS"
  ((${#list[@]})) || die "no repo given and REPOS is empty in .env"
  printf '%s\n' "${list[@]}"
}

up() {
  docker compose build -q
  for repo in $(repos "$@"); do
    echo "==> $repo"
    local token
    token=$(gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token)
    REPO_URL="https://github.com/$repo" REG_TOKEN="$token" RUNNER_LABELS="$LABEL" \
      compose "$repo" up -d --scale "runner=$RUNNERS_PER_REPO"
    gh variable set "$RUNS_ON_VAR" -R "$repo" --body "[\"self-hosted\",\"$LABEL\"]"
  done
}

down() {
  for repo in $(repos "$@"); do
    echo "==> $repo"
    # Unset first so jobs queued from now on go to GitHub-hosted instead of waiting.
    if [[ $FALLBACK_TO_HOSTED == true ]]; then
      gh variable delete "$RUNS_ON_VAR" -R "$repo" 2>/dev/null || true
    fi
    compose "$repo" down
    # Containers are gone, so every runner with LABEL is stale. GitHub can keep showing
    # them online for a while, hence no status filter.
    gh api "repos/$repo/actions/runners" --paginate \
      --jq ".runners[] | select(any(.labels[]; .name==\"$LABEL\")) | .id" |
      while read -r id; do
        gh api -X DELETE "repos/$repo/actions/runners/$id" && echo "deregistered runner $id"
      done
  done
}

status() {
  for repo in $(repos "$@"); do
    echo "==> $repo  ($RUNS_ON_VAR=$(gh variable get "$RUNS_ON_VAR" -R "$repo" 2>/dev/null || echo unset))"
    compose "$repo" ps --format '  {{.Name}}  {{.Status}}'
    gh api "repos/$repo/actions/runners" --paginate \
      --jq '.runners[] | "  \(.name)  \(.status)  busy=\(.busy)"'
  done
}

logs() {
  [[ $# -eq 1 ]] || die "usage: $0 logs owner/repo"
  compose "$1" logs -f
}

cmd="${1:-}"; shift || true
case "$cmd" in
  up|down|status|logs) "$cmd" "$@" ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
