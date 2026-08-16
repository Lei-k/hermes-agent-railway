# hermes-agent-railway

把 [Hermes Agent](https://github.com/NousResearch/hermes-agent)（fork：[`Lei-k/hermes-agent`](https://github.com/Lei-k/hermes-agent)）部署到 Railway。

完整的設計依據、平台限制分析與風險評估在 [`plan/`](./plan/)。這份 README 是操作手冊。

---

## 架構

```
        nousresearch/hermes-agent:v2026.8.13   （上游官方預建映像）
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

**為什麼用上游預建映像**：`Lei-k/hermes-agent` 目前與 upstream 零分歧（`behind_by=0`，沒有任何自己的 commit），自建一份沒有意義 —— 上游 Dockerfile 冷建置要編 SQLite、抓 s6-overlay、裝 Playwright、`uv sync` 八個 extras、建兩個前端，上游自己把該 job 的 timeout 設在 45 分鐘、映像 5GB+。直接用官方發布的版本標籤，**fork repo 完全不用動**，Railway 端每次部署只建薄封裝。

多數客製化也不需要 fork —— 見下方「[客製化](#客製化)」。

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

---

## 部署

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

## 客製化

**不需要 fork。** 幾乎所有客製化都能疊在這一層薄封裝上，因為 Railway 建置時是 root，可以往映像裡寫任何東西：

| 想改什麼 | 做法 | 放哪 |
|---|---|---|
| Dashboard auth provider | `COPY` 進 `/opt/hermes/plugins/dashboard_auth/<name>/` | 映像（root-only，代理人改不動） |
| 自訂 plugin | `COPY` 進 `/opt/hermes/plugins/` | 映像 |
| 自訂 skill | `COPY` 進 `/opt/hermes/skills/`（開機時 `skills_sync.py` 會同步） | 映像 |
| SOUL.md 人格 | `COPY` 覆蓋 `/opt/hermes/docker/SOUL.md`（首次開機 seed 用） | 映像 |
| config 預設值 | `HERMES_BOOTSTRAP_CONFIG` 環境變數，或 `COPY` 覆蓋 `/opt/hermes/cli-config.yaml.example` | 變數／映像 |
| 系統套件 | `RUN apt-get update && apt-get install -y ...` | 映像 |
| Python 套件 | `RUN /opt/hermes/.venv/bin/pip install ...`（build 階段是 root，venv 可寫；只有 runtime 是封死的） | 映像 |
| npm 工具 | `RUN npm i -g ...` | 映像 |
| 執行期才要的可選後端 | `HERMES_LAZY_INSTALL_TARGET=/opt/data/lazy-packages`（已預設） | volume |

**只有改 Hermes 核心原始碼**（`cli.py`、`run_agent.py`、`hermes_state.py`、agent loop⋯）才真的需要自建映像。屆時有兩條路：

1. **小修補**：在薄封裝裡 `COPY patches/xxx.py /opt/hermes/xxx.py` 覆蓋單一檔案。editable install 指向 `/opt/hermes`，所以直接生效。跨版本升級時容易失效，適合臨時修補。
2. **完整自建**：把建置流水線放在 **本 repo** 的 GitHub Actions（checkout `Lei-k/hermes-agent` 為第二個 source，建好推 GHCR），`Dockerfile` 改指向那個映像。**fork repo 依然不用動。** 完整 workflow 見 [`plan/03`](./plan/03-implementation-plan.md) 附錄。

---

## 維運

### 憑證管理紀律 ⚠️

`$HERMES_HOME/.env` 是以 `override=True` 載入的（`hermes_cli/env_loader.py:500`），**會蓋掉 Railway 注入的環境變數**。憑證統一管在 Railway 變數，所以：

- **不要跑 `hermes setup`** — 它會把 API key 寫進 `.env`，從此同名的 Railway 變數永久失效
- **不要用 `hermes config set <某個 API_KEY>`** — 同樣路由到 `.env`
- `hermes config set` 只用於非憑證設定（`model`、`terminal.backend`、`tool_loop_guardrails`…）

唯一無解的例外是 `API_SERVER_KEY`：`stage2-hook.sh` 在 `.env` 缺它時一定會自動產生一組寫入。因為 api_server 維持 loopback、不對外可達，接受即可。

症狀是「改了 Railway 變數但沒作用」時，先查 `/opt/data/.env` 有沒有同名 key。

### 升級

上游大約每週發一個版本標籤（`v2026.7.1` → `v2026.8.13`）。升級只有一步：

```bash
# 看有哪些版本：https://hub.docker.com/r/nousresearch/hermes-agent/tags
# 改 Dockerfile 的 ARG HERMES_TAG，commit + push，Railway 自動重建（秒級）
```

也可以在 Railway service variables 設 `HERMES_TAG` 覆寫，升級時連程式碼都不用動。

開機時 `stage2-hook.sh` 會自動跑 `docker_config_migrate.py`，需要時把 `config.yaml`/`.env` 備份成時間戳檔案。

**回滾**：`HERMES_TAG` 改回舊標籤即可 —— Docker Hub 上舊版本都還在。

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
- **待驗證假設**：見 [`plan/05`](./plan/05-risks-and-verification.md) §2。其中 **A1（容器是否拿得到 PID 1）** 最關鍵，第一次部署就要從 log 確認。
