# hermes-agent-railway

把 [Hermes Agent](https://github.com/NousResearch/hermes-agent)（fork：[`Lei-k/hermes-agent`](https://github.com/Lei-k/hermes-agent)）部署到 Railway 的薄封裝與操作手冊。

完整的設計依據、平台限制分析與風險評估在 [`plan/`](./plan/)。這份 README 是操作手冊。

---

## 用途 / 適合誰 / 能得到什麼

**用途**：在 Railway 上長時間跑一個 Hermes Agent（gateway + Telegram polling + web dashboard），憑上游官方預建映像加一層薄封裝，不需自建或修改 fork 的原始碼。

**適合誰**：

- 需要無人值守、常駐執行的 Hermes 部署，且能自行完成 Auth0 tenant、Google OAuth client、DNS 記錄設定的人。
- 能接受「dashboard 等同容器內的 shell、任何通過驗證的人都能執行任意指令」這個風險模型的人（見「安全與憑證」）。

**不適合誰**：只想臨時試用、不打算設定 Auth0 白名單的人——沒有白名單，Google 認證等於對全世界開門。

**能得到什麼**：一份釘住上游版本的 `Dockerfile`、`railway.toml`、Railway 專用開機 hook、Auth0 白名單設定步驟、部署後驗收清單、故障排除表。**得不到什麼**：任何已完成的雲端資源、憑證，或「照做就一定成功」的保證——見下一節。

---

## 驗證狀態與重要未驗證假設

這是一份**部署前撰寫**的操作手冊：本 repo 內沒有任何一次實際部署的 log 或結果記錄，文中的步驟與變數尚未被本 repo 記錄為在你的環境中跑通過。

最關鍵、**必須在你自己第一次部署時立刻用 deploy log 確認**的假設：

- **容器內是否真的拿到 PID 1**（`plan/05` §2 A1）：`entrypoint-dispatch.sh` 在非 PID 1 時會走 fallback，直接 exec 主程式、**不啟動 s6 監管樹**——dashboard 與受監管的 gateway 服務會全部不存在，healthcheck 必然失敗。Railway 官方文件未說明是否會包一層自己的 init。偵測方式：deploy log **不可**出現 `WARNING: container entrypoint is not PID 1`。

其餘標記為風險等級的假設（瀏覽器工具穩定性、`.env` 覆蓋行為、config bootstrap 的重試邏輯等）與完整驗證方式列在 [`plan/05`](./plan/05-risks-and-verification.md) §1–2；本 README 後續只保留會直接擋住上線或涉及安全的部分。

---

## 部署前置

### Auth0（必須在部署前完成）

沒有任何 auth provider 註冊時，dashboard 在非 loopback bind 下會 **fail closed、直接拒絕啟動**，healthcheck 必然失敗。完整步驟見 [`plan/07`](./plan/07-dashboard-access-control.md) §5，摘要如下：

1. 建 tenant，記下 `<tenant>.<region>.auth0.com`（就是 OIDC issuer，不需另購自訂網域）。
2. Authentication → Social → **Google connection**。
3. Applications → Create Application（**Regular Web Application**）：
   - Allowed Callback URLs = `https://<your-domain>/auth/callback`
   - Connections 分頁**只勾 Google**，關閉 Database connection
4. Actions → post-login trigger，加白名單並 Apply：
   ```javascript
   exports.onExecutePostLogin = async (event, api) => {
     const allowed = ['you@your-company.example'];
     const email = (event.user.email || '').toLowerCase();
     if (!event.user.email_verified || !allowed.includes(email)) {
       api.access.deny('Not authorized for this application.');
     }
   };
   ```
   （`allowed` 填實際要放行的帳號。本 repo 公開，文件一律只放佔位符。）

> **`email_verified` 的檢查與關閉 Database connection 是同一個攻擊面的兩道保險，兩個都要做。** 白名單只比對 email，而自助註冊的 email 是使用者自己填的。

**兩層 OAuth，憑證別填錯層**

```
瀏覽器 ──①──> Hermes dashboard ──②──> Auth0 ──③──> Google
                                  ↑              ↑
                        這層憑證填 Railway   這層憑證填 Auth0 UI
```

| 憑證 | 從哪拿 | 填到哪 | 該層的 redirect URI |
|---|---|---|---|
| **Auth0 Application** 的 Client ID / Secret | Auth0 → Applications → 你的 App → **Settings** → Basic Information | **Railway 變數** `HERMES_DASHBOARD_OIDC_CLIENT_ID` / `_CLIENT_SECRET` | Auth0 的 Allowed Callback URLs = `https://<your-domain>/auth/callback` |
| **Google OAuth client** 的 Client ID / Secret | Google Cloud Console → Credentials | **Auth0 UI** → Authentication → Social → Google connection | Google 的 Authorized redirect URI = `https://<tenant>.<region>.auth0.com/login/callback` |

**Google 那組不會進 Railway。** Hermes 只認 Auth0，不知道背後是 Google 還是別的 IdP。

`HERMES_DASHBOARD_OIDC_ISSUER` 取自同一頁的 **Domain** 欄位（如 `dev-ab12cd.us.auth0.com`），自己補上 `https://` 與尾斜線。驗證：

```bash
curl -s https://<tenant>.<region>.auth0.com/.well-known/openid-configuration | jq '.issuer'
# 回傳的字串就是要填的值；拿不到東西表示 Domain 抄錯
```

> Application 型別建成 **Single Page Application** 的話不會有 Client Secret（public + PKCE），`HERMES_DASHBOARD_OIDC_CLIENT_SECRET` 留空不設即可 —— Hermes 兩種都支援。

### 其他前置

- 一個你能加 CNAME + TXT 記錄的網域（本文用 `<your-domain>` 代稱，範例中出現的 `hermes.relvo.cc` 只是佔位範例，請換成你自己的網域）。
- 本機執行 `claude setup-token` 產生的 `CLAUDE_CODE_OAUTH_TOKEN`，或其他 model provider 的 API key。

---

## 最短 Railway 部署

repo 已在 GitHub 上，用連接 GitHub 的方式部署最順 —— 之後 `git push` 就會依 `railway.toml` 自動重建（剛好對上升級流程：改 `HERMES_TAG` → push → 完成）。

### 1. 建立 service

[railway.com](https://railway.com) → **New Project** → **Deploy from GitHub repo** → 選 `Lei-k/hermes-agent-railway`。

Railway 會讀到 `railway.toml`，自動用 `builder = "DOCKERFILE"`。**第一次部署會失敗是正常的** —— 變數還沒設，dashboard 因為找不到 auth provider 而 fail closed。

> ⚠️ **Settings → Deploy → Custom Start Command 必須留空。** 它會以 exec form **覆蓋映像的 ENTRYPOINT**，而 `entrypoint-dispatch.sh` 承載整條 s6 bootstrap（volume chown、`.env`/`config.yaml` 首次 seed、config schema migration、監管樹）。指令已烤進 `Dockerfile` 的 `CMD`，留空即可。

### 2. 加 Volume

服務上按 `⌘K` / 右鍵 → **Add Volume**，mount path 填 **`/opt/data`**。

必須在第一次成功開機前加好，否則資料會落在 ephemeral 磁碟，重新部署就消失。

### 3. 設變數

**Variables → Raw Editor**，一次貼上（值請換成真實的）：

```bash
RAILWAY_RUN_UID=0
PORT=9119
HERMES_DASHBOARD=1
HERMES_DASHBOARD_HOST=0.0.0.0
HERMES_DASHBOARD_PORT=9119
HERMES_TIMEZONE=Asia/Taipei
HERMES_GATEWAY_BOOTSTRAP_STATE=running
HERMES_DASHBOARD_PUBLIC_URL=https://<your-domain>
HERMES_DASHBOARD_OIDC_ISSUER=https://<tenant>.<region>.auth0.com/
HERMES_DASHBOARD_OIDC_CLIENT_ID=<auth0 client id>
HERMES_DASHBOARD_OIDC_CLIENT_SECRET=<auth0 client secret>
CLAUDE_CODE_OAUTH_TOKEN=<claude setup-token 產生>
HERMES_BOOTSTRAP_MODEL=anthropic/<claude-model-id>
HERMES_BOOTSTRAP_TERMINAL_BACKEND=local
HERMES_BOOTSTRAP_CONFIG=tool_loop_guardrails.hard_stop_enabled=true; tool_loop_guardrails.hard_stop_after.exact_failure=5
TELEGRAM_BOT_TOKEN=<選配>
OPENROUTER_API_KEY=<選配，備援 provider>
```

各變數的作用與注意事項見 [`.env.railway.example`](./.env.railway.example) 與 [`plan/04`](./plan/04-configuration-reference.md)。

### 4. 掛自訂網域

**Settings → Networking → Custom Domain** → 填入 `<your-domain>`，**target port 選 9119**。

依 Railway 給的值加 **CNAME + TXT 兩筆** DNS 記錄 —— 只加 CNAME 不會驗證通過（會回 404）。等 Let's Encrypt 憑證簽發（Railway 通常在一小時內完成，實際時間以你觀察到的為準）。

確認可用後**把 Railway 自動產生的 `*.up.railway.app` 網域移除** —— 留著等於 dashboard 有第二個對外入口，且 `/api/health`、`/api/status` 免驗證可讀，會洩漏版本與 gateway 狀態。

### 5. 重新部署

變數設好後 **Deployments → Redeploy**。

<details>
<summary>替代路徑：用 railway CLI</summary>

```bash
npm i -g @railway/cli
cp .env.railway.example .env.railway   # 填入真實值
railway login
railway link
./scripts/provision.sh                 # 預覽
./scripts/provision.sh --apply         # 執行
```

CLI 路徑不會自動連 GitHub，之後升級要手動 `railway up`。
</details>

---

## 部署後驗收

```bash
curl -s https://<your-domain>/api/health
curl -s https://<your-domain>/api/status | jq '.auth_required, .auth_providers'
#   → true / ["self-hosted"]   出現第二個 provider 就要查
```

Deploy log 檢查：

- **不可**出現 `WARNING: container entrypoint is not PID 1` — 出現代表 s6 監管樹沒起來，dashboard 不存在，對應「驗證狀態」一節的 A1
- 應出現 `[stage2] Setup complete; starting user services`
- 應出現 `[railway] bootstrap complete`

登入測試：白名單內的 Google 帳號可進；**白名單外的帳號要實測被拒**，應看到 `400 OAuth error from provider: access_denied (...)`。

以上步驟就是目前採用 Auth0 self-hosted OIDC 設計的驗收清單。**不要照 `plan/05-risks-and-verification.md` §3 的舊 `HERMES_ALLOWLIST_*`／`allowlist-oidc` 清單操作**：那是已放棄的 plugin 方案，現有 Dockerfile 沒有安裝該 plugin，且會要求移除本 README 使用的 `HERMES_DASHBOARD_OIDC_*`。

---

## 安全與憑證

### 存取控制的攻擊面

Hermes 本身**沒有使用者白名單** —— OIDC provider 只驗簽章與 `iss`/`aud`/`exp` 就建立 session，沒有 email/group/domain 過濾。白名單完全靠 Auth0 這一層（「部署前置」一節的 post-login Action + 關閉 Database connection）撐住；兩者缺一，任何一個 Google 帳號都能取得有效 session。

**dashboard 等同容器內的 shell**：Hermes 的工具集含 terminal 執行，任何通過驗證的人都能在容器內跑任意指令，也能讀到 Railway 的所有服務變數（含 `CLAUDE_CODE_OAUTH_TOKEN`、`TELEGRAM_BOT_TOKEN`）。因此：

- 白名單只收斂到具名、信任的人
- 這個容器裡不要放與 Hermes 無關的高權限憑證
- `api_server`（`127.0.0.1:8642`，工具集含 terminal 執行）維持 loopback，不對外開放
- `tool_loop_guardrails.hard_stop_enabled` 建議開啟（見「最短部署」的 `HERMES_BOOTSTRAP_CONFIG`），作為重複失敗／無進展工具迴圈的 defense in depth。它**不是一般 shell containment**：不會阻止單次任意命令，也不會停止持續有進展、每次命令都不同的序列。

### 憑證管理紀律

`$HERMES_HOME/.env` 是以 `override=True` 載入的（`hermes_cli/env_loader.py:500`），**會蓋掉 Railway 注入的環境變數**。憑證統一管在 Railway 變數，所以：

- **不要跑 `hermes setup`** — 它會把 API key 寫進 `.env`，從此同名的 Railway 變數永久失效
- **不要用 `hermes config set <某個 API_KEY>`** — 同樣路由到 `.env`
- `hermes config set` 只用於非憑證設定（`model`、`terminal.backend`、`tool_loop_guardrails`…）

唯一無解的例外是 `API_SERVER_KEY`：`stage2-hook.sh` 在 `.env` 缺它時一定會自動產生一組寫入。因為 api_server 維持 loopback、不對外可達，接受即可。

症狀是「改了 Railway 變數但沒作用」時，先查 `/opt/data/.env` 有沒有同名 key。

---

## 架構與薄封裝

```
        nousresearch/hermes-agent:v2026.8.13   （上游官方預建映像）
                         │ FROM（本 repo 的薄封裝：只有 COPY 與設定 CMD，不含編譯步驟）
┌─ Railway Service (1 replica) ─────────────────────────────┐
│  ENTRYPOINT: entrypoint-dispatch.sh → /init (s6, PID 1)   │
│                                                            │
│   cont-init.d:  01-hermes-setup      chown / seed / migrate│
│                 015-supervise-perms                        │
│                 016-railway-bootstrap ← 本 repo            │
│                 02-reconcile-profiles 拉起 gateway slot     │
│                                                            │
│   s6 服務:  gateway-default   代理人本體、Telegram polling  │
│             dashboard         0.0.0.0:$PORT ⇢ 對外          │
│   CMD:      gateway run       容器主程式（心跳）            │
│   loopback: api_server 127.0.0.1:8642（不對外）             │
└──────────┬─────────────────────────────────────────────────┘
           │ Volume
      /opt/data   config.yaml / .env / sessions / memories / skills / cron
           │
     https://<your-domain>  ←  Auth0（Google）驗證閘
```

**為什麼用上游預建映像**：`Lei-k/hermes-agent` 目前與 upstream 零分歧（`behind_by=0`，沒有任何自己的 commit），自建一份沒有意義 —— 上游 Dockerfile 冷建置要編 SQLite、抓 s6-overlay、裝 Playwright、`uv sync` 八個 extras、建兩個前端，上游自己把該 job 的 timeout 設在 45 分鐘、映像 5GB+。直接用官方發布的版本標籤，**fork repo 完全不用動**，Railway 端薄封裝沒有額外編譯或 dependency-install layer；但冷建置仍要拉取釘選的 amd64 base image（目前壓縮後約 949 MB），不能解讀為沒有大型網路傳輸。

多數客製化也不需要 fork —— 見下方「客製化」。

**為什麼 Railway 的 start command 必須留空**：見「最短 Railway 部署」步驟 1 的說明。

### 檔案

| 路徑 | 用途 |
|---|---|
| `Dockerfile` | 薄封裝：釘住上游版本、塞入開機 hook、烤入 `CMD` |
| `railway.toml` | builder / healthcheck / restart policy |
| `docker/cont-init.d/016-railway-bootstrap` | Railway 專用開機 hook（埠對齊、公開網址、瀏覽器旗標、首次 config bootstrap） |
| `.env.railway.example` | Railway 服務變數範本 |
| `scripts/provision.sh` | 用 railway CLI 建 volume / 變數 / 網域 |
| `plan/` | 設計文件（8 份） |

`railway.toml` 裡另外釘住的兩個運維參數：`healthcheckTimeout = 300`（冷開機要跑 chown、seed、config migration、skills sync、Playwright 路徑偵測；300 秒是 Railway 目前的**預設值**，平台允許再提高，不是上限）、`drainingSeconds = 30`（給 s6 時間把 gateway 收乾淨、讓 SQLite 完成 WAL checkpoint）。

---

## 客製化 / 升級 / 回滾 / 故障排除

### 客製化

**不需要 fork。** 幾乎所有客製化都能疊在這一層薄封裝上，因為 Railway 建置時是 root，可以往映像裡寫任何東西：

| 想改什麼 | 做法 | 放哪 |
|---|---|---|
| Dashboard auth provider | `COPY` 進 `/opt/hermes/plugins/dashboard_auth/<name>/` | 映像（root-only，代理人改不動） |
| 自訂 plugin | `COPY` 進 `/opt/hermes/plugins/` | 映像 |
| 自訂 skill | `COPY` 進 `/opt/hermes/skills/`（開機時 `skills_sync.py` 會同步） | 映像 |
| SOUL.md 人格 | `COPY` 覆蓋 `/opt/hermes/docker/SOUL.md`（首次開機 seed 用） | 映像 |
| config 預設值 | `HERMES_BOOTSTRAP_CONFIG` 環境變數，或 `COPY` 覆蓋 `/opt/hermes/cli-config.yaml.example` | 變數／映像 |
| 系統套件 | `RUN apt-get update && apt-get install -y ...` | 映像 |
| Python 套件 | `RUN uv pip install --python /opt/hermes/.venv/bin/python ...`（上游以 `uv sync` 建 venv，不保證內含 `pip`） | 映像 |
| npm 工具 | `RUN npm i -g ...` | 映像 |
| 執行期才要的可選後端 | `HERMES_LAZY_INSTALL_TARGET=/opt/data/lazy-packages`（已預設） | volume |

**只有改 Hermes 核心原始碼**（`cli.py`、`run_agent.py`、`hermes_state.py`、agent loop⋯）才真的需要自建映像。屆時有兩條路：

1. **小修補**：在薄封裝裡 `COPY patches/xxx.py /opt/hermes/xxx.py` 覆蓋單一檔案。editable install 指向 `/opt/hermes`，所以直接生效。跨版本升級時容易失效，適合臨時修補。
2. **完整自建**：把建置流水線放在 **本 repo** 的 GitHub Actions（checkout `Lei-k/hermes-agent` 為第二個 source，建好推 GHCR），`Dockerfile` 改指向那個映像。**fork repo 依然不用動。** 完整 workflow 見 [`plan/03`](./plan/03-implementation-plan.md) 附錄。

### 升級與回滾

上游大約每週發一個版本標籤（`v2026.7.1` → `v2026.8.13`，依 Dockerfile 內記錄的標籤觀察）。升級只有一步：

```bash
# 看有哪些版本：https://hub.docker.com/r/nousresearch/hermes-agent/tags
# 改 Dockerfile 的 ARG HERMES_TAG，commit + push，Railway 會依 railway.toml 自動重建
```

也可以在 Railway service variables 設 `HERMES_TAG` 覆寫，升級時連程式碼都不用動。

開機時 `stage2-hook.sh` 會自動跑 `docker_config_migrate.py`，需要時把 `config.yaml`/`.env` 備份成時間戳檔案。

**回滾**：`HERMES_TAG` 改回舊標籤即可 —— Docker Hub 上舊版本都還在。

掛了 volume 的 service 重新部署會有短暫停機（Railway 平台限制：多個 active deployment 無法同時掛同一顆 volume）。這對 Hermes 反而是必要的 —— 兩個 gateway 共用資料目錄會損毀 session 與 memory store。

### 修改白名單與緊急撤權

編輯 Auth0 post-login Action 會阻止該使用者**下一次登入或 token refresh**，不需要重新部署 Hermes；但它不會撤銷瀏覽器手上尚未過期的 ID token。Hermes 會在每個 request 本機驗證既有 token 的簽章與 `iss`／`aud`／`exp`，因此已登入者可持續存取到該 token 的 `exp`（Auth0 常見預設約 10 小時，實際值以 tenant/token 為準）。

需要立即把既有 session 全部踢下線時，採 fail-closed 的 audience rotation：先在 Auth0 建立一個新的 Regular Web Application、設定同一 callback 與 Google connection，確認 post-login Action 白名單已移除該帳號，再把 Railway 的 `HERMES_DASHBOARD_OIDC_CLIENT_ID`／`_CLIENT_SECRET` 換成新 Application 並 redeploy。舊 ID token 的 `aud` 不再符合新 client ID，所有人都必須重新登入。此程序是全體 session eviction，不是單一使用者的細粒度撤銷；部署完成後要重跑白名單內／外登入驗收。

### 日誌

| 來源 | 位置 |
|---|---|
| gateway + dashboard | Railway deploy logs（容器 stdout，兩者交錯） |
| gateway（跨重啟保留、輪替 10×1MB） | `/opt/data/logs/gateways/default/current` |
| 每次開機的 profile 還原稽核 | `/opt/data/logs/container-boot.log` |
| 一般 Hermes 日誌 | `railway ssh` → `hermes logs --follow [--level WARNING]` |

### 常見問題

| 症狀 | 檢查 |
|---|---|
| Healthcheck 失敗 | ① log 有無 `not PID 1` ② dashboard 是否 fail-closed（缺 auth provider）③ `PORT` 與 `HERMES_DASHBOARD_PORT` 是否一致 |
| `redirect_uri_mismatch` | `HERMES_DASHBOARD_PUBLIC_URL` 是否等於 `https://<your-domain>`；與 Auth0 的 Allowed Callback URLs 是否完全一致 |
| `no auth providers are registered`（dashboard 拒絕啟動） | `HERMES_DASHBOARD_OIDC_ISSUER` + `_CLIENT_ID` 是否真的到得了容器（`railway ssh` → `env \| grep OIDC`）。**錯誤訊息只會回報 `nous` plugin 的 skip 原因，不會提到 self-hosted OIDC** —— 訊息沒列出它不代表不支援 |
| 填了 Google 的 client id 卻登入失敗 | 填錯層了。Railway 變數要填 **Auth0 Application** 的憑證；Google 那組填在 Auth0 的 Google connection 裡 |
| 自訂網域回 404 | TXT 記錄漏了，或憑證還在簽發 |
| 登入頁出現兩個 provider | 有多餘的 auth provider 註冊了 —— 檢查是否誤設 `HERMES_ALLOWLIST_*` 或其他 provider 的變數 |
| 代理人不回訊息 | ① dashboard Status 頁的 gateway 狀態 ② `hermes gateway status` ③ `HERMES_GATEWAY_BOOTSTRAP_STATE=running` 是否有設 ④ 是否撞 Claude Code 訂閱限額 |
| Permission denied / EACCES | `RAILWAY_RUN_UID=0` 是否設 |
| 該進的人被拒 | Auth0 Action 的 email 清單是否完全一致（小寫比對）；`email_verified` 是否為 true |

完整 runbook 在 [`plan/05`](./plan/05-risks-and-verification.md) §4。

### 尚未決定 / 未實作

- **CLIProxyAPI**：只有 Claude Code 一家訂閱的話不需要（Hermes 原生支援 `CLAUDE_CODE_OAUTH_TOKEN`）。要池化多家 CLI 訂閱才值得加第二個 Railway service。分析見 [`plan/06`](./plan/06-model-provider-evaluation.md)。
- **`fallback_providers`**：住在 `config.yaml`，是 list 結構，`hermes config set` 的點分語法不適用。目前需 `railway ssh` 手動設一次。強烈建議設 —— Claude Code 訂閱是滾動時間窗限額，而這是無人值守負載，撞頂後代理人會整段啞掉。
- **待驗證假設**：完整清單見 [`plan/05`](./plan/05-risks-and-verification.md) §2，其中「驗證狀態與重要未驗證假設」一節列出的 A1（容器是否拿得到 PID 1）最關鍵，第一次部署就要從 log 確認。
