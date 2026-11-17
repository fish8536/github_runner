#!/usr/bin/env bash
# Starts a private dockerd, registers this container as a repo runner and runs it.
# Deregistration happens on the host (`runner.sh down`), so no long-lived credential
# ever enters the container.
set -euo pipefail

: "${REPO_URL:?}" "${REG_TOKEN:?}" "${RUNNER_LABELS:?}"
name="${RUNNER_NAME_PREFIX:-laptop}-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"

# Replicas share one cache volume, but a dockerd data-root and the hosted tool cache cannot
# be shared safely. Each replica takes the first free slot and holds its lock for the
# container's lifetime, so caches survive `down`/`up` without two runners ever writing the
# same directory.
cache=/cache
sudo chown runner "$cache"
for ((slot = 1; ; slot++)); do
  exec {lock}>"$cache/slot$slot.lock"
  flock -n "$lock" && break
  exec {lock}>&-
done
slot_dir="$cache/slot$slot"
data_root="$slot_dir/docker"
mkdir -p "$slot_dir"/{tool,go-mod,go-build,pnpm-store}

# Job steps inherit the runner's environment. setup-go / setup-node install into _work/_tool.
export GOMODCACHE="$slot_dir/go-mod" GOCACHE="$slot_dir/go-build"
# A persistent GOCACHE also holds passing test results, so a rerun on the same slot would
# report cached passes without running tests that depend on outside state (e.g. a live DB).
# go applies GOFLAGS entries only to commands that know the flag, so build/vet ignore it.
export GOFLAGS=-count=1
export pnpm_config_store_dir="$slot_dir/pnpm-store"
mkdir -p _work
ln -sfn "$slot_dir/tool" _work/_tool

sudo dockerd --data-root "$data_root" --group docker >/tmp/dockerd.log 2>&1 &
for _ in $(seq 60); do docker info >/dev/null 2>&1 && break; sleep 0.5; done
docker info >/dev/null 2>&1 || { cat /tmp/dockerd.log >&2; exit 1; }
# Leftovers from a job killed in a previous session; after that, the hook cleans every job.
/cleanup.sh
export ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/cleanup.sh
echo "dockerd ready (data-root $data_root)"

./config.sh --unattended --replace \
  --url "$REPO_URL" \
  --token "$REG_TOKEN" \
  --name "$name" \
  --labels "$RUNNER_LABELS" \
  --work _work \
  --disableupdate

# run.sh turns SIGTERM into SIGINT for the Listener, which then prints "Exiting runner..."
# and hangs until SIGKILL. SIGTERM sent to the Listener directly cancels any running job,
# reports it, and exits within seconds.
./run.sh &
pid=$!
trap 'pkill -TERM -f bin/Runner.Listener' TERM INT
wait "$pid" || true
wait "$pid" 2>/dev/null || true

# Stop dockerd cleanly so its data-root (the shared cache) is never killed mid-write.
sudo pkill -TERM -x dockerd || true
for _ in $(seq 40); do pgrep -x dockerd >/dev/null || break; sleep 0.5; done
