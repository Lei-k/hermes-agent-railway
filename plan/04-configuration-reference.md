# 04 — 設定參考

依已確認決策撰寫：fork 自建映像、Pro 方案、OIDC 驗證、Telegram polling、api_server 不對外、需要瀏覽器工具、Claude Code provider、**憑證統一管在 Railway 變數**。

---

## 1. Railway 服務變數

### 1.1 必填 — 啟動

| 變數 | 值 | 為什麼 |
|---|---|---|
| `RAILWAY_RUN_UID` | `0` | Railway volume 以 root 掛載；Hermes 的 `stage2-hook.sh` 需要 root 才能做 UID remap 與 chown，之後每個受監管服務再用 `s6-setuidgid` 降權到 `hermes`(UID 10000) |
| `PORT` | `9119` | Railway 用它決定 healthcheck 與 domain 的目標埠 |
| `HERMES_DASHBOARD` | `1` | 啟用受 s6 監管的 dashboard 服務（未設時該 slot 會以 exit 125 標記為永久失敗） |
| `HERMES_DASHBOARD_HOST` | `0.0.0.0` | 讓 Railway proxy 連得到 |
| `HERMES_DASHBOARD_PORT` | `9119` | 與 `PORT` 一致 |
| `HERMES_GATEWAY_BOOTSTRAP_STATE` | `running` | **全新 volume 上不設這個，gateway 不會自動啟動**。stage2 據此寫下首次的 `gateway_state.json`，`02-reconcile-profiles` 才會拉起 s6 slot |

### 1.2 必填 — Dashboard 驗證（Google 登入 + 白名單）

非 loopback 綁定會強制開啟驗證閘；沒有任何 provider 註冊時 dashboard **fail closed，直接拒絕啟動**。

**Hermes 沒有內建使用者白名單**，必須在 IdP 端處理。**已決定用 Auth0**（Google 當 social connection，白名單寫成 post-login Action）。設定步驟見 [`07`](./07-dashboard-access-control.md) §5。

| 變數 | 說明 |
|---|---|
| `HERMES_DASHBOARD_OIDC_ISSUER` | `https://<tenant>.<region>.auth0.com/`（不需另購 Auth0 自訂網域） |
| `HERMES_DASHBOARD_OIDC_CLIENT_ID` | Auth0 Application 的 client id |
| `HERMES_DASHBOARD_OIDC_CLIENT_SECRET` | Regular Web Application 才需要；SPA（public + PKCE）不需要。**兩種 Hermes 都支援** |
| `HERMES_DASHBOARD_OIDC_SCOPES` | 選填，預設 `openid profile email`。**要靜默續期就設 `openid profile email offline_access`**——預設不含 `offline_access`，Auth0 不發 refresh token，ID token 到期（預設 10h）就要重新登入。Auth0 端也要勾 Refresh Token grant |
| `HERMES_DASHBOARD_PUBLIC_URL` | **必填** `https://hermes.relvo.cc`（見下方 §1.2.1） |

白名單寫在 Auth0 的 **post-login Action**（比對 email + `email_verified`，不符就 `api.access.deny()`），並把 Database connection 關掉（否則有人可自助註冊一個宣稱是白名單 email 的帳號）。Auth0 免費方案：25,000 MAU、social connection 無限、5 Actions、免信用卡，且不需要 Auth0 的自訂網域。

用的是 **bundled `self_hosted` provider**，`HERMES_ALLOWLIST_*` 與自寫 plugin 都不需要（那是 [`07`](./07-dashboard-access-control.md) 附錄 A 的未採用替代方案）。

#### 1.2.1 `HERMES_DASHBOARD_PUBLIC_URL` 是必填

自訂網域下**不能**依賴 `RAILWAY_PUBLIC_DOMAIN` 自動推導——Railway 文件沒有說明加了自訂網域後它取哪個值，若仍是 `xxx.up.railway.app`，OAuth callback 會被組成錯的 host，IdP 直接回 `redirect_uri_mismatch`（待驗證 A22）。

**Hermes 端驗證行為**：驗 ID token（RS256/ES256）against discovery 到的 `jwks_uri`，`iss`/`aud` pin 在設定值上。confidential client 依 IdP advertise 的 `token_endpoint_auth_methods_supported` 選 `client_secret_basic` 或 `client_secret_post`，**PKCE 在兩種模式下都會送**。Session 欄位：`user_id` ← `sub`、`email` ← `email`、`display_name` ← `name`→`preferred_username`→`nickname`→`email`、`org_id` ← `org_id`/`organization`，否則 join `groups`。

<details>
<summary>備用方案：basic auth（僅供 bring-up 除錯，官方警告不適合公網）</summary>

`HERMES_DASHBOARD_BASIC_AUTH_USERNAME` + `_PASSWORD_HASH` + `_SECRET`（+ 選填 `_TTL_SECONDS`）。
雜湊：`python -c "from plugins.dashboard_auth.basic import hash_password; print(hash_password('PW'))"`；secret：`openssl rand -base64 32`（留空會每次重啟換隨機金鑰、所有 session 失效）。
`/auth/password-login` 有 per-IP 速率限制（10 次/分鐘 → 429），帳號錯與密碼錯回同一個 `401`。
</details>

> `HERMES_DASHBOARD_INSECURE` 自 2026-06 起是 **no-op**，不再能關閉驗證閘。

### 1.3 Model provider

依 [`06`](./06-model-provider-evaluation.md) 選項 A：

| 變數 | 說明 |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code 訂閱憑證。搭配 `model.provider: anthropic` 使用。本機用 `claude setup-token` 產生 |
| `ANTHROPIC_BASE_URL` | **僅在採用 CLIProxyAPI 時**設為 `http://cliproxy.railway.internal:8317`（見 [`06`](./06-model-provider-evaluation.md)） |
| `OPENROUTER_API_KEY` | 備援 provider 的 key（撞訂閱限額時自動切換） |
| `HERMES_BOOTSTRAP_MODEL` | 本專案自訂，首次開機執行 `hermes config set model <值>`，格式 `provider/model` |
| `HERMES_BOOTSTRAP_TERMINAL_BACKEND` | 本專案自訂，預設 `local`（Railway 無 Docker daemon） |

> `model.provider` / `model.model` 與 `fallback_providers` 住在 `config.yaml`，**沒有對應環境變數**。前者由 `HERMES_BOOTSTRAP_MODEL` 代跑；後者需擴充 bootstrap 腳本或用 `railway ssh` 設一次。

<details>
<summary>其他 provider 的 key 環境變數</summary>

`ANTHROPIC_API_KEY`、`OPENAI_API_KEY` + `OPENAI_BASE_URL`、`GOOGLE_API_KEY`/`GEMINI_API_KEY`、`DEEPSEEK_API_KEY`、`GLM_API_KEY`、`KIMI_API_KEY`、`XAI_API_KEY`… 完整清單見 `website/docs/reference/environment-variables.md`
</details>

### 1.4 Telegram（polling）

| 變數 | 說明 |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Bot token。polling 是預設模式，不佔對外埠 |

平台啟用與 allowed users 在 `config.yaml`，需由 bootstrap 腳本或 `hermes gateway setup` 落地。

<details>
<summary>webhook 模式（本計畫不採用）</summary>

`TELEGRAM_WEBHOOK_URL` + **必填** `TELEGRAM_WEBHOOK_SECRET`（沒有它 gateway 拒絕啟動，GHSA-3vpc-7q5r-276h）+ `TELEGRAM_WEBHOOK_PORT`（預設 8443）。需要**第二個 custom domain**（Railway 一個 domain 只綁一個埠）。
</details>

### 1.5 瀏覽器工具

| 變數 | 說明 |
|---|---|
| `AGENT_BROWSER_ARGS` | 由 `016-railway-bootstrap` 設為 `--no-sandbox,--disable-dev-shm-usage`。**手動設定會停用自動注入**，所以兩個 flag 必須寫齊 |
| `AGENT_BROWSER_ENGINE` | `auto`（預設，目前是 Chrome）/ `lightpanda` / `chrome` |
| `AGENT_BROWSER_EXECUTABLE_PATH` | 通常不用設——`stage2-hook.sh` 開機時自動從 `/opt/hermes/.playwright` 偵測 |
| `BROWSER_INACTIVITY_TIMEOUT` | 閒置回收秒數（預設 120） |

雲端瀏覽器退路：`BROWSERBASE_API_KEY` + `BROWSERBASE_PROJECT_ID`、`BROWSER_USE_API_KEY`、`FIRECRAWL_API_KEY`。

### 1.6 其他

| 變數 | 說明 |
|---|---|
| `HERMES_TIMEZONE` | `Asia/Taipei`。影響 cron 排程與時間顯示 |
| `RAILWAY_HEALTHCHECK_TIMEOUT_SEC` | 覆寫 healthcheck timeout（預設 300s） |
| `HERMES_SKIP_CONFIG_MIGRATION` | `1` = 跳過開機時的 config schema migration（升級除錯用） |
| `HERMES_GATEWAY_NO_SUPERVISE` | `1` = 退回「gateway 就是容器主程序」的舊語意。**Railway 上不要設** |
| `HERMES_AUTH_JSON_BOOTSTRAP` | 首次開機以此內容建立 `auth.json`（僅在檔案不存在時）。走 Nous Portal 的純變數路徑會用到 |

**不要設**（依 #5 決策）：`API_SERVER_ENABLED` / `API_SERVER_HOST`。api_server 維持 loopback。

---

## 2. ⚠️ 環境變數 vs `.env` 的優先順序

`hermes_cli/env_loader.py:500`：

```python
_load_dotenv_with_fallback(user_env, override=True)   # user_env = $HERMES_HOME/.env
```

**`/opt/data/.env` 會覆蓋 Railway 注入的環境變數**（與 `website/docs/user-guide/docker.md` 的敘述相反，以程式碼為準；列為必測 A4）。

你選了「憑證統一管在 Railway 變數」（#8），所以規則是：

| 情況 | 結果 |
|---|---|
| key 只存在於 Railway 變數 | Railway 變數生效 ✅ **這是本計畫的目標狀態** |
| key 同時在 Railway 變數與 `.env` | **`.env` 勝出** ❌ 要避免 |
| 跑過 `hermes setup` / `hermes config set <API_KEY>` | 該 key 已進 `.env`，Railway 變數從此失效 ⚠️ |

### 必須遵守的操作紀律

1. **不跑 `hermes setup`。** 它是互動精靈，會把 API key 寫進 `.env`。憑證全部走 Railway 變數。
2. **`hermes config set` 只用於非憑證設定**（`model`、`terminal.backend`、`tool_loop_guardrails`、`fallback_providers`）。這些會進 `config.yaml`，不衝突。
3. **`hermes config set <某個 API_KEY>` 是禁止動作**——它會路由到 `.env` 並永久遮蔽 Railway 變數。
4. **`hermes gateway setup` 要小心**：若它把 `TELEGRAM_BOT_TOKEN` 寫進 `.env`，就等於把該 token 的管理權移交給 `.env`。要嘛避開，要嘛接受並在文件記錄。

### 唯一的例外：`API_SERVER_KEY`

`stage2-hook.sh` 在 `.env` 缺這個 key 時會**自動產生一組 32-byte 隨機值寫入**，之後載入時 `.env` 必然勝出。**無論如何都無法用 Railway 變數控制它。** 因為 api_server 依 #5 決策維持 loopback（不對外可達），接受這個行為即可。

### 好消息

seed 出來的 `.env`（複製自 `.env.example`，496 行）裡所有 API key 都是註解掉的，只有 `TERMINAL_TIMEOUT`、`TERMINAL_LIFETIME_SECONDS`、`BROWSER_SESSION_TIMEOUT`、`BROWSER_INACTIVITY_TIMEOUT`、`BROWSERBASE_PROXIES`、`BROWSERBASE_ADVANCED_STEALTH`、`TERMINAL_MODAL_IMAGE`、`*_DEBUG` 這幾個無害預設是啟用的。首次部署不會出現「seed 檔遮蔽你的金鑰」。

---

## 3. `config.yaml` 上的關鍵設定

環境變數蓋不到、必須落在 `config.yaml` 的項目：

```yaml
model:
  provider: anthropic          # 由 HERMES_BOOTSTRAP_MODEL 代跑
  model: <claude-model-id>

fallback_providers:            # 撞 Claude Code 訂閱限額時自動切換
  - provider: openrouter
    model: <備援 model-id>

terminal:
  backend: local               # Railway 沒有 Docker daemon

tool_loop_guardrails:          # 無人值守部署的斷路器（預設關閉）
  hard_stop_enabled: true
  hard_stop_after:
    exact_failure: 5
    idempotent_no_progress: 5

gateway:
  api_server:
    enabled: false             # 依 #5，不對外
```

落地方式：擴充 `016-railway-bootstrap` 的首次開機區塊（純變數路徑，推薦），或 `railway ssh` → `hermes config set`，或直接編輯 volume 上的檔案。

---

## 4. `.env.railway.example`（放在 repo 根目錄）

```bash
# ── Railway 執行期 ──────────────────────────────────────────────────
RAILWAY_RUN_UID=0
PORT=9119
HERMES_DASHBOARD=1
HERMES_DASHBOARD_HOST=0.0.0.0
HERMES_DASHBOARD_PORT=9119
HERMES_GATEWAY_BOOTSTRAP_STATE=running
HERMES_TIMEZONE=Asia/Taipei

# ── Dashboard 驗證（Auth0 + Google，白名單在 Auth0 post-login Action）
# Auth0: Google social connection、關閉 Database connection、
#        callback URL = https://hermes.relvo.cc/auth/callback
HERMES_DASHBOARD_PUBLIC_URL=https://hermes.relvo.cc
HERMES_DASHBOARD_OIDC_ISSUER=https://<tenant>.<region>.auth0.com/
HERMES_DASHBOARD_OIDC_CLIENT_ID=
HERMES_DASHBOARD_OIDC_CLIENT_SECRET=

# ── Model provider（Claude Code 訂閱 + 按量備援）────────────────────
# 本機執行 `claude setup-token` 產生
CLAUDE_CODE_OAUTH_TOKEN=
OPENROUTER_API_KEY=

# ── 首次開機的 config bootstrap（本專案自訂）────────────────────────
HERMES_BOOTSTRAP_MODEL=anthropic/<claude-model-id>
HERMES_BOOTSTRAP_TERMINAL_BACKEND=local

# ── 訊息平台 ────────────────────────────────────────────────────────
TELEGRAM_BOT_TOKEN=

# ── 瀏覽器（雲端退路，若本地 Chromium 不穩再啟用）───────────────────
# BROWSERBASE_API_KEY=
# BROWSERBASE_PROJECT_ID=
```

> `AGENT_BROWSER_ARGS` 由 `016-railway-bootstrap` 自動設定，不需列在這裡。
> `API_SERVER_KEY` 由 stage2 自動產生於 `/opt/data/.env`，不需也無法用 Railway 變數控制。
