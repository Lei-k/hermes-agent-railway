# 05 — 風險、待驗證假設與驗收

依已確認決策更新（Pro 方案、fork 自建映像、OIDC、需要瀏覽器工具、純變數路徑）。

## 1. 風險清單

依「會不會擋住上線」排序。

### R1 — 容器可能拿不到 PID 1，s6 監管樹整個不啟動 🔴 高

`entrypoint-dispatch.sh` 在非 PID 1 時會走 fallback：跑完 stage2 之後直接 exec `main-wrapper.sh`，**不啟動 `/init`**。後果是 dashboard 與 per-profile gateway 這些受監管服務全部不存在——healthcheck 必然失敗。Railway 未公開文件說明是否會包一層自己的 init。

- **偵測**：deploy log 出現 `[hermes] WARNING: container entrypoint is not PID 1`
- **緩解**：改用非監管模式（CMD 改 `["gateway","run","--no-supervise"]`，放棄 dashboard），或在薄封裝映像自寫一支同時跑 gateway 與 dashboard 的 supervisor。都是相當大的架構調整，**必須在第一次部署就確認**。

### R2 — Hermes 沒有使用者白名單，Google 認證等於對全世界開門 🔴 高（安全）

`dashboard.oauth.self_hosted` 的完整設定面只有 `issuer` / `client_id` / `client_secret` / `scopes`；provider 驗完 ID token 的簽章與 `iss`/`aud`/`exp` 就直接建立 session。**沒有任何 email / group / domain 過濾。**

把 Google 當 issuer 且同意畫面是 **External** 時，**全世界任何一個 Google 帳號**走完流程都拿得到有效 session——而 dashboard 等同容器內的 shell（Hermes 工具集含 terminal 執行）。

**額外的旁路面**：bundled `self_hosted` plugin 只要 `HERMES_DASHBOARD_OIDC_ISSUER` + `_CLIENT_ID` 有值就自動註冊，而登入頁列出**所有**已註冊 provider 讓使用者挑。若白名單 provider 與 bundled provider 同時註冊，使用者可以直接點沒有白名單的那顆按鈕。

- **緩解（已採用）**：白名單放在 Auth0。三層——① Google 同意畫面設 Internal（選配，需 Workspace）② Auth0 post-login Action 比對 email + `email_verified` 後 `api.access.deny()` ③ Auth0 只掛 Google connection、Database connection 關閉。Hermes 只註冊 bundled `self_hosted` provider，改名單即時生效、不用 redeploy、不用寫 plugin。
- **驗收**：`/api/status` 的 `auth_providers` 應**只有** `["self-hosted"]`，且白名單外的帳號實測被拒。

### R2b — 代理人擁有完整 terminal 執行權 🟠 中高（安全）

Hermes 的工具集包含在容器內執行任意指令。任何通過 dashboard 驗證的人等同拿到容器內的 shell；Railway 的所有服務變數（含 `CLAUDE_CODE_OAUTH_TOKEN`、`TELEGRAM_BOT_TOKEN`、`HERMES_ALLOWLIST_*`）對代理人都可讀。

- **緩解**：R2 的白名單收斂到具名的人；api_server 維持 loopback（#5）；tool-loop 硬停止開啟；**這個容器裡不要放與 Hermes 無關的高權限憑證**。

### R3 — Claude Code 訂閱限額在常駐負載下容易撞頂 🟠 中高

訂閱是滾動時間窗限額，設計前提是互動式使用；而部署形態是常駐 gateway + Telegram 隨時進訊息 + cron 無人值守 + 學習迴圈的背景呼叫 + auxiliary task（vision/壓縮/擷取）。撞頂後代理人整段啞掉——Telegram 沒回應、cron 靜默失敗。

- **緩解**：`fallback_providers` 配一個按量計費的備援。Hermes 收到「plan/usage limit reached」型 429 會**立刻切換不重試**（因為重試也不會過）。詳見 [`06`](./06-model-provider-evaluation.md)。
- **另一面**：用訂閱憑證驅動第三方 agent 是否在 Anthropic 訂閱條款範圍內，需你自行確認。

### R4 — `.env` 覆蓋 Railway 服務變數造成設定漂移 🟠 中

`/opt/data/.env` 以 `override=True` 載入，會蓋掉平台變數。你選了「統一管在 Railway 變數」，所以任何把 key 寫進 `.env` 的動作都會破壞這個模型——而 `hermes setup`、`hermes gateway setup`、`hermes config set <API_KEY>` 都會這麼做。症狀是「改了 Railway 變數但沒作用」，很難自行察覺。

- **緩解**：`04` §2 的操作紀律寫進 repo README；用 `hermes dump` / `hermes doctor` 確認實際生效值；`API_SERVER_KEY` 是無法避免的例外（stage2 一定會自動產生），接受即可。

### R5 — fork 與上游的合併維護成本 🟠 中

fork 有自訂修改，上游幾乎每週發版（`v2026.7.1` → `v2026.8.13`）。`cli.py` 933 KB、`hermes_state.py` 583 KB、`run_agent.py` 417 KB——這些巨檔上的修改在合併時衝突機率高。

- **緩解**：修改盡量做在 plugin / skill / config 層（`/opt/data` 可寫）而非核心；核心修改保持小而集中；升級前讀上游 changelog；GHCR 上每個 commit 都有映像，回滾只是改 `HERMES_TAG`。

### R6 — GHCR private package 的 Railway 認證路徑未驗證 🟡 中低

薄封裝在 Railway build 階段拉基底映像，所以 registry credentials 必須在 build 階段可用。Railway 文件說 GHCR 要用 personal access token。

- **緩解**：先把 package 設 public（若 fork 修改可公開）；否則走 registry credentials，失敗的退路是把薄封裝那層也搬進 GitHub Actions，Railway 改純 image source 部署（但會失去 `railway.toml`，且必須設 start command `/opt/hermes/docker/entrypoint-dispatch.sh gateway run`）。

### R6b — Railway 產生的網域是第二個對外入口 🟡 中低（安全）

加了 `hermes.relvo.cc` 之後，`xxx.up.railway.app` 仍然是活的。從那個 host 登入會因 redirect_uri 不符而失敗，但它仍是可被掃描到的暴露面（`/api/health`、`/api/status` 免驗證可讀，會洩漏版本與 gateway 狀態）。

- **緩解**：確認自訂網域可用後，在 Railway 移除產生的網域。列入階段 1 驗收。

### R7 — 重新部署有停機 🟡 中低

掛了 volume 的 Railway service 無法多個 active deployment 並存。

- **接受**：這對 Hermes 反而必要——兩個 gateway 共用資料目錄會損毀 session 與 memory store。寫進維運文件即可。

### R8 — 冷開機時間可能逼近 healthcheck timeout 🟡 低

首次開機要 chown、seed、config migration、skills sync、Playwright 偵測，加上 `016-railway-bootstrap` 呼叫兩次 `hermes config set`（每次冷啟動數秒），再起 uvicorn。

- **緩解**：`healthcheckTimeout = 300`；`/api/health` 本身刻意做得很輕（避開 gateway config 與 plugin 冷載入）。

### R9 — 瀏覽器工具在 Railway 上的穩定性 🟡 低

原評估為「中低」，查證後降級：Hermes 會**自動注入** `--no-sandbox,--disable-dev-shm-usage`（文件明列 "many container images" 的偵測情境），Playwright Chromium 已烤在映像內、stage2 自動偵測路徑，且 Pro 方案記憶體充足。剩下的不確定性是自動注入在 Railway 上是否觸發（受監管服務以 `hermes` UID 執行，非 root）——`016-railway-bootstrap` 已明確補上該變數。

- **退路**：雲端瀏覽器（Browserbase / Browser Use / Firecrawl）完全避開本地資源問題；或 Lightpanda（記憶體低 16 倍）。

### 已解除的風險

- ~~volume 容量不足~~ — Pro 方案 1 TB
- ~~映像大小超限~~ — Pro 方案無限（映像 ~5 GB）
- ~~記憶體不足~~ — Pro 方案充裕
- ~~basic auth 對公網暴露~~ — 階段 1 直接上 OIDC

---

## 2. 待驗證假設

| # | 假設 | 驗證方式 |
|---|---|---|
| A1 | Railway 容器內 `entrypoint-dispatch.sh` 是 PID 1，s6 完整啟動 | deploy log 不得出現 `not PID 1`；`railway ssh` 後 `cat /proc/1/cmdline` 應含 `s6-svscan` 或 `/init` |
| A2 | 不設 start command 時，Railway 使用映像的 ENTRYPOINT + CMD | deploy log 應出現 `[stage2] Setup complete` |
| A3 | Railway volume 掛 `/opt/data` 後，stage2 的 chown 成功 | log 不得出現 `chown ... failed (rootless container?)`；`ls -ld /opt/data` 應為 `hermes:hermes` |
| A4 | `/opt/data/.env` 確實以 `override=True` 蓋掉平台環境變數 | Railway 設一個測試變數，`.env` 寫不同值，用 `hermes dump` 比對 |
| A5 | `HERMES_GATEWAY_BOOTSTRAP_STATE=running` 能讓全新 volume 首次開機就啟動 gateway | `/opt/data/logs/container-boot.log` 應有 `profile=default prior_state=running action=started` |
| A6 | `/api/health` 在驗證閘開啟時仍回 200 且不需 cookie | `curl -i https://<domain>/api/health` |
| A7 | Railway healthcheck 的 `healthcheck.railway.app` Host 標頭不會被 dashboard 拒絕 | deploy 是否通過 healthcheck；失敗時 log 顯示 400 / service unavailable |
| A8 | Dashboard Chat 分頁的 WebSocket (`/api/pty`) 能通過 Railway proxy | 開 Chat 分頁實際對話 |
| A9 | fork 映像未壓縮大小（預期 ~5 GB） | 本機 `docker pull` + `docker images` |
| A10 | `016-railway-bootstrap` 寫入 `/run/s6/container_environment/` 的變數，dashboard 服務讀得到 | `railway ssh` 檢查 dashboard 實際綁的埠 |
| A11 | `hermes config set` 可在 cont-init（root，經 exec shim 降權）環境下正常執行且不過慢 | 首次開機後 `hermes config get model`；量測開機時間 |
| A12 | 掛 volume 時 Railway 不會出現兩個 active deployment 並存 | 觀察一次重新部署 |
| ~~A13~~ | ~~IdP 需 public + PKCE client~~ — **已解除**：原始碼確認 confidential client（PKCE + `client_secret`）也支援，Google Web application client 可直接用 | — |
| **A14** | 瀏覽器工具在 Railway 上可用（`AGENT_BROWSER_ARGS` 補上後） | 讓代理人跑 `browser_navigate` + `browser_snapshot` |
| **A15** | GHCR private package 的 Railway registry credentials 在 **build** 階段可用 | 薄封裝建置能成功拉到基底映像 |
| **A16** | `agent-browser` CLI 的 `npx` 解析路徑在唯讀 `/opt/hermes` + `HERMES_DISABLE_LAZY_INSTALLS=1` 下可運作 | 首次瀏覽器工具呼叫是否成功；npm cache 應落在 `/opt/data` |
| **A17** | `CLAUDE_CODE_OAUTH_TOKEN` 單獨作為環境變數（無 Claude Code credential 檔）能驅動 `provider: anthropic` | `hermes doctor`；實際跑一輪對話 |
| ~~A18~~ | ~~自寫 plugin 的簽章正確性~~ — **不適用**：已決定走 Auth0，不寫 plugin | — |
| ~~A19~~ | ~~自寫 plugin 的錯誤呈現~~ — **不適用** | — |
| **A24** | Auth0 的 issuer（`https://<tenant>.<region>.auth0.com/`，含尾斜線）能被 Hermes `self_hosted` provider 正確 discovery 與 ID token 驗證 | 完成一次登入；`GET /api/auth/me` 回傳 `provider: self-hosted` |
| **A25** | *(選配)* 加 `offline_access` scope 後 Auth0 發出 refresh token，Hermes 的靜默續期可運作 | 等 ID token 過期（Auth0 預設 10h）後仍不需重新登入 |
| **A20** | *(僅採 CLIProxyAPI 時)* CLIProxyAPI 綁定能被 Railway 私有網路（IPv6）連到 | Hermes 容器內 `curl http://cliproxy.railway.internal:8317/...` |
| **A21** | *(僅採 CLIProxyAPI 時)* 經過中介層後 function calling 與串流的保真度 | 讓代理人跑一輪含多次工具呼叫的任務 |
| **A22** | 加了自訂網域 `hermes.relvo.cc` 後 `RAILWAY_PUBLIC_DOMAIN` 的取值（文件未說明） | `railway ssh` → `echo $RAILWAY_PUBLIC_DOMAIN`。**不論結果為何都應明確設 `HERMES_DASHBOARD_PUBLIC_URL`**，此項只為釐清行為 |
| ~~A23~~ | ~~Cloudflare Access 的 OIDC SaaS app~~ — **不適用**：`relvo.cc` 不在 Cloudflare，該路線需搬 nameserver，已捨棄 | — |

---

## 3. 驗收檢查表

### 階段 0：fork 映像流水線
- [ ] `fork-image.yml` 成功推出 `ghcr.io/lei-k/hermes-agent:<sha>`
- [ ] 本機 `docker run --rm <image> version` 可執行
- [ ] 量測未壓縮映像大小 → **A9**
- [ ] package 可見性已決定；private 的話 Railway registry credentials 已設 → **A15**

### 階段 1：容器落地
- [ ] Google OAuth client 已建立（consent screen = Internal），redirect URI = `https://<domain>/auth/callback`
- [ ] `HERMES_ALLOWLIST_*` 已設；`HERMES_DASHBOARD_OIDC_*` 確認**未設**
- [ ] Railway build 成功（薄封裝，應在 1 分鐘內）
- [ ] Deploy log 無 `not PID 1` 警告 → **A1**
- [ ] Deploy log 有 `[stage2] Setup complete; starting user services` → **A2**
- [ ] Deploy log 有 `[railway] bootstrap complete`
- [ ] Healthcheck 通過 → **A6 / A7**
- [ ] `curl -s https://<domain>/api/status | jq '.auth_providers'` → **只有** `["allowlist-oidc"]`（兩個 = 旁路，必須修）→ **A18**
- [ ] `hermes.relvo.cc` CNAME + TXT 已設、憑證已簽發、`HERMES_DASHBOARD_PUBLIC_URL` 已明確設定 → **A22**
- [ ] Railway 產生的 `*.up.railway.app` 網域已移除
- [ ] 白名單內的 Google 帳號可登入；`GET /api/auth/me` 回傳該身分
- [ ] **白名單外的 Google 帳號被拒**，且錯誤訊息可讀 → **A19**
- [ ] `railway ssh` → `ls -ld /opt/data` 為 `hermes:hermes` → **A3**
- [ ] `/opt/data/logs/container-boot.log` 顯示 gateway 已啟動 → **A5**
- [ ] `hermes config get model` 顯示 `HERMES_BOOTSTRAP_MODEL` 的值 → **A11**
- [ ] Dashboard Status 頁顯示 gateway running

### 階段 2：代理人可用
- [ ] 實際跑一輪對話，確認 Claude Code 憑證生效 → **A17**
- [ ] Dashboard Chat 分頁可正常來回對話 → **A8**
- [ ] Telegram 收發正常
- [ ] `browser_navigate` + `browser_snapshot` 可用 → **A14 / A16**
- [ ] `fallback_providers` 已設定；模擬限額確認會切換
- [ ] 在 Railway 改一個變數 → redeploy → 確認生效（而非被 `.env` 遮蔽）→ **A4**
- [ ] `railway redeploy` 後 session 歷史、memories、skills、config 全部保留 → **A12**
- [ ] `hermes doctor` 全綠或僅剩已知可接受的警告

### 階段 3：安全
- [ ] Auth0 post-login Action 的白名單只含應有的人，且有檢查 `email_verified`
- [ ] Google OAuth client 的 redirect URI 是 Auth0 的 `/login/callback`，不是 Hermes 的
- [ ] Auth0 的 Database connection 已關閉（否則可自助註冊帳號）
- [ ] 演練一次「從 Action 移除某人 → 該人立刻被拒」（不需 redeploy）
- [ ] Auth0 的 MFA / 暴力破解防護已開啟
- [ ] api_server 確認不可從公網到達
- [ ] `tool_loop_guardrails.hard_stop_enabled: true` 已生效
- [ ] Railway 密鑰變數皆標記 sealed
- [ ] 確認容器內沒有與 Hermes 無關的高權限憑證

### 階段 4：維運
- [ ] 完成一次上游同步演練（merge upstream → CI 建置 → 改 `HERMES_TAG` → redeploy → 驗版本與資料）
- [ ] 完成一次回滾演練（`HERMES_TAG` 改回舊 sha）
- [ ] 外部 uptime 監控已接上 `/api/health`
- [ ] 備份流程已實測可還原

---

## 4. 維運手冊（Runbook）

| 症狀 | 檢查順序 |
|---|---|
| Healthcheck 失敗 | ① log 有無 `not PID 1` ② 有無 dashboard fail-closed 的驗證錯誤 ③ `PORT` 與 `HERMES_DASHBOARD_PORT` 是否一致 ④ `HERMES_DASHBOARD=1` 是否有設 |
| Dashboard 拒絕啟動並列出 provider 問題 | 沒有註冊任何驗證 provider。檢查 `HERMES_DASHBOARD_OIDC_ISSUER` 是否能取到 discovery document |
| OIDC 登入後 callback 失敗 / `redirect_uri_mismatch` | `HERMES_DASHBOARD_PUBLIC_URL` 是否等於 `https://hermes.relvo.cc`（自訂網域下不能靠 `RAILWAY_PUBLIC_DOMAIN` 推導）；IdP 註冊的 redirect URI 是否完全一致 |
| 自訂網域回 404 | TXT 記錄漏了（只加 CNAME 不會驗證通過）；或憑證還在簽發中 |
| 走 Cloudflare 時憑證簽不出來 / 重導迴圈 | `_acme-challenge` 記錄要關閉 proxy；SSL/TLS 模式設 Full (strict) |
| 登入頁出現兩個 provider 按鈕 | 🔴 白名單旁路。`HERMES_DASHBOARD_OIDC_ISSUER`/`_CLIENT_ID` 被誤設了，清掉並 redeploy |
| 該進的人被拒 | Auth0 Action 的 email 清單是否與 Google 帳號的 email 完全一致（小寫比對）；`email_verified` 是否為 true |
| 代理人不回訊息 | ① dashboard Status 頁看 gateway 狀態 ② `hermes gateway status` ③ `tail -F /opt/data/logs/gateways/default/current` ④ 確認 `HERMES_GATEWAY_BOOTSTRAP_STATE=running` ⑤ 是否撞 Claude Code 限額（看有無切到 fallback） |
| 改了 Railway 變數沒作用 | `/opt/data/.env` 裡有同名 key（`override=True`）。檢查是否誤跑過 `hermes setup` |
| Permission denied / EACCES | `RAILWAY_RUN_UID=0` 是否設；stage2 的 chown 是否失敗 |
| 瀏覽器工具失敗 | ① `AGENT_BROWSER_ARGS` 是否含兩個 flag ② `AGENT_BROWSER_EXECUTABLE_PATH` 是否被 stage2 設好 ③ 切雲端瀏覽器 |
| Volume 快滿 | `du -sh /opt/data/*`；清理舊 session；Pro 可 live resize |
| 升級後行為異常 | `/opt/data` 內有 migration 前的時間戳備份；`HERMES_TAG` 改回舊 sha 並 redeploy |

日誌位置速查：
- Railway deploy logs = 容器 stdout（gateway + dashboard 交錯）
- `/opt/data/logs/gateways/<profile>/current` — 跨重啟保留的 gateway 日誌（輪替 10×1MB）
- `/opt/data/logs/container-boot.log` — 每次開機的 profile 還原稽核
- `hermes logs --follow [--level WARNING]` — 一般 Hermes 日誌

---

## 5. 未納入本計畫的範圍

- **Docker terminal backend / DooD**。Railway 沒有 Docker daemon。要沙箱化就得用遠端後端（SSH / Modal / Daytona / Vercel Sandbox）。
- **api_server 對外**。依 #5 決策排除。要開需加第二個 custom domain 並重做安全設計（見 `03` 階段 3）。
- **Telegram webhook 模式**。依 #4 決策用 polling。
- **Hermes Desktop 遠端連線**。技術上可行（Desktop 的 Remote Gateway 連的就是 dashboard），但需確認它能走自訂的 allowlist provider。
- **CLIProxyAPI 第二個 service**。僅在確定要池化多家 CLI 訂閱時才納入，見 [`06`](./06-model-provider-evaluation.md) §4。
- **多 region / 水平擴充**。Hermes 的資料模型不支援。
- **Scale-to-zero**。掛 volume 的 service 不適用；polling 模式的平台連線也需要常駐。
