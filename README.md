# github_runner

繁體中文 | [English](README.en.md)

在自己的電腦上用 Docker 起停 GitHub Actions self-hosted runner，用來替 private repo 省下 GitHub-hosted 的分鐘數。

- **手動起停**：`./runner.sh up` 才接 job，`./runner.sh down` 就停。不常駐、不開機自啟。
- **Docker-in-Docker**：每個 runner 有自己的 `dockerd`，`services:` 容器與 GitHub-hosted 一樣用 `localhost:<port>` 存取，
  多個 runner 平行跑也不會搶 port，job 也碰不到 host 上的容器。
- **跨 job / 跨重啟的 cache**：toolchain、Go module/build cache、pnpm store、Docker image 都留在 volume，
  不必經過 GitHub Actions cache。
- **不存長期憑證**：用 host 上已登入的 `gh` 取得 1 小時有效的 registration token，容器裡沒有 PAT。

## 需求

- Docker 與 Docker Compose v2，要能跑 privileged 容器（Docker Desktop、OrbStack、Linux 原生 Docker 都可以）
- 已登入的 [`gh`](https://cli.github.com/)，帳號要有目標 repo 的 admin 權限
- bash

## 快速開始

1. 設定：

   ```sh
   cp .env.example .env
   # 編輯 .env，至少設定 REPOS="your-user/your-repo"
   ```

2. 把 workflow 的 `runs-on` 改成以下其中一種（`ubuntu-latest` 永遠只會跑在 GitHub-hosted）：

   ```yaml
   # A. 跟著 runner 起停切換：runner 開著跑本機，關掉時回到 GitHub-hosted
   runs-on: ${{ fromJSON(vars.CI_RUNS_ON || '"ubuntu-latest"') }}

   # B. 只用本機：runner 關掉時 job 排隊等待（最多 24 小時，之後 GitHub 會取消）
   runs-on: [self-hosted, laptop]
   ```

3. 起停：

   ```sh
   ./runner.sh up                    # build image、註冊 runner、設定 repo variable CI_RUNS_ON
   ./runner.sh status                # 容器狀態與 GitHub 上的 runner 狀態
   ./runner.sh logs your-user/your-repo
   ./runner.sh down                  # 停止、從 GitHub 移除 runner、（預設）刪除 CI_RUNS_ON
   ```

   `up`、`down`、`status` 可以帶一或多個 `owner/repo`，省略時用 `.env` 的 `REPOS`；`logs` 需要指定一個 repo。

## 設定（`.env`）

| 變數 | 預設 | 說明 |
|---|---|---|
| `REPOS` | （必填） | 空白分隔的 `owner/repo` 清單，每個 repo 各起一組 runner |
| `LABEL` | `laptop` | 自訂 label；workflow 用 `[self-hosted, <LABEL>]` 指定 |
| `RUNNERS_PER_REPO` | `3` | 每個 repo 的 runner 數，也就是可同時執行的 job 數 |
| `RUNS_ON_VAR` | `CI_RUNS_ON` | `up` 設定、`down` 刪除的 repo variable 名稱（寫法 A 用） |
| `FALLBACK_TO_HOSTED` | `true` | `false` 時 `down` 不刪除 variable，job 改為排隊等 runner |

## 運作方式

### Docker-in-Docker

每個 runner 容器是 privileged，裡面先啟動自己的 `dockerd`，再啟動 runner：

- `services:` 的 port 發佈在該 runner 自己的 network namespace，step 用 `localhost:<port>` 連。
  多個 runner 同時綁 `5432:5432` 不衝突。
- 啟動時與每個 job 結束後（`ACTIONS_RUNNER_HOOK_JOB_COMPLETED`）都會執行 `cleanup.sh`，
  清掉停止的容器、network 與 volume，image 保留。postgres 這類 image 宣告了 `VOLUME`，
  不清的話每個 job 都會留下一個匿名 volume。

### Cache

Cache 放在 named volume `ghr-<owner>-<repo>_runner-cache`（掛在 `/cache`）。每個 runner 啟動時用 flock
佔用一個 slot（`slot1`、`slot2`…），同一個 slot 同一時間只有一個 runner 使用，所以沒有並行寫入問題：

| 路徑 | 用途 |
|---|---|
| `/cache/slotN/docker` | `dockerd` data-root（image cache） |
| `/cache/slotN/tool` | `_work/_tool`（setup-go、setup-node 等 action 安裝的 toolchain） |
| `/cache/slotN/go-mod` | `GOMODCACHE` |
| `/cache/slotN/go-build` | `GOCACHE` |
| `/cache/slotN/pnpm-store` | `pnpm_config_store_dir`（pnpm 12 起不再讀 `npm_config_*`） |

- 上述環境變數由 entrypoint export，job step 會繼承。workflow 可以關掉 `actions/setup-go` 與
  `actions/setup-node` 的 `cache`，不經過 GitHub Actions cache。
- 因為 `GOCACHE` 會保留通過的測試結果，entrypoint 也設定了 `GOFLAGS=-count=1`，
  避免同一個 slot 重跑時直接回報 cached 結果、跳過依賴外部狀態（例如資料庫）的測試。
  workflow 自己設定 `GOFLAGS` 會覆蓋這個預設值。
- Workspace（`_work` 的其餘部分）在容器的檔案系統裡，`down` 時清除。
- Cache 大小取決於專案，每個 slot 各一份。要整個清掉：

  ```sh
  docker volume rm ghr-your-user-your-repo_runner-cache
  ```

## 限制

- **只支援 repo 層級的 runner**：個人帳號沒有帳號層級的 runner，每個 repo 各註冊一組。
- **架構跟著主機**：Apple Silicon 上是 linux/arm64，而 GitHub-hosted 是 x64，只提供 x64 binary 的 action 或工具會失敗。
- **Runner 不是 ephemeral**：同一個 runner 會連續接多個 job（cache 才能保留），job 之間不是乾淨環境。
- **不會自動重啟**：registration token 1 小時後過期，容器停止後要用 `./runner.sh up` 重新取得 token。
- `down` 會立刻取消執行中的 job（GitHub 上顯示 cancelled），容器在幾秒內結束。

## 安全性

privileged 容器等同於 Docker host（或 Docker Desktop VM）的 root 權限，job 可以執行任意程式碼。

- **只用在 private repo**。public repo 的任何人都能開 fork PR，在你的電腦上執行程式碼；
  況且 public repo 使用 GitHub-hosted runner 本來就免費。
- 只讓你信任的人有 repo 的寫入權限。

## License

[MIT](LICENSE)
