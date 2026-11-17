# github_runner

在這台 Mac 上手動起停 GitHub Actions self-hosted runner（Docker）。沒開的時候不接 job。

## 使用

```sh
cp .env.example .env      # 設定 REPOS 等
./runner.sh up            # build、註冊 runner、設定 repo variable CI_RUNS_ON
./runner.sh status
./runner.sh logs your-user/your-repo
./runner.sh down          # 停掉、反註冊，並刪掉 CI_RUNS_ON（回退到 GitHub-hosted）
```

需要：Docker（Docker Desktop 或 OrbStack，要能跑 privileged 容器）、已登入的 `gh`（帳號要有 repo admin 權限）。
容器裡不放長期憑證，只帶 1 小時有效的 registration token。

## Workflow 要改

`runs-on: ubuntu-latest` 永遠跑在 GitHub-hosted，二選一：

```yaml
# 跟著 runner 起停切換；runner 關掉時回到 GitHub-hosted
runs-on: ${{ fromJSON(vars.CI_RUNS_ON || '"ubuntu-latest"') }}

# 只用本機；runner 關掉時 job 排隊（最多 24h，之後 GitHub 取消）
runs-on: [self-hosted, laptop]
```

- `up` 之後：`CI_RUNS_ON=["self-hosted","laptop"]`。
- `down` 之後：variable 被刪。不想回退就在 `.env` 設 `FALLBACK_TO_HOSTED=false`。
- variable 只在 job 排入佇列時求值，已經在跑的 job 不受影響。

## 架構

每個 runner 容器是 privileged，裡面跑自己的 `dockerd`（Docker-in-Docker）：

- job 看不到也碰不到 host 上的容器。
- `services:` 的 port 發佈在該 runner 自己的 network namespace，step 用 `localhost:<port>` 連，
  跟 hosted runner 一樣；多個 runner 同時綁 `5432:5432` 不衝突，`RUNNERS_PER_REPO` 預設 3。
- cache 放在 named volume `ghr-<owner>-<repo>_runner-cache`（掛在 `/cache`），每個 replica 用 flock 佔一個 slot
  （`slot1`、`slot2`…），`down`/`up` 之間保留。同一 slot 同時只有一個 runner 用，不會有並行寫入問題：

  | 路徑 | 用途 |
  |---|---|
  | `/cache/slotN/docker` | dockerd data-root（image cache） |
  | `/cache/slotN/tool` | `_work/_tool` 的 symlink 目標（setup-go / setup-node 的 toolchain） |
  | `/cache/slotN/go-mod` | `GOMODCACHE` |
  | `/cache/slotN/go-build` | `GOCACHE` |
  | `/cache/slotN/pnpm-store` | `pnpm_config_store_dir`（pnpm 12 不認 `npm_config_*`） |

  `GOMODCACHE`、`GOCACHE`、`pnpm_config_store_dir` 由 entrypoint export，job step 會繼承；workflow 可以把
  setup-go / setup-node 的 `cache` 關掉，不用經過 GitHub Actions cache。
  GOCACHE 會保留通過的測試結果，所以 entrypoint 也 export `GOFLAGS=-count=1`，避免同一 slot 重跑時回報
  cached 結果、跳過依賴外部狀態（例如 live DB）的測試。workflow 自己設 `GOFLAGS` 會覆蓋這個預設。
  啟動時和每個 job 結束後（`ACTIONS_RUNNER_HOOK_JOB_COMPLETED`）都會跑 `cleanup.sh`，清掉該 runner 的 dockerd 裡
  停掉的容器、network、volume；image 與上述 cache 保留。postgres 這類 image 宣告了 `VOLUME`，不清的話每個 job
  會留下一個約 500MB 的匿名 volume。正常大小約每個 slot 4–5GB（3 個 slot 約 14GB）。
  要整個清掉：`docker volume rm ghr-your-user-your-repo_runner-cache`。
- workspace（`_work` 其餘部分）在容器檔案系統裡，`down` 時消失。

## 注意

- Runner 是 linux/arm64（GitHub-hosted 是 x64），用到 x64-only 的 binary/action 會壞。
- `down` 會立刻取消執行中的 job（GitHub 上顯示 cancelled），容器在幾秒內結束。
- privileged 等於 Docker VM 的 root；只用在 private repo。public repo 的 fork PR 可以在這台跑任意程式碼，
  而且 public repo 用 GitHub-hosted 本來就免費。

## License

[MIT](LICENSE)
