# 03 — 實作計畫

分五個階段。階段 0–2 是可上線的最小完整部署；階段 3–4 是強化與擴充。

---

## 目標倉庫結構

**A. `Lei-k/hermes-agent`（fork，階段 0）**
```
.github/workflows/
└── fork-image.yml                        # 建 amd64 映像 → 推 GHCR
```

**B. `hermes-agent-railway`（本 repo）**
```
hermes-agent-railway/
├── Dockerfile                            # 薄封裝：FROM ghcr.io/lei-k/hermes-agent:<sha>
├── railway.toml                          # builder / healthcheck / restart policy
├── .dockerignore
├── docker/
│   └── cont-init.d/
│       └── 016-railway-bootstrap         # Railway 專用開機 hook
├── scripts/
│   └── provision.sh                      # railway CLI 一次建好 volume / 變數 / domain
├── .env.railway.example                  # 服務變數範本（不含真實密鑰）
├── README.md
└── plan/                                 # 本目錄
```

---

## 階段 0：fork 映像流水線

### 為什麼需要

上游 `.github/workflows/docker.yml` 的 build job 有守衛：

```yaml
build:
  if: github.repository == 'NousResearch/hermes-agent' && needs.detect.outputs.build == 'true'
```

**在 fork 上永遠不會執行**，而且發佈目標是 `nousresearch/hermes-agent`（fork 也拿不到那組 Docker Hub secret）。fork 必須有自己的 workflow。

### 為什麼不讓 Railway 直接建 fork 原始碼

| 項目 | 上游 Dockerfile 的實際成本 |
|---|---|
| 建置時間 | 上游自己把 job timeout 設在 **45 分鐘**；註解自述冷建置 15–45 分鐘 |
| 映像大小 | 上游註解直言 **「the image is 5GB+」** |
| 建置內容 | 從原始碼編 SQLite 3.53.4 → 抓 s6-overlay → 複製 Node 26 → `npm install` + Playwright Chromium → photon sidecar `npm ci` → `uv sync` 八個 extras → 建 `web/` 與 `ui-tui/` 前端 |

GitHub Actions 有 `type=gha,mode=max` 的 layer cache、可以只建 amd64（Railway 只跑 amd64，省掉 arm64 那半），而且不會佔住 Railway 的部署流程。兩層分離之後，Railway 端每次部署只建薄封裝，是秒級。

### 0.1 `Lei-k/hermes-agent` 的 `.github/workflows/fork-image.yml`

```yaml
name: Fork image → GHCR

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  packages: write

concurrency:
  group: fork-image-${{ github.ref }}
  cancel-in-progress: false        # 每個 merge 都要有自己的映像

env:
  IMAGE: ghcr.io/${{ github.repository_owner }}/hermes-agent

jobs:
  build:
    runs-on: ubuntu-latest
    # 上游同等 job 設 45 分鐘；冷建置（無 cache）會用掉大半
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: meta
        run: echo "sha=$(git rev-parse --short HEAD)" >> "$GITHUB_OUTPUT"

      - uses: docker/build-push-action@v6
        with:
          context: .
          file: Dockerfile
          push: true
          # 只建 amd64 —— Railway 跑 amd64，省掉 arm64 的一半建置時間
          platforms: linux/amd64
          tags: |
            ${{ env.IMAGE }}:${{ steps.meta.outputs.sha }}
            ${{ env.IMAGE }}:main
          build-args: |
            HERMES_GIT_SHA=${{ github.sha }}
          cache-from: type=gha,scope=fork-amd64
          cache-to: type=gha,mode=max,scope=fork-amd64
```

> `HERMES_GIT_SHA` build-arg 會被烤進 `/opt/hermes/.hermes_build_sha`，讓 `hermes dump` 與啟動 banner 能報出正確的 commit——容器問題排查時這是唯一能確認「到底跑的是哪個 commit」的線索。

### 0.2 GHCR package 可見性

兩個選擇：

- **設為 public**（`ghcr.io/lei-k/hermes-agent`）→ Railway 直接拉，零設定。前提是 fork 的修改可公開。
- **保持 private** → Railway 需要 registry credentials。Railway 文件說明 GHCR 要用 **personal access token**（不是密碼）作為認證。需在 Railway service 設定 registry 帳密。

薄封裝的 Dockerfile 在 Railway build 階段拉基底映像，所以 credentials 必須在 **build** 階段可用。若 private 這條路在 Railway 上遇到阻礙（列為待驗證 A15），退路是把薄封裝那一層也搬進 GitHub Actions，Railway 改成純 image source 部署——但那樣就得放棄 `railway.toml` 的 config-as-code，改用 start command `/opt/hermes/docker/entrypoint-dispatch.sh gateway run`（唯一安全的覆蓋寫法）。

### 階段 0 完成定義
- [ ] workflow 成功推出 `ghcr.io/lei-k/hermes-agent:<sha>`
- [ ] 本機 `docker pull` + `docker run --rm <image> version` 可執行
- [ ] 本機量測未壓縮映像大小（預期 ~5 GB，Pro 方案無上限）
- [ ] 決定 package 可見性；private 的話 Railway registry credentials 已設好

---

## 階段 1：容器落地

### 1.1 `Dockerfile`（本 repo）

```dockerfile
# syntax=docker/dockerfile:1

# fork 自建映像（階段 0 產出）。釘死 commit sha，不用 :main：
# 未釘版會讓 Railway 的執行環境在無預警下改變。
ARG HERMES_IMAGE=ghcr.io/lei-k/hermes-agent
ARG HERMES_TAG=<commit-sha>
FROM ${HERMES_IMAGE}:${HERMES_TAG}

# Railway 專用開機 hook。
#
# cont-init.d 依字典序執行，上游既有順序是：
#   01-hermes-setup → 015-supervise-perms → 02-reconcile-profiles
# 我們要在 02（依 gateway_state.json 拉起 gateway s6 slot）之前完成埠對齊
# 與 config bootstrap，所以編號取 016（"016" < "02"，字元比較 1 < 2）。
COPY --chmod=0755 docker/cont-init.d/016-railway-bootstrap \
     /etc/cont-init.d/016-railway-bootstrap

# Railway 的 custom start command 會覆蓋映像 ENTRYPOINT，而 Hermes 的
# ENTRYPOINT (entrypoint-dispatch.sh) 承載整條 s6 bootstrap，不能被覆蓋。
# 把參數烤進 CMD，Railway 的 start command 就能留空。
CMD ["gateway", "run"]
```

> ENTRYPOINT 原封不動繼承。`gateway run` 在官方映像內是**受 s6 監管**的模式：CMD 程序本身只是心跳，真正的 gateway 崩潰後會被 s6 自動重啟，容器不會死。

### 1.2 `docker/cont-init.d/016-railway-bootstrap`

```sh
#!/command/with-contenv sh
# shellcheck shell=sh
#
# Railway 專用容器開機 hook。以 root 執行，在 01-hermes-setup(stage2) 之後、
# 02-reconcile-profiles(拉起 gateway) 之前。
#
# 寫入 /run/s6/container_environment/<KEY> 是 s6-overlay 的環境注入機制：
# 所有帶 with-contenv shebang 的受監管服務（dashboard、per-profile gateway）
# 與 main-wrapper.sh 都會讀到。
set -eu

HERMES_HOME="${HERMES_HOME:-/opt/data}"
ENVDIR=/run/s6/container_environment
mkdir -p "$ENVDIR"

log() { echo "[railway] $*"; }
set_env() { printf '%s' "$2" > "$ENVDIR/$1"; log "$1=$2"; }

# ── 1. Dashboard 是 Railway 唯一的對外入口，強制開啟 ──────────────────
case "${HERMES_DASHBOARD:-}" in
    1|true|TRUE|True|yes|YES|Yes) ;;
    *) set_env HERMES_DASHBOARD 1 ;;
esac

# ── 2. 把 dashboard 綁到 Railway 的 PORT ────────────────────────────
if [ -z "${HERMES_DASHBOARD_PORT:-}" ] && [ -n "${PORT:-}" ]; then
    set_env HERMES_DASHBOARD_PORT "$PORT"
fi
[ -n "${HERMES_DASHBOARD_HOST:-}" ] || set_env HERMES_DASHBOARD_HOST 0.0.0.0

# ── 3. OIDC/OAuth callback 需要真正的公開網址 ───────────────────────
# callback 是 <public URL>/auth/callback，必須與 IdP 註冊的 redirect URI 一致。
if [ -z "${HERMES_DASHBOARD_PUBLIC_URL:-}" ] && [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
    set_env HERMES_DASHBOARD_PUBLIC_URL "https://${RAILWAY_PUBLIC_DOMAIN}"
fi

# ── 4. 瀏覽器工具：容器內非 root 執行，自動注入可能不觸發 ───────────
# Hermes 在偵測到 root 或 AppArmor 受限 userns 時會自動注入
# --no-sandbox,--disable-dev-shm-usage；受監管服務是以 hermes(UID 10000)
# 執行，不一定命中。Railway 無法設 --shm-size，所以明確補上。
# 注意：手動設定會停用自動注入，因此必須把兩個 flag 都寫齊。
if [ -z "${AGENT_BROWSER_ARGS:-}" ] && [ "${HERMES_RAILWAY_BROWSER_ARGS:-1}" = "1" ]; then
    set_env AGENT_BROWSER_ARGS "--no-sandbox,--disable-dev-shm-usage"
fi

# ── 5. 首次開機的 config bootstrap（純變數路徑）─────────────────────
# model / terminal backend 住在 config.yaml，沒有對應環境變數。
# 憑證類一律不碰 —— 那些留在 Railway 變數，寫進 .env 會反過來蓋掉平台變數。
#
# /opt/hermes/bin/hermes 是 exec shim（PATH 最前），偵測到 root 呼叫者會
# 自動透過 s6-setuidgid 降權到 hermes，所以寫出的檔案 owner 正確。
BOOTSTRAP_MARK="$HERMES_HOME/.railway_bootstrapped"
if [ ! -f "$BOOTSTRAP_MARK" ]; then
    if [ -n "${HERMES_BOOTSTRAP_MODEL:-}" ]; then
        log "bootstrap model=${HERMES_BOOTSTRAP_MODEL}"
        hermes config set model "$HERMES_BOOTSTRAP_MODEL" \
            || log "WARNING: 'hermes config set model' failed"
    fi
    # Railway 沒有 Docker daemon，docker terminal backend 不可用。
    hermes config set terminal.backend "${HERMES_BOOTSTRAP_TERMINAL_BACKEND:-local}" \
        || log "WARNING: 'hermes config set terminal.backend' failed"

    : > "$BOOTSTRAP_MARK" 2>/dev/null || true
    chown hermes:hermes "$BOOTSTRAP_MARK" 2>/dev/null || true
fi

log "bootstrap complete"
```

> **注意**：`hermes config set` 需匯入完整 CLI，冷啟動約數秒。若實測發現在 cont-init 階段太慢或有副作用（待驗證 A11），退路是拿掉 §5，改成部署後用 `railway ssh` 跑一次——但那會偏離 #8 的純變數原則，所以優先修這段而非放棄。

### 1.3 `railway.toml`

```toml
# https://docs.railway.com/reference/config-as-code
#
# 注意：service source、volume、環境變數都不在此 schema 內，
# 由 scripts/provision.sh 或 Railway dashboard 建立。

[build]
builder = "DOCKERFILE"
dockerfilePath = "Dockerfile"

[deploy]
# startCommand 刻意留空 —— 設了它會覆蓋映像的 ENTRYPOINT，
# 整條 s6 bootstrap（chown / seed / migration / 監管樹）會被跳過。

healthcheckPath = "/api/health"    # 免驗證的 liveness 端點（PUBLIC_API_PATHS）
healthcheckTimeout = 300           # 冷開機要跑 migration + skills sync + uvicorn

restartPolicyType = "ALWAYS"
drainingSeconds = 30               # 給 s6 收乾淨 gateway + SQLite WAL checkpoint
```

### 1.4 `.dockerignore`

```
plan/
scripts/
README.md
.env*
.git/
```

### 1.5 Railway 端建置

```bash
railway login
railway init                        # 或 railway link 到既有 project
railway add --service hermes-agent

# Volume — 必須是 /opt/data（= $HERMES_HOME，上游 Dockerfile 的 VOLUME 宣告）
railway volume add --mount-path /opt/data

# 最小變數集（完整清單見 04-configuration-reference.md）
railway variables \
  --set RAILWAY_RUN_UID=0 \
  --set PORT=9119 \
  --set HERMES_DASHBOARD=1 \
  --set HERMES_DASHBOARD_HOST=0.0.0.0 \
  --set HERMES_DASHBOARD_PORT=9119 \
  --set HERMES_GATEWAY_BOOTSTRAP_STATE=running \
  --set HERMES_TIMEZONE=Asia/Taipei \
  --set HERMES_DASHBOARD_PUBLIC_URL=https://hermes.relvo.cc \
  --set HERMES_DASHBOARD_OIDC_ISSUER='https://<your-idp>/' \
  --set HERMES_DASHBOARD_OIDC_CLIENT_ID='hermes-dashboard' \
  --set CLAUDE_CODE_OAUTH_TOKEN='<token>' \
  --set HERMES_BOOTSTRAP_MODEL='anthropic/<claude-model-id>'

railway up               # 建置並部署

# 自訂網域（relvo.cc）—— CNAME + TXT 兩筆都要加，只加 CNAME 不會驗證通過
railway domain hermes.relvo.cc        # target port 選 9119
# → 依 Railway 給的值在 DNS 加 CNAME + TXT，等 Let's Encrypt 憑證簽發（通常 1 小時內）
# → 確認 https://hermes.relvo.cc 可用之後，把 Railway 產生的 *.up.railway.app 網域移除，
#    讓公開入口只有一個（見 07 §2.2）
```

**`HERMES_GATEWAY_BOOTSTRAP_STATE=running` 不可省。** 全新 volume 上沒有 `gateway_state.json`，`02-reconcile-profiles` 只會註冊 s6 slot 而**不會啟動** gateway——代理人不會連 Telegram、cron 不會跑。這個變數讓 stage2 在首次開機寫下 `{"gateway_state":"running"}`。

### 1.6 Dashboard 驗證：Google 登入 + 白名單

**必須在第一次部署前完成**——沒有任何 provider 註冊時，dashboard 在非 loopback bind 下會 **fail closed，直接拒絕啟動**，healthcheck 必然失敗。

完整比較與替代方案見 [`07-dashboard-access-control.md`](./07-dashboard-access-control.md)。**推薦走 Auth0**（`relvo.cc` 不在 Cloudflare，Auth0 不碰 DNS 且白名單改了即時生效）：

1. **Auth0 建 tenant**，記下預設網域 `<tenant>.<region>.auth0.com`（就是 OIDC issuer，不需另購自訂網域）
2. **Authentication → Social → 建立 Google connection**
3. **Applications → Create Application**（*Regular Web Application* 或 *Single Page Application* 皆可，Hermes 兩種都支援）
   - Allowed Callback URLs = `https://hermes.relvo.cc/auth/callback`
   - **關掉 Database connection**，只留 Google，避免有人自助註冊帳號
4. **Actions → post-login trigger** 加白名單並 Apply：
   ```javascript
   exports.onExecutePostLogin = async (event, api) => {
     const allowed = ['you@your-company.example'];
     const email = (event.user.email || '').toLowerCase();
     if (!event.user.email_verified || !allowed.includes(email)) {
       api.access.deny('Not authorized for this application.');
     }
   };
   ```
   > `email_verified` 的檢查不可省——沒有它，只要 IdP 允許自助註冊，任何人都能宣稱自己是白名單上的 email。
5. **設 Railway 變數**：
   ```
   HERMES_DASHBOARD_OIDC_ISSUER=https://<tenant>.<region>.auth0.com/
   HERMES_DASHBOARD_OIDC_CLIENT_ID=<client id>
   HERMES_DASHBOARD_OIDC_CLIENT_SECRET=<client secret>
   HERMES_DASHBOARD_PUBLIC_URL=https://hermes.relvo.cc
   ```

6. **（選配，加分）Google 同意畫面設 Internal**：Auth0 的 Google connection 要一組你自己的 Google OAuth client，建立時把 consent screen 的 User Type 設 Internal。注意那組 client 的 redirect URI 是 **Auth0 的** `https://<tenant>.<region>.auth0.com/login/callback`，不是 Hermes 的。

> 用的是 **bundled `self_hosted` provider**，不需要自寫 plugin，`HERMES_ALLOWLIST_*` 完全用不到，旁路問題也不存在（只有一個 provider 註冊）。
>
> 被拒的使用者會拿到 `400 OAuth error from provider: access_denied (...)`，並在稽核日誌留下 `LOGIN_FAILURE`（已從 `routes.py:473-485` 確認）。
>
> 想要免重新登入的續期，設 `HERMES_DASHBOARD_OIDC_SCOPES=openid profile email offline_access` 並在 Auth0 勾選 Refresh Token grant——預設 scopes 不含 `offline_access`，Auth0 就不發 refresh token，ID token 到期（預設 10 小時）要重新登入。

> **順序**：因為用自訂網域，callback URL 從一開始就確定是 `https://hermes.relvo.cc/auth/callback`，不必等 Railway 給網址——先在 IdP 設好，再建 service、掛網域、部署。

### 階段 1 完成定義

- [ ] Railway build 成功（薄封裝，應在 1 分鐘內）
- [ ] Deploy log **沒有** `WARNING: container entrypoint is not PID 1`
- [ ] Deploy log 有 `[stage2] Setup complete; starting user services` 與 `[railway] bootstrap complete`
- [ ] `curl https://<domain>/api/health` → 200
- [ ] `curl -s https://hermes.relvo.cc/api/status | jq '.auth_providers'` → **只有一個 provider**（出現兩個就是旁路，必須修）
- [ ] 瀏覽器開 `https://hermes.relvo.cc/` → 導向 `/login` → 用白名單內的 Google 帳號登入 → 回到 dashboard
- [ ] Railway 產生的 `*.up.railway.app` 網域已移除
- [ ] `GET /api/auth/me` 回傳已驗證 session
- [ ] **白名單外的 Google 帳號登入被拒**（這一項一定要實測）
- [ ] Dashboard Status 頁顯示 gateway running

---

## 階段 2：讓代理人真的可用

### 2.1 Model provider

依 [`06`](./06-model-provider-evaluation.md)。**只有 Claude Code 訂閱的話走選項 A**（Hermes 原生支援，零額外元件）；若有多家 CLI 訂閱要池化，才值得加 CLIProxyAPI 當第二個 service（見 `06` §4 的成本分析）。選項 A：

```bash
railway variables \
  --set CLAUDE_CODE_OAUTH_TOKEN='<claude setup-token 產生>' \
  --set HERMES_BOOTSTRAP_MODEL='anthropic/<claude-model-id>' \
  --set OPENROUTER_API_KEY='<備援 key>'
```

備援鏈需要寫進 `config.yaml`（沒有對應環境變數）——可以擴充 `016-railway-bootstrap` 的 §5，或用 `railway ssh` 設一次：

```yaml
fallback_providers:
  - provider: openrouter
    model: <備援 model-id>
```

**為什麼需要備援**：Claude Code 訂閱是滾動時間窗限額，設計前提是互動式使用；而常駐 gateway + cron + 學習迴圈是無人值守負載，撞限額的機率高很多。Hermes 收到「plan/usage limit reached」型 429 時會立刻切換（不重試），代理人不會啞掉。

> **若改採 CLIProxyAPI**：新增第二個 Railway service（自己的 volume 存 `auth-dir`、不開對外 domain），Hermes 端改設 `ANTHROPIC_BASE_URL=http://cliproxy.railway.internal:8317` + `ANTHROPIC_API_KEY=<CLIProxyAPI 的 api-keys 之一>`。上游帳號的 OAuth 登入要用 `railway ssh` 逐一互動完成。詳見 `06` §4–5。

### 2.2 Telegram（polling 模式）

```bash
railway variables --set TELEGRAM_BOT_TOKEN='<token>'
```

平台啟用與 allowed users 需寫進 `config.yaml`。純變數路徑下可擴充 bootstrap 腳本；或首次用 `railway ssh` 跑 `hermes gateway setup`（**注意：這個精靈可能把 token 寫進 `.env`，之後 Railway 變數就失效**——若走這條，就接受 token 由 `.env` 管理）。

polling 不佔對外埠。掛了 volume 的 Railway service 不會 scale to zero，polling「機器無法休眠」的缺點在此不成立。

### 2.3 瀏覽器工具

映像已內建 Playwright Chromium（`/opt/hermes/.playwright`），`stage2-hook.sh` 開機時自動偵測並設 `AGENT_BROWSER_EXECUTABLE_PATH`。`016-railway-bootstrap` 的 §4 已補上 `AGENT_BROWSER_ARGS`。

驗證方式：讓代理人實際跑一次 `browser_navigate` + `browser_snapshot`。若不穩，兩個退路：

- **雲端瀏覽器**：`BROWSERBASE_API_KEY` + `BROWSERBASE_PROJECT_ID`（或 Browser Use / Firecrawl / Nous Portal Tool Gateway）。完全避開本地資源問題
- **Lightpanda**：記憶體低 16 倍，需在薄封裝映像加裝 binary + 設 `AGENT_BROWSER_ENGINE=lightpanda`

另外 `agent-browser` CLI 是透過 `npx` 解析的，而映像 `HERMES_DISABLE_LAZY_INSTALLS=1` 且 `/opt/hermes` 唯讀——npm cache 會落在 `HOME=/opt/data` 底下（volume 上）。這條路徑需驗證（A16）；必要時在薄封裝映像 `npm i -g agent-browser` 預裝。

### 2.4 無人值守環境的 tool-loop 斷路器

官方建議 gateway/server 部署要開啟硬停止（預設關閉，只適合有人盯著的互動式 session）：

```yaml
tool_loop_guardrails:
  hard_stop_enabled: true
  hard_stop_after:
    exact_failure: 5
    idempotent_no_progress: 5
```

### 階段 2 完成定義

- [ ] `hermes config get model` 顯示預期的 provider/model
- [ ] Dashboard Chat 分頁可正常對話（驗證 WebSocket/PTY 通過 Railway proxy）
- [ ] Telegram 收發正常
- [ ] 瀏覽器工具實測可用（或已切到雲端瀏覽器）
- [ ] 觸發一次額度耗盡，確認 fallback 生效（可用假 token 模擬）
- [ ] `railway redeploy` 後 session 歷史與設定仍在（驗證 volume 持久化）

---

## 階段 3：安全強化

### 3.1 檢視驗證強度

階段 1 已直接上 OIDC，跳過了 basic auth 這一步。要確認的是：

- Auth0 的 post-login Action 白名單只含應有的人，且有檢查 `email_verified`
- Auth0 的 Database connection 確實關閉（否則有人可自助註冊帳號）
- 只有一個 provider 註冊（`/api/status` 的 `auth_providers`）
- 開啟 Auth0 的 MFA 與暴力破解防護（免費方案就有）
- `HERMES_DASHBOARD_OIDC_SCOPES` 預設 `openid profile email` 是否足夠；session TTL 與 refresh 行為

### 3.2 api_server 維持 loopback

依 #5 決策，**不設 `API_SERVER_HOST=0.0.0.0`**。api_server 提供代理人的完整工具集**包含 terminal 指令執行**——這正是 2026 年 6 月那波攻擊的入口之一。

`API_SERVER_KEY` 由 stage2 自動產生並寫進 `/opt/data/.env`，loopback-only 所以不對外可達。這是唯一一個「刻意由 `.env` 管理而非 Railway 變數」的憑證——因為 stage2 的自動產生機制無論如何都會贏（見 `04` §2）。

### 3.3 代理人權限邊界

代理人在容器內有完整 shell。實務上要注意：

- 這個容器裡不要放與 Hermes 無關的高權限憑證（Railway 變數對代理人是可見的）
- `terminal` 的 command approval 政策依需求收緊
- tool-loop 硬停止已在 2.4 開啟

### 3.4 密鑰衛生

- Railway 變數標記為 sealed
- volume 上的 `.env` 由 stage2 強制 `chmod 600`
- 定期輪替：`CLAUDE_CODE_OAUTH_TOKEN`、Telegram token、OIDC client（若 IdP 支援）

---

## 階段 4：維運與擴充

### 4.1 上游同步與版本升級

因為 fork 有自訂修改，升級是兩段式：

```
upstream/main ──merge──> Lei-k/hermes-agent:main
                              │ push 觸發 fork-image.yml
                              ↓
                    ghcr.io/lei-k/hermes-agent:<new-sha>
                              │ 更新本 repo Dockerfile 的 HERMES_TAG
                              ↓
                         Railway 重建薄封裝（秒級）
```

1. fork 合併上游變更，解決 conflict
2. workflow 自動建置推 GHCR（60 分鐘內）
3. 改本 repo `Dockerfile` 的 `ARG HERMES_TAG` → commit → Railway 自動重建
4. 開機時 `stage2-hook.sh` 自動跑 `docker_config_migrate.py`，需要時把 `config.yaml`/`.env` 備份成時間戳檔案
5. 從 `/api/status` 確認版本

掛了 volume 的 service 重新部署會有短暫停機（Railway 平台限制），屬預期行為。

**回滾**：把 `HERMES_TAG` 改回舊 sha 即可——GHCR 上每個 commit 都有映像。

### 4.2 備份

Railway Pro 的 volume 備份是平台功能；另外做應用層備份：

```bash
railway ssh
tar czf /tmp/hermes-backup.tar.gz -C /opt/data \
    config.yaml .env SOUL.md memories skills cron sessions
```

更好的做法是用 Hermes 自己的 cron 排程器，定期把備份推到物件儲存——這正是它擅長的事。

### 4.3 多 profile（選用）

```bash
railway ssh
hermes profile create work        # 動態註冊 s6 slot，不需重建容器
hermes -p work gateway start
```

Dashboard 是機器層級的，側邊欄 profile 切換器即可管理全部 profile，**不需要額外埠**。

### 4.4 監控

- Railway healthcheck **只在部署時檢查，上線後不再監控**。外部 uptime 服務打 `/api/health`
- `/api/status` 提供版本、gateway 狀態、活躍 session 數
- Dashboard 內建資源壓力橫幅（記憶體 < 128 MiB 或 < 15% 告警、疑似 OOM 重啟偵測、volume 剩餘 < 512 MB 告警）
- 跨部署保留的日誌：`/opt/data/logs/gateways/default/current`、`/opt/data/logs/container-boot.log`
