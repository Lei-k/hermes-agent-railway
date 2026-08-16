# 01 — Hermes Agent 架構解析（以部署為視角）

本文只涵蓋「要把它跑在 Railway 上必須知道的事」。所有結論都來自 `../hermes-agent` 原始碼與 `website/docs`，並標註出處。

---

## 1. 這是什麼

Hermes Agent 是 Nous Research 的自我改進型 AI 代理人。與部署有關的三個要點：

- **它是長駐程序，不是 request/response 服務。** 核心是 `hermes gateway run`——一個常駐的 gateway 程序，主動連上 Telegram / Discord / Slack / WhatsApp / Signal / Matrix / Email 等平台，並託管內建 cron 排程器。
- **它有大量本地狀態。** session 歷史、記憶、技能（skills）、cron 定義、憑證全部落在磁碟上的 `$HERMES_HOME`，而且是 SQLite（含 FTS5）。**沒有持久磁碟就等於每次部署失憶。**
- **它有一個 web dashboard**（`hermes dashboard`），是瀏覽器端的管理介面，並內嵌完整 TUI chat（透過 PTY + WebSocket）。

---

## 2. 官方容器映像的執行模型

出處：`Dockerfile`、`docker/`、`website/docs/user-guide/docker.md`

### 2.1 映像堆疊

`Dockerfile` 是四階段建置：

| 階段 | 內容 |
|---|---|
| `sqlite_build` | 從原始碼編 SQLite 3.53.4（Debian 13 的 3.46.1 有 WAL-reset 損毀 bug），開啟 FTS3/4/5、RTree、Session 等編譯旗標 |
| `uv_source` | 取 `ghcr.io/astral-sh/uv` 的 `uv`/`uvx` 二進位 |
| `node_source` | 取 `node:26-bookworm-slim` 的 node + npm（trixie 內建 Node 20 已 EOL） |
| 最終 `debian:13.4` | 系統套件（ripgrep/ffmpeg/git/openssh-client/docker-cli）、s6-overlay v3、npm install + Playwright Chromium、`uv sync --frozen` 裝 `[all,messaging,otlp,anthropic,bedrock,azure-identity,hindsight,matrix]`、建置 `web/` 與 `ui-tui/` 前端 |

Docker Hub 上 `v2026.8.13` 壓縮後約 937 MB（arm64 + amd64 manifest）。上游註解自述冷建置 15–45 分鐘。

### 2.2 PID 1 與啟動鏈

`ENTRYPOINT ["/opt/hermes/docker/entrypoint-dispatch.sh"]`，`CMD []`。

`entrypoint-dispatch.sh` 判斷自己是否為 PID 1：

- **是 PID 1**（一般 Docker/Podman）→ `exec /init /opt/hermes/docker/main-wrapper.sh "$@"`，走完整 s6-overlay 監管樹。
- **不是 PID 1**（Fly Machines、`docker run --init`、部分 K8s/Nomad）→ 印警告、手動跑 `stage2-hook.sh`、再 `exec main-wrapper.sh`。**此路徑下 dashboard 與 per-profile gateway 這些受監管服務全部不會啟動。**

> **對 Railway 的意義**：必須確認容器拿得到 PID 1。若落到 fallback 路徑，dashboard 不會起來、healthcheck 會失敗——這是部署後第一件要從 log 確認的事（fallback 會印出 `WARNING: container entrypoint is not PID 1`）。

### 2.3 s6 開機序列（PID 1 路徑）

`/init` 依序執行：

1. **`/etc/cont-init.d/01-hermes-setup`** = `docker/stage2-hook.sh`（root 身分）
   - 拒絕 `docker run --user <任意 uid>` 的啟動方式（bootstrap 需要 root）
   - `HERMES_UID`/`HERMES_GID`（別名 `PUID`/`PGID`）→ `usermod`/`groupmod` 重映射 `hermes` 使用者（預設 UID 10000）
   - **針對性** chown `$HERMES_HOME` 的 hermes 專屬子目錄（刻意不做全樹 `chown -R`，以免破壞 bind mount 的宿主檔案）
   - 建立目錄骨架：`backups cron sessions logs logs/gateways hooks memories skills skins plans workspace home pairing platforms/pairing lazy-packages`
   - **首次開機 seed 設定檔**：`.env` ← `.env.example`、`config.yaml` ← `cli-config.yaml.example`、`SOUL.md` ← `docker/SOUL.md`（`[ ! -f ]` 保護，不覆蓋既有檔）
   - 若 `.env` 沒有 `API_SERVER_KEY`，**自動產生一組 32-byte 隨機值寫入 `.env`**
   - `chmod 600 .env`
   - 跑 `scripts/docker_config_migrate.py` 做非互動式 config schema migration（`HERMES_SKIP_CONFIG_MIGRATION=1` 可跳過）
   - `HERMES_AUTH_JSON_BOOTSTRAP` → 首次寫入 `auth.json`（僅在檔案不存在時）
   - **`HERMES_GATEWAY_BOOTSTRAP_STATE=running` → 首次寫入 `gateway_state.json`**（見下）
   - 同步內建 skills、偵測 Playwright Chromium 路徑並寫入 `/run/s6/container_environment/AGENT_BROWSER_EXECUTABLE_PATH`

2. **`/etc/cont-init.d/015-supervise-perms`**

3. **`/etc/cont-init.d/02-reconcile-profiles`** = `python -m hermes_cli.container_boot`
   - `/run/service/` 是 tmpfs，每次重啟被清空；此腳本走訪 volume 上的 `$HERMES_HOME/profiles/<name>/`，重建每個 profile 的 s6 service slot
   - **只有上次記錄狀態為 `running` 的 profile 才會自動啟動**。全新 volume 上沒有 `gateway_state.json` → gateway **不會**自動起來。這就是 `HERMES_GATEWAY_BOOTSTRAP_STATE=running` 存在的原因。

4. **啟動 s6-rc 服務**：`main-hermes`（其實只是 `sleep infinity` 的佔位服務）與 `dashboard`

5. **exec CMD 作為容器主程式**（`main-wrapper.sh`）
   - 無參數 → `hermes`
   - 第一個參數是 PATH 上的可執行檔 → 直接 exec
   - 其他 → `hermes <args>`（子命令直通）
   - 透過 `s6-setuidgid hermes` 降權；容器隨此主程式結束而結束

> `cont-init.d` 依**字典序**執行。要插入自己的開機腳本並確保在 gateway 被拉起之前跑完，命名必須排在 `02-reconcile-profiles` 之前——`016-xxx` 是安全的（`016` < `02`，字元比較 `1` < `2`）。

### 2.4 `gateway run` 在容器內是被監管的

出處：`website/docs/user-guide/docker.md`

在官方映像內執行 `gateway run` 時，**CMD 那個程序本身只是一個 `sleep infinity` 心跳**，真正的 gateway 由 s6 監管、崩潰後數秒內自動重啟。`docker stop` 仍能乾淨關閉全部。`--no-supervise` 或 `HERMES_GATEWAY_NO_SUPERVISE=1` 可退回舊語意（gateway 就是主程序，它退出容器就退出）。

> **對 Railway 的意義**：預設的受監管模式更好——gateway 崩潰時容器不會死、不會觸發 Railway 重新部署、volume 不會反覆重掛。保持預設。

### 2.5 不可變安裝樹

`/opt/hermes` 是 root 所有、對 `hermes` 使用者唯讀。執行期 `.pyc` 寫入與 lazy install 都被關閉（`PYTHONDONTWRITEBYTECODE=1`、`HERMES_DISABLE_LAZY_INSTALLS=1`）。選用後端的 lazy install 被導向 `HERMES_LAZY_INSTALL_TARGET=/opt/data/lazy-packages`（在 volume 上，附加在 `sys.path` **尾端**，只能新增模組不能遮蔽核心模組）。

> 這代表：代理人可以自我改進 skills / memory / plugins / config（都在 `/opt/data`），但改不動核心程式碼。要改核心就得重建映像。

---

## 3. 連接埠與網路面

| 服務 | 預設埠 | 預設綁定 | 開啟條件 |
|---|---|---|---|
| Web dashboard | `9119` | 容器內 `0.0.0.0` | `HERMES_DASHBOARD=1` |
| OpenAI 相容 API server | `8642` | `127.0.0.1` | `API_SERVER_ENABLED=true` |
| Telegram webhook server | `8443` | — | 設定 `TELEGRAM_WEBHOOK_URL` 時 |

出處：`docker/s6-rc.d/dashboard/run`、`website/docs/user-guide/features/api-server.md`、`website/docs/user-guide/messaging/telegram.md`

環境變數：`HERMES_DASHBOARD_HOST`（容器內預設 `0.0.0.0`）、`HERMES_DASHBOARD_PORT`、`API_SERVER_HOST`、`API_SERVER_PORT`、`TELEGRAM_WEBHOOK_PORT`。

### 3.1 Dashboard 驗證閘（重要）

出處：`website/docs/user-guide/features/web-dashboard.md`、`hermes_cli/dashboard_auth/`

- 綁定位址**不是** `127.0.0.1`/`::1`/`localhost` 時，驗證閘**自動開啟**。
- 閘開啟但沒有註冊任何 `DashboardAuthProvider` → **啟動時 fail closed，直接拒絕綁定**（非互動環境如 Docker/s6 不會出現互動式補救提示）。
- `--insecure` / `HERMES_DASHBOARD_INSECURE` 自 2026-06 起是 **no-op**，不再能關掉驗證。原因寫在文件裡：未驗證的公開 dashboard 是 2026 年 6 月 MCP-config 持久化攻擊活動的入口。
- 三種內建 provider：
  - `basic` — 帳號密碼（`HERMES_DASHBOARD_BASIC_AUTH_USERNAME` + `_PASSWORD_HASH`/`_PASSWORD` + `_SECRET`）。**官方明文警告：僅適用受信任網路 / VPN，不適合直接對公網暴露。**
  - `nous` — Nous Portal OAuth（`HERMES_DASHBOARD_OAUTH_CLIENT_ID`，由 `hermes dashboard register` 產生）。**這是官方指定可對公網暴露的 provider。**
  - `self_hosted` — 自建 OIDC（`HERMES_DASHBOARD_OIDC_ISSUER` + `_CLIENT_ID`）。

> **對 Railway 的意義**：Railway domain 就是公網。**必須**至少設定一種 provider，否則 dashboard 根本起不來——是 fail closed 拒絕啟動，不是「放行但不驗證」，所以**前置代理（Cloudflare Access 等）不能取代 provider**。本計畫採 `self_hosted` OIDC 走託管型 IdP（Auth0 / Zitadel Cloud / Okta 都能開 public PKCE client，不需自建），詳見 `04` §1.2。反向代理後方的 callback 需要 `HERMES_DASHBOARD_PUBLIC_URL`。
>
> 另有一個 `drain` provider（`plugins/dashboard_auth/drain`）走非互動式 bearer token（`supports_token` + `verify_token`），由 `HERMES_DASHBOARD_DRAIN_SECRET` 供給、只授權 `/api/gateway/drain` 一個端點，且弱密鑰（< 256 bits）會在註冊時被拒。它是 service-to-service 用的，不能當人類登入的 provider。

### 3.2 免驗證的健康檢查端點

出處：`hermes_cli/dashboard_auth/public_paths.py`

`PUBLIC_API_PATHS` 這個 frozenset 定義了繞過驗證閘的路徑，兩個 middleware 共用：

```
/api/health          ← 最精簡的程序存活探針（刻意避開 gateway config / plugin 冷載入）
/api/status          ← 版本、gateway 狀態、活躍 session 數、驗證閘型態
/api/config/defaults, /api/config/schema
/api/model/info
/api/dashboard/themes, /api/dashboard/plugins
/api/cron/fire       ← 自帶 NAS-minted JWT 驗證
```

該檔案的註解明確要求這個清單裡的每個端點都必須能安全地暴露給「外部 uptime 探針（Pingdom、Better Stack）」。

> **`/api/health` 就是 Railway healthcheck 的正解。**

### 3.3 API Server 的安全模型

- `API_SERVER_KEY` 是**每個部署都必填**，連 loopback 綁定也一樣。
- api_server 提供代理人的**完整工具集，包含 terminal 指令執行**。
- 啟動時會檢查 key 長度（≥16 字元）。
- 預設不開 CORS；`API_SERVER_CORS_ORIGINS` 才是白名單。
- 併發上限 `gateway.api_server.max_concurrent_runs` 預設 10，超過回 429。

---

## 4. 狀態與持久化

出處：`website/docs/user-guide/docker.md`、`docker/stage2-hook.sh`

`/opt/data`（= `$HERMES_HOME`）是**唯一**真實來源：

| 路徑 | 內容 |
|---|---|
| `.env` | API keys 與密鑰（`chmod 600`） |
| `config.yaml` | 全部 Hermes 設定 |
| `SOUL.md` | 代理人人格 |
| `auth.json` | OAuth refresh token（Nous Portal 等） |
| `sessions/` | 對話歷史 |
| `memories/` | 持久記憶 |
| `skills/` | 已安裝技能 |
| `home/` | 工具子程序（git/ssh/gh/npm）的 HOME |
| `cron/` | 排程定義 |
| `hooks/`, `logs/`, `skins/`, `plans/`, `workspace/` | 其餘執行期狀態 |
| `state.db`, `hermes_state.db`, `response_store.db` | SQLite（含 `-wal`/`-shm`） |
| `profiles/<name>/` | 多 profile 的獨立狀態 |
| `lazy-packages/` | 選用後端的執行期 pip 安裝目標 |

> **官方警告：絕對不要讓兩個 gateway 容器同時對同一個資料目錄寫入**——session 檔與 memory store 不支援並行寫入。

資源建議（官方）：記憶體最低 1 GB、建議 2–4 GB（開瀏覽器工具則至少 2 GB）；volume 最低 500 MB、建議 2 GB 以上。

---

## 5. 設定與環境變數解析順序（部署時最容易踩的坑）

出處：`hermes_cli/env_loader.py:470-522`

`load_hermes_dotenv()` 的實際行為：

```python
if user_env.exists():                                  # $HERMES_HOME/.env
    _load_dotenv_with_fallback(user_env, override=True)   # ← override=True
    _clear_known_keys_missing_from_dotenv(user_env)
```

**`/opt/data/.env` 是以 `override=True` 載入的——它會蓋掉平台注入的環境變數。**

這與 `website/docs/user-guide/docker.md` 裡「Direct `-e` flags override values from `.env`」的敘述相反。實測結論應以程式碼為準，並在 `05` 的驗證清單中列為必測項目。

實務上的三個推論：

1. **只要某個 key 出現在 `/opt/data/.env`，Railway 的服務變數就無效。** 特別是跑過 `hermes setup`（會把 API key 寫進 `.env`）之後，Railway 上同名變數就不再生效——這會造成「我改了 Railway 變數但沒作用」的困惑。
2. **`API_SERVER_KEY` 幾乎必定被 `.env` 蓋掉**：`stage2-hook.sh` 在 `.env` 沒有這個 key 時會自動產生一組寫進去，之後載入時 `.env` 勝出。要指定自己的值，必須寫進 `.env`（或用 `hermes config set`），不能只靠 Railway 變數。
3. **好消息**：`.env.example` 裡的 API key 全部是註解掉的（只有 `TERMINAL_TIMEOUT`、`BROWSER_SESSION_TIMEOUT`、`*_DEBUG` 等少數無害預設是啟用的），所以首次 seed 出來的 `.env` **不會**遮蔽 provider 金鑰。

`_clear_known_keys_missing_from_dotenv` 的清除範圍很窄（只有 `_PROFILE_MANAGED_ENV_KEYS`，即 ACP auth method、copilot-ACP endpoint 這類「決定走哪條 provider 路徑」的行為變數），**provider API key 刻意排除在外**，不會被清掉。

### 5.1 model 設定不是環境變數驅動的

`model.provider` / `model.model` 住在 `config.yaml`，沒有對應的環境變數（`HERMES_MODEL` 只是 process 層級的覆寫，文件註明是給 cron 排程器用的）。非互動式落地 model 設定的方式：

```bash
hermes config set model openrouter/anthropic/claude-sonnet-4   # provider/model 一次設定
hermes config set model.provider openrouter
hermes config set terminal.backend local
```

`hermes config set` 會自動分流：API key → `.env`，其他 → `config.yaml`（出處：`website/docs/user-guide/configuration.md:50`）。

> **在「憑證統一管在 Railway 變數」的模型下，這個自動分流是雙面刃**：對 `model`、`terminal.backend` 這類非憑證設定很好用；但 `hermes config set <某個 API_KEY>` 會把值寫進 `.env`，而 `.env` 以 `override=True` 載入——等於永久遮蔽同名的 Railway 變數。詳見 `04` §2 的操作紀律。

---

## 5.2 Model provider 與憑證解析

Hermes 支援數十家 provider，與本計畫相關的兩點：

**Claude Code 憑證是原生支援的**（出處：`website/docs/reference/environment-variables.md:108`、`skills/.../providers-and-models.md:12`、`website/docs/developer-guide/provider-runtime.md:132-137`）：

- `provider: anthropic` 接受 `ANTHROPIC_API_KEY` **或** `CLAUDE_CODE_OAUTH_TOKEN`
- 憑證解析**優先採用可刷新的 Claude Code credentials**，其次才是複製進來的 env token
- 原生 Messages API 呼叫前會先 preflight 憑證刷新；401 時重建 client 再重試一次

**三層韌性機制**（出處：`website/docs/user-guide/features/fallback-providers.md`、`credential-pools.md`）：

```
請求
 → 憑證池：同 provider 多把 key 輪替
     └─ 收到「plan/usage limit reached」型 429 → 立刻換下一把（不重試，因為重試也不會過）
     └─ 一般 transient 429 → 同一把重試一次，再 429 才輪替
 → 池子全空 → fallback_providers 切換到不同 provider（不中斷對話）
 → auxiliary task（vision / 壓縮 / 網頁擷取）有獨立的 provider 解析
```

`fallback_providers` 是 `config.yaml` 的頂層 list，需要 `provider` + `model` 兩個欄位。

> **注意**：憑證池輪替會重置 provider 端的 prompt cache（cache 綁在 account/API key 上），長對話每次輪替要付一次全額 context 重讀。

---

## 5.3 瀏覽器工具後端

出處：`website/docs/user-guide/features/browser.md`、`website/docs/reference/environment-variables.md:159`

| 後端 | 本地資源 | 需求 |
|---|---|---|
| **agent-browser + 本地 Chromium**（預設） | 2 GB+ | 映像已內建 Playwright Chromium 於 `/opt/hermes/.playwright`；`stage2-hook.sh` 開機自動偵測並設 `AGENT_BROWSER_EXECUTABLE_PATH` |
| **Lightpanda** 本地引擎 | 記憶體低 16 倍、快 9 倍 | 需自行安裝 binary；`AGENT_BROWSER_ENGINE=lightpanda`。專為「長期跑在小 VM 上的 agent」設計 |
| **Browserbase / Browser Use / Firecrawl** 雲端 | ~0 | 一組 API key |
| **Nous Portal Tool Gateway** | ~0 | Portal 訂閱含 cloud browser（Browser Use） |
| Camofox / CDP 連本機瀏覽器 | — | 不適用容器部署 |

**容器環境的 `/dev/shm` 問題已被上游處理**：

> `AGENT_BROWSER_ARGS` — Hermes **auto-injects `--no-sandbox,--disable-dev-shm-usage`** when running as root or on AppArmor-restricted unprivileged user namespaces (Ubuntu 23.10+, DGX Spark, **many container images**); set this manually only to override or add other flags.

**但手動設定會停用自動注入**，所以要嘛不設、要嘛把兩個 flag 都寫齊。另外容器內受監管服務是以 `hermes`(UID 10000) 執行而非 root，自動注入是否命中需實測。

---

## 6. 多 profile 與監管

出處：`website/docs/user-guide/docker.md`

官方推薦**一個容器承載所有 profile**，而不是一個 profile 一個容器：

- `hermes profile create <name>` 會在 `/run/service/gateway-<name>/` 動態註冊 s6 service slot，不需重建容器
- 崩潰由 `s6-supervise` 以退避策略自動重啟
- per-profile 輪替日誌在 `$HERMES_HOME/logs/gateways/<name>/current`（10 份 × 1 MB）
- 容器重啟時由 `02-reconcile-profiles` 依 `gateway_state.json` 還原

**每個 profile 的 api_server 預設都綁 8642**，沒有自動配埠。要跑第二個 profile 的 api_server，必須在**該 profile 自己的** `.env` 裡設不同的 `API_SERVER_PORT`（不能放在容器層級的環境變數，否則所有 profile 撞埠）。

Dashboard 則是**機器層級**：一個 dashboard 服務所有 profile，靠側邊欄的 profile 切換器（`?profile=<name>`）決定讀寫目標。所以多 profile 不需要多開 dashboard 埠。

---

## 7. 日誌落點

| 來源 | 落點 |
|---|---|
| per-profile gateway | 同時 tee 到容器 stdout **和** `$HERMES_HOME/logs/gateways/<profile>/current`（輪替） |
| dashboard | 容器 stdout（無前綴，與 gateway 交錯） |
| 開機還原器 | `$HERMES_HOME/logs/container-boot.log`（append-only 稽核） |
| 一般 Hermes 日誌 | `$HERMES_HOME/logs/`（`agent.log`、`errors.log`），用 `hermes logs --follow` 讀 |

> 容器 stdout 會被 Railway 收成 deploy logs。`logs/gateways/<profile>/current` 在 volume 上，跨重啟保留——這在 Railway 上特別有價值，因為 Railway 的 log 保留期有限。

---

## 8. 平台連線模式：polling vs webhook

出處：`website/docs/user-guide/messaging/telegram.md:246-300`、`plugins/platforms/telegram/adapter.py:4198`

Telegram 預設用 **long polling**（gateway 主動對外拉更新）。上游文件明確提到 Railway：

> For **cloud deployments (Fly.io, Railway, Render, etc.)**, webhook mode is more cost-effective. These platforms can auto-wake suspended machines on inbound HTTP traffic, but not on outbound connections. Since polling is outbound, a polling bot can never sleep.

webhook 模式：`TELEGRAM_WEBHOOK_URL`（路徑會自動從 URL 擷取）+ **必填** `TELEGRAM_WEBHOOK_SECRET`（沒有它 gateway 拒絕啟動，見 GHSA-3vpc-7q5r-276h）+ 選填 `TELEGRAM_WEBHOOK_PORT`（預設 8443）。

> **對 Railway 的意義**：webhook 需要**第二個對外埠**（Railway 一個 domain 只綁一個 target port）。第一階段建議用 polling——設定為零，且掛了 volume 的 Railway service 本來就不會 scale to zero，polling 的「機器無法休眠」缺點在此不成立。
