# github_runner

[繁體中文](README.md) | English

Start and stop GitHub Actions self-hosted runners in Docker on your own machine, to save GitHub-hosted minutes on private repos.

- **Manual on/off**: runners take jobs only after `./runner.sh up` and stop with `./runner.sh down`. Nothing runs in the background or at boot.
- **Docker-in-Docker**: each runner has its own `dockerd`. `services:` containers are reachable on `localhost:<port>` just like on
  GitHub-hosted runners, parallel runners never fight over ports, and jobs cannot touch the host's containers.
- **Caches across jobs and restarts**: toolchains, Go module/build caches, the pnpm store and Docker images stay in a volume,
  without going through the GitHub Actions cache.
- **No long-lived credentials**: a 1-hour registration token is fetched with the host's logged-in `gh`; no PAT ever enters a container.

## Requirements

- Docker with Docker Compose v2, able to run privileged containers (Docker Desktop, OrbStack and native Linux Docker all work)
- [`gh`](https://cli.github.com/), logged in with an account that has admin access to the target repos
- bash

## Quick start

1. Configure:

   ```sh
   cp .env.example .env
   # edit .env and set at least REPOS="your-user/your-repo"
   ```

2. Change the workflow's `runs-on` to one of these (`ubuntu-latest` always runs on GitHub-hosted runners):

   ```yaml
   # A. Follow the runner: local while it is up, GitHub-hosted while it is down
   runs-on: ${{ fromJSON(vars.CI_RUNS_ON || '"ubuntu-latest"') }}

   # B. Local only: while the runner is down, jobs wait in the queue (up to 24 hours, then GitHub cancels them)
   runs-on: [self-hosted, laptop]
   ```

3. Start and stop:

   ```sh
   ./runner.sh up                    # build the image, register runners, set the CI_RUNS_ON repo variable
   ./runner.sh status                # container state and runner state on GitHub
   ./runner.sh logs your-user/your-repo
   ./runner.sh down                  # stop, remove the runners from GitHub, delete CI_RUNS_ON (by default)
   ```

   `up`, `down` and `status` take one or more `owner/repo` arguments and default to `REPOS` from `.env`; `logs` needs exactly one repo.

## Configuration (`.env`)

| Variable | Default | Description |
|---|---|---|
| `REPOS` | (required) | Space-separated `owner/repo` list; each repo gets its own set of runners |
| `LABEL` | `laptop` | Custom label; workflows target `[self-hosted, <LABEL>]` |
| `RUNNERS_PER_REPO` | `3` | Runners per repo, i.e. how many jobs run at once |
| `RUNS_ON_VAR` | `CI_RUNS_ON` | Repo variable that `up` sets and `down` deletes (used by option A) |
| `FALLBACK_TO_HOSTED` | `true` | When `false`, `down` keeps the variable, so jobs queue for the runner instead |

## How it works

### Docker-in-Docker

Each runner container is privileged. It starts its own `dockerd` first, then the runner:

- Ports published by `services:` live in that runner's own network namespace, and steps connect via `localhost:<port>`.
  Several runners can bind `5432:5432` at the same time.
- `cleanup.sh` runs at startup and after every job (`ACTIONS_RUNNER_HOOK_JOB_COMPLETED`), removing stopped containers,
  networks and volumes while keeping images. Images such as postgres declare `VOLUME`, so without this every job
  would leave an anonymous volume behind.

### Caches

Caches live in the named volume `ghr-<owner>-<repo>_runner-cache`, mounted at `/cache`. On startup each runner takes a slot
(`slot1`, `slot2`, …) with flock. A slot is used by only one runner at a time, so there are no concurrent writes:

| Path | Purpose |
|---|---|
| `/cache/slotN/docker` | `dockerd` data-root (image cache) |
| `/cache/slotN/tool` | `_work/_tool` (toolchains installed by actions such as setup-go and setup-node) |
| `/cache/slotN/go-mod` | `GOMODCACHE` |
| `/cache/slotN/go-build` | `GOCACHE` |
| `/cache/slotN/pnpm-store` | `pnpm_config_store_dir` (pnpm 12+ no longer reads `npm_config_*`) |

- The entrypoint exports these variables and job steps inherit them, so workflows can turn off `cache` in
  `actions/setup-go` and `actions/setup-node` and skip the GitHub Actions cache.
- Since `GOCACHE` also keeps passing test results, the entrypoint sets `GOFLAGS=-count=1`. Otherwise a rerun on the same
  slot could report cached passes and skip tests that depend on outside state, such as a database.
  A `GOFLAGS` set in the workflow overrides this default.
- The workspace (the rest of `_work`) lives on the container's filesystem and is wiped on `down`.
- Cache size depends on the project, with one copy per slot. To wipe everything:

  ```sh
  docker volume rm ghr-your-user-your-repo_runner-cache
  ```

## Limitations

- **Repo-level runners only**: personal accounts have no account-level runners, so each repo gets its own set.
- **Architecture follows the host**: on Apple Silicon the runners are linux/arm64, while GitHub-hosted runners are x64.
  Actions or tools that ship only x64 binaries will fail.
- **Runners are not ephemeral**: a runner takes job after job (that is what keeps the caches), so jobs do not start from a clean environment.
- **No automatic restart**: the registration token expires after 1 hour, so after a container stops, run `./runner.sh up` to get a new one.
- `down` cancels running jobs immediately (shown as cancelled on GitHub), and containers exit within seconds.

## Security

A privileged container has root on the Docker host (or the Docker Desktop VM), and jobs run arbitrary code.

- **Use it for private repos only.** Anyone can open a fork PR on a public repo and run code on your machine;
  and public repos get GitHub-hosted runners for free anyway.
- Give write access to the repo only to people you trust.

## License

[MIT](LICENSE)
