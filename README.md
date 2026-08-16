# hermes-agent-railway

把 [Hermes Agent](https://github.com/NousResearch/hermes-agent)（fork：[`Lei-k/hermes-agent`](https://github.com/Lei-k/hermes-agent)）部署到 Railway。

完整的設計依據、平台限制分析與風險評估在 [`plan/`](./plan/)。這份 README 是操作手冊。

---

## 架構

```
┌─ GitHub Actions (Lei-k/hermes-agent) ─────────────────────┐
│  .github/workflows/fork-image.yml                          │
│  build amd64 → ghcr.io/lei-k/hermes-agent:<sha>            │
└────────────────────────┬───────────────────────────────────┘
                         │ FROM（本 repo 的薄封裝，秒級建置）
┌─ Railway Service (Pro, 1 replica) ────────────────────────┐
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
     https://hermes.relvo.cc  ←  Auth0 (Google) 驗證閘
```

**為什麼是兩層映像**：上游 Dockerfile 冷建置要編 SQLite、抓 s6-overlay、裝 Playwright、`uv sync` 八個 extras、建兩個前端 —— 上游自己把那個 job 的 timeout 設在 45 分鐘、映像 5GB+。交給 GitHub Actions（有 layer cache、只建 amd64），Railway 端就只建薄封裝。

**為什麼 Railway 的 start command 必須留空**：它會以 exec form **覆蓋映像的 ENTRYPOINT**，而 `entrypoint-dispatch.sh` 承載整條 s6 bootstrap（volume chown、`.env`/`config.yaml` 首次 seed、config schema migration、監管樹）。指令已烤進 `Dockerfile` 的 `CMD`。

---

## 檔案

| 路徑 | 用途 |
|---|---|
| `Dockerfile` | 薄封裝：釘住上游版本、塞入開機 hook、烤入 `CMD` |
| `railway.toml` | builder / healthcheck / restart policy |
| `docker/cont-init.d/016-railway-bootstrap` | Railway 專用開機 hook（埠對齊、公開網址、瀏覽器旗標、首次 config bootstrap） |
| `.env.railway.example` | Railway 服務變數範本 |
| `scripts/provision.sh` | 用 railway CLI 建 volume / 變數 / 網域 |
| `plan/` | 設計文件（8 份） |

> `.github/workflows/fork-image.yml` 屬於 **fork repo**（`Lei-k/hermes-agent`），已一併產生在該 checkout 中，需要在那邊 commit。

---

## 部署

### 0. fork 映像流水線（一次性）

在 `Lei-k/hermes-agent` commit 並 push `.github/workflows/fork-image.yml`，讓它跑一次。

GHCR package 的可見性二選一：
- **public** → Railway 直接拉，零設定
- **private** → 要在 Railway service 設 registry credentials（GHCR 用 personal access token，不是密碼）。薄封裝在 **build** 階段拉基底映像，所以 credentials 必須在 build 階段可用（待驗證 A15）

拿到 sha 後，把 `Dockerfile` 的 `ARG HERMES_TAG=main` 改成該 sha。

### 1. Auth0（部署前必須完成）

沒有任何 auth provider 註冊時，dashboard 在非 loopback bind 下會 **fail closed、直接拒絕啟動**，healthcheck 必然失敗。

完整步驟見 [`plan/07`](./plan/07-dashboard-access-control.md) §5。摘要：

1. 建 tenant，記下 `<tenant>.<region>.auth0.com`（就是 OIDC issuer，不需另購自訂網域）
2. Authentication → Social → **Google connection**
3. Applications → Create Application（**Regular Web Application**）
   - Allowed Callback URLs = `https://hermes.relvo.cc/auth/callback`
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
>
> **Google OAuth client 的 redirect URI 是 Auth0 的**（`https://<tenant>.<region>.auth0.com/login/callback`），不是 Hermes 的。兩層不要搞混。

### 2. Railway

```bash
cp .env.railway.example .env.railway   # 填入真實值
railway login
railway link
./scripts/provision.sh                 # 預覽
./scripts/provision.sh --apply         # 執行
```

依 Railway 給的值加上 **CNAME + TXT 兩筆** DNS 記錄（只加 CNAME 不會驗證通過，會回 404），等憑證簽發。

確認 `https://hermes.relvo.cc` 可用之後，**把 Railway 自動產生的 `*.up.railway.app` 網域移除** —— 留著等於 dashboard 有第二個對外入口。

### 3. 驗收

```bash
curl -s https://hermes.relvo.cc/api/health
curl -s https://hermes.relvo.cc/api/status | jq '.auth_required, .auth_providers'
#   → true / ["self-hosted"]   出現第二個 provider 就要查
```

Deploy log 檢查：
- **不可**出現 `WARNING: container entrypoint is not PID 1` — 出現代表 s6 監管樹沒起來，dashboard 不存在
- 應出現 `[stage2] Setup complete; starting user services`
- 應出現 `[railway] bootstrap complete`

登入測試：白名單內的 Google 帳號可進；**白名單外的帳號要實測被拒**，應看到 `400 OAuth error from provider: access_denied (...)`。

完整檢查表在 [`plan/05`](./plan/05-risks-and-verification.md) §3。

---

## 維運

### 憑證管理紀律 ⚠️

`$HERMES_HOME/.env` 是以 `override=True` 載入的（`hermes_cli/env_loader.py:500`），**會蓋掉 Railway 注入的環境變數**。憑證統一管在 Railway 變數，所以：

- **不要跑 `hermes setup`** — 它會把 API key 寫進 `.env`，從此同名的 Railway 變數永久失效
- **不要用 `hermes config set <某個 API_KEY>`** — 同樣路由到 `.env`
- `hermes config set` 只用於非憑證設定（`model`、`terminal.backend`、`tool_loop_guardrails`…）

唯一無解的例外是 `API_SERVER_KEY`：`stage2-hook.sh` 在 `.env` 缺它時一定會自動產生一組寫入。因為 api_server 維持 loopback、不對外可達，接受即可。

症狀是「改了 Railway 變數但沒作用」時，先查 `/opt/data/.env` 有沒有同名 key。

### 上游同步與升級

```
upstream/main ──merge──> Lei-k/hermes-agent:main
                              │ push 觸發 fork-image.yml（~60 分鐘）
                              ↓
                    ghcr.io/lei-k/hermes-agent:<new-sha>
                              │ 改本 repo Dockerfile 的 HERMES_TAG
                              ↓
                         Railway 重建薄封裝（秒級）
```

開機時 `stage2-hook.sh` 會自動跑 `docker_config_migrate.py`，需要時把 `config.yaml`/`.env` 備份成時間戳檔案。

**回滾**：`HERMES_TAG` 改回舊 sha 即可 —— GHCR 上每個 commit 都有映像。

掛了 volume 的 service 重新部署會有短暫停機（Railway 平台限制：多個 active deployment 無法同時掛同一顆 volume）。這對 Hermes 反而是必要的 —— 兩個 gateway 共用資料目錄會損毀 session 與 memory store。

### 修改白名單

編輯 Auth0 的 post-login Action，**即時生效，不用 redeploy**。

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
| `redirect_uri_mismatch` | `HERMES_DASHBOARD_PUBLIC_URL` 是否等於 `https://hermes.relvo.cc`；與 Auth0 的 Allowed Callback URLs 是否完全一致 |
| 自訂網域回 404 | TXT 記錄漏了，或憑證還在簽發 |
| 登入頁出現兩個 provider | 有多餘的 auth provider 註冊了 —— 檢查是否誤設 `HERMES_ALLOWLIST_*` 或其他 provider 的變數 |
| 代理人不回訊息 | ① dashboard Status 頁的 gateway 狀態 ② `hermes gateway status` ③ `HERMES_GATEWAY_BOOTSTRAP_STATE=running` 是否有設 ④ 是否撞 Claude Code 訂閱限額 |
| Permission denied / EACCES | `RAILWAY_RUN_UID=0` 是否設 |
| 該進的人被拒 | Auth0 Action 的 email 清單是否完全一致（小寫比對）；`email_verified` 是否為 true |

完整 runbook 在 [`plan/05`](./plan/05-risks-and-verification.md) §4。

---

## 尚未決定 / 未實作

- **CLIProxyAPI**：只有 Claude Code 一家訂閱的話不需要（Hermes 原生支援 `CLAUDE_CODE_OAUTH_TOKEN`）。要池化多家 CLI 訂閱才值得加第二個 Railway service。分析見 [`plan/06`](./plan/06-model-provider-evaluation.md)。
- **`fallback_providers`**：住在 `config.yaml`，是 list 結構，`hermes config set` 的點分語法不適用。目前需 `railway ssh` 手動設一次。強烈建議設 —— Claude Code 訂閱是滾動時間窗限額，而這是無人值守負載，撞頂後代理人會整段啞掉。
- **待驗證假設 A1–A25**：見 [`plan/05`](./plan/05-risks-and-verification.md) §2。其中 **A1（容器是否拿得到 PID 1）** 最關鍵，第一次部署就要從 log 確認。
