# 02 — Railway 平台限制與對應策略

每一節都是「Railway 的規則」→「與 Hermes 的衝突」→「本計畫的對策」。資料來源為 2026-08 的 Railway 官方文件（連結列於文末）。

---

## 1. Start command 會覆蓋映像的 ENTRYPOINT ⚠️ 最關鍵

**規則**：以 Dockerfile 或 image 部署的 service，start command 預設就是映像的 ENTRYPOINT/CMD；但**一旦你在 Railway 設定 custom start command，它會以 exec form 覆蓋映像的 ENTRYPOINT**。

**衝突**：Hermes 的 `ENTRYPOINT ["/opt/hermes/docker/entrypoint-dispatch.sh"]` 是整條 bootstrap 的入口——覆蓋掉它等於跳過 `/init`(s6)、跳過 volume chown、跳過 `.env`/`config.yaml` seed、跳過 config schema migration、跳過 gateway 與 dashboard 的監管服務。容器會以某種半殘狀態啟動，症狀通常是 EACCES 或「dashboard 沒起來」。

**對策**：
- **Railway 的 start command 欄位一律留空。**
- 在本專案自己的薄封裝 Dockerfile 裡寫 `CMD ["gateway", "run"]`，讓參數烤進映像。
- 若因故必須設 start command，唯一安全的值是把 ENTRYPOINT 手動寫回去：
  `/opt/hermes/docker/entrypoint-dispatch.sh gateway run`

---

## 2. Volume：掛載、權限、單一性

**規則**：
- Volume 在**容器啟動時**才掛載，build 期間不存在；pre-deploy command 也讀不到 volume。
- **Volume 以 root 身分掛載。** 非 root 的映像需要在 service 上設 `RAILWAY_RUN_UID=0`。
- 自動注入 `RAILWAY_VOLUME_NAME` 與 `RAILWAY_VOLUME_MOUNT_PATH`。
- 容量：Trial/Free **0.5 GB**、Hobby **5 GB**、Pro **1 TB**（可自助擴充）。付費方案支援不停機 live resize。
- **掛了 volume 的 service，重新部署時會有短暫停機**——因為多個 active deployment 無法同時掛同一顆 volume，即使設了 healthcheck 也一樣。

**衝突 / 契合**：
- Hermes 的 `stage2-hook.sh` 需要以 root 啟動才能做 UID remap 與 chown；Hermes 映像最後一個 `USER` 指令是 `root`，所以本來就以 root 啟動 ✅。但仍**明確設定 `RAILWAY_RUN_UID=0`** 當作防禦，避免 Railway 端預設值變動。
- 「同一顆 volume 不會有兩個 active deployment」正好滿足 Hermes「絕不可兩個 gateway 共用資料目錄」的硬性要求 ✅。
- **已確認 Pro 方案**：volume 上限 1 TB 且可自助擴充 + live resize，容量不是問題 ✅。

**對策**：
- Volume mount path = **`/opt/data`**（就是 `$HERMES_HOME`，Dockerfile 裡也有 `VOLUME ["/opt/data"]`）。
- 設 `RAILWAY_RUN_UID=0`。
- 不用 pre-deploy command 做任何需要碰 volume 的事（Hermes 的 migration 已經在 `cont-init.d` 裡跑，時機正確）。
- Replica 固定 1，不啟用多 region。

---

## 3. 單一對外埠 / PORT 變數

**規則**：
- 可在 service variables 設 `PORT`；**若 domain 沒有指定 target port，Railway 會把流量導到 `PORT` 指定的埠**。
- 應用若監聽多個埠，加 domain 時可從清單選一個 target port。
- **一個 domain 只能對應一個埠。** 要同時對外開兩個埠，需要**兩個 custom domain**，各自綁一個 target port。
- 自訂網域數量：Trial 1 / Hobby 2 / **Pro 20**（可申請增加）。自訂網域需要 **CNAME + TXT 兩筆記錄**（只加 CNAME 會回 404），Railway 自動簽發 Let's Encrypt 憑證。Apex 根網域需 DNS 商支援 CNAME flattening / ALIAS（Cloudflare 支援；Route 53 / GoDaddy 不支援）。

**衝突**：Hermes 有三個潛在的對外面（dashboard 9119 / api_server 8642 / telegram webhook 8443）。

**已確認使用自有網域 `relvo.cc`**（建議 `hermes.relvo.cc`）→ Pro 的 20 個網域額度讓「一個 domain 一個埠」不再是實質限制。但既有決策不變：Telegram 用 polling、api_server 不對外，所以**實際上只需要一個網域**。

自訂網域帶來的兩個必辦事項（詳見 [`07`](./07-dashboard-access-control.md) §2）：**`HERMES_DASHBOARD_PUBLIC_URL` 必須明確設定**（不能依賴 `RAILWAY_PUBLIC_DOMAIN` 推導，其在自訂網域下的取值未文件化），以及**確認後移除 Railway 產生的網域**（否則 dashboard 有兩個對外入口）。

**對策**：
- **dashboard 當主要對外入口**：設 `PORT=9119` 與 `HERMES_DASHBOARD_PORT=9119`（兩者一致，同時滿足 Railway 的 healthcheck 定位與 domain 路由）；`HERMES_DASHBOARD_HOST=0.0.0.0`（容器內已是預設，明寫比較不會出意外）。
- 本專案的 `016-railway-bootstrap` 腳本會在 `PORT` 有值而 `HERMES_DASHBOARD_PORT` 沒設時，自動把 dashboard 的埠對齊 `PORT`，讓兩種設定風格都能運作。
- **api_server 留在 loopback**（`127.0.0.1:8642`，預設值），只給容器內的 dashboard/cron 用。需要對公網開放 OpenAI 相容 API 時，才加第二個 custom domain（target port 8642）並設 `API_SERVER_HOST=0.0.0.0` + 強 `API_SERVER_KEY`。
- **Telegram 用 polling**，不佔埠。真的要 webhook 再開第三個 domain。

---

## 4. Healthcheck

**規則**：
- Railway 反覆請求 `healthcheckPath` 直到收到 HTTP 200，才把新 deployment 切為 active。
- 預設從注入的 `PORT` 打；若用 target port 就必須自己設 `PORT` 變數讓 Railway 知道打哪。
- 請求來源是 **`healthcheck.railway.app`**——會依 Host 標頭過濾流量的應用必須放行這個網域。
- 預設 timeout **300 秒**，可用 `RAILWAY_HEALTHCHECK_TIMEOUT_SEC` 調整。
- **上線後 Railway 不再監控該端點**，healthcheck 只驗證部署就緒，不是持續監控。

**對策**：
- `healthcheckPath = "/api/health"`（免驗證、刻意做得極輕量，見 `01` §3.2）。
- 明確設 `PORT=9119`。
- `healthcheckTimeout = 300`。Hermes 的冷開機要跑 chown、config migration、skills sync、Playwright 路徑偵測，加上 dashboard 起 uvicorn，需要一點時間；300 秒是安全的上限。
- 持續監控要另外接（Better Stack / Pingdom 打 `/api/health` 或 `/api/status`）。

---

## 5. 映像大小 / 建置

**規則**（Railway 方案資源上限）：

| 方案 | RAM | vCPU | Volume | 映像大小 | Ephemeral |
|---|---|---|---|---|---|
| Trial | 1 GB | 2 | 0.5 GB | **4 GB** | 1 GB |
| Free | 0.5 GB | 1 | 0.5 GB | **4 GB** | 1 GB |
| **Hobby** | 48 GB | 48 | **5 GB** | **100 GB** | 100 GB |
| Pro | 1 TB | 1000 | 1 TB | 無限 | 100 GB |

**已確認使用 Pro 方案** → 映像大小無限、volume 1 TB、ephemeral 100 GB、記憶體充裕。原本的容量顧慮全部解除。

**仍然成立的對策**（理由從「容量」變成「建置時間與流程」）：
- **不在 Railway 上從頭建 Hermes。** 上游自己把該 job 的 timeout 設在 **45 分鐘**，註解直言 **「the image is 5GB+」**，而且建置內容是：從原始碼編 SQLite 3.53.4 → 抓 s6-overlay → 複製 Node 26 → `npm install` + Playwright Chromium → photon sidecar `npm ci` → `uv sync` 八個 extras → 建 `web/` 與 `ui-tui/` 兩個前端。
- **fork 的完整映像交給 GitHub Actions**（有 `type=gha,mode=max` layer cache，且可只建 amd64——Railway 只跑 amd64，省掉 arm64 那一半），推到 GHCR。
- **Railway 只建薄封裝**（`FROM ghcr.io/lei-k/hermes-agent:<sha>` + COPY 一支腳本 + CMD），建置時間以秒計。
- **基底映像釘死 commit sha**，不用 `:main`——避免執行環境在無預警下改變。GHCR 上每個 commit 都有映像，回滾只是改一個 `ARG`。

**注意**：上游 `.github/workflows/docker.yml` 的 build job 有 `if: github.repository == 'NousResearch/hermes-agent'` 守衛，**在 fork 上永遠不會執行**，且發佈目標 `nousresearch/hermes-agent` 的 Docker Hub secret fork 也拿不到。fork 必須有自己的 workflow（見 `03` 階段 0）。

**GHCR 認證**：Railway 支援從 GHCR 拉映像，private package 需要 personal access token（不是密碼）。薄封裝在 **build** 階段拉基底映像，所以 credentials 必須在 build 階段可用——列為待驗證 A15。

---

## 6. 執行期環境

**規則 / 已知限制**：
- 沒有 Docker daemon、不能 bind-mount `/var/run/docker.sock`、不能開 privileged。
- 無法自訂 `--shm-size`。
- Ephemeral 檔案系統：volume 以外的寫入在重新部署後消失。
- `drainingSeconds` 控制 SIGTERM 到 SIGKILL 的間隔。

**衝突**：
- Hermes 的 `terminal.backend: docker` 沙箱後端**在 Railway 上不可用**——必須用 `local`（預設）或遠端後端（SSH / Modal / Daytona / Vercel Sandbox）。
- Playwright/Chromium 對 `/dev/shm` 敏感（Docker 預設只給 64 MB），官方 Docker 疑難排解建議 `--shm-size=1g`；Railway 給不了。
- `/opt/hermes/.playwright` 在映像層（非 volume），重新部署後仍在 ✅。`lazy-packages` 在 volume 上 ✅。

**對策**：
- 明確設 `terminal.backend: local`（在 `config.yaml`，由 `016-railway-bootstrap` 首次開機落地）。
- **瀏覽器工具（#6 確認需要）風險比原估低**：Hermes 會自動注入 `--no-sandbox,--disable-dev-shm-usage`，觸發條件是「以 root 執行，或在 AppArmor 受限的 unprivileged user namespace」，文件明列「many container images」。但容器內受監管服務是以 `hermes`(UID 10000) 執行而非 root，自動注入不一定命中——所以 `016-railway-bootstrap` 明確設定 `AGENT_BROWSER_ARGS`（注意：手動設定會停用自動注入，兩個 flag 必須寫齊）。
- 退路：雲端瀏覽器（Browserbase / Browser Use / Firecrawl / Nous Portal Tool Gateway）完全避開本地資源問題；或 Lightpanda 本地引擎（記憶體低 16 倍）。
- `drainingSeconds` 給 30 秒，讓 s6 有時間把 gateway 收乾淨、SQLite WAL checkpoint 完成。

---

## 7. Config as code（`railway.toml` / `railway.json`）

**可用欄位**：

```
[build]  builder ("RAILPACK"|"DOCKERFILE") / dockerfilePath / watchPatterns
         buildCommand / railpackVersion
[deploy] startCommand / preDeployCommand
         healthcheckPath / healthcheckTimeout
         restartPolicyType ("ON_FAILURE"|"ALWAYS"|"NEVER") / restartPolicyMaxRetries
         cronSchedule / multiRegionConfig / overlapSeconds / drainingSeconds
```
可用 `[environments.<name>]` 做環境覆寫（含特殊的 `pr` 環境）。

**限制**：**service source（要用哪個 Docker image）不在 config-as-code 的 schema 裡**——只能在 dashboard / CLI / TypeScript IaC 設定。Volume 與環境變數同樣不在 `railway.toml` 裡。

**對策**：
- 用 `builder = "DOCKERFILE"` 從本 repo 建薄封裝映像；「用哪個上游版本」就變成 repo 內 Dockerfile 的 `ARG`——**版本控管回到 Git，而不是散在 Railway UI 裡**。這也是選擇薄封裝而非直接 image source 的第二個理由。
- Volume、變數、domain 用 `railway` CLI 或 dashboard 建立，並在 `04` 文件中逐項列出，讓它可重現。

---

## 8. 首次互動式設定

**規則**：`railway ssh` 可以在執行中的 service 容器內開互動 shell（`railway ssh` 或從 dashboard 右鍵複製 SSH 指令）。

**衝突**：`hermes setup` 是互動式精靈，Railway 上沒有 `docker run -it`。

**對策**：
1. 先以最小變數集部署（provider key + dashboard basic auth），讓容器起來。
2. `railway ssh` 進容器，跑 `hermes setup`（或 `hermes setup --portal` 走 Nous Portal OAuth）。設定寫進 volume 上的 `/opt/data/`，跨部署保留。
3. 之後的變更優先用 `hermes config set` 或 dashboard 的 Config 頁面——**注意 `/opt/data/.env` 會覆蓋 Railway 服務變數**（見 `01` §5）。

---

## 9. Railway 自動注入的變數（Hermes 可用）

| 變數 | 用途 |
|---|---|
| `RAILWAY_PUBLIC_DOMAIN` | 組出 `HERMES_DASHBOARD_PUBLIC_URL`（OAuth callback 需要） |
| `RAILWAY_VOLUME_MOUNT_PATH` | 驗證 volume 掛在預期位置 |
| `RAILWAY_ENVIRONMENT_NAME`, `RAILWAY_SERVICE_NAME` | 日誌 / 診斷 |
| `RAILWAY_RUN_UID` | 需由我們設為 `0` |

Hermes 自帶的 `optional-skills/mcp/mcp-oauth-remote-gateway/SKILL.md` 已經知道要在 Railway 上讀 `RAILWAY_PUBLIC_DOMAIN`，可見上游對 Railway 有基本認知。

---

## 參考來源

- [Railway Volumes](https://docs.railway.com/guides/volumes)
- [Railway Healthchecks](https://docs.railway.com/guides/healthchecks)
- [Railway Config as Code](https://docs.railway.com/reference/config-as-code)
- [Railway Plans / Resource limits](https://docs.railway.com/reference/pricing/plans)
- [Railway Build and Start Commands](https://docs.railway.com/builds/build-and-start-commands)
- [Railway Set a Start Command](https://docs.railway.com/deployments/start-command)
- [Railway Dockerfiles](https://docs.railway.com/builds/dockerfiles)
- [Railway Services（Docker image 部署）](https://docs.railway.com/guides/services)
- [Railway Working with Domains](https://docs.railway.com/networking/domains/working-with-domains)
- [Railway CLI](https://docs.railway.com/guides/cli)
- [Railway Variables Reference](https://docs.railway.com/variables/reference)
