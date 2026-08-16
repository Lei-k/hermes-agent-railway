# Hermes Agent → Railway 部署計畫

本目錄是把 [`../hermes-agent`](https://github.com/Lei-k/hermes-agent.git)（Nous Research 的 Hermes Agent，此處為 `Lei-k` fork）部署到 [Railway](https://railway.com) 的完整實作計畫。

## 文件索引

| 檔案 | 內容 |
|---|---|
| [`01-hermes-agent-architecture.md`](./01-hermes-agent-architecture.md) | Hermes Agent 執行模型：容器架構、s6 監管樹、程序/連接埠、狀態存放、設定與環境變數解析順序 |
| [`02-railway-platform-constraints.md`](./02-railway-platform-constraints.md) | Railway 平台限制，以及每一項與 Hermes 的衝突點與對策 |
| [`03-implementation-plan.md`](./03-implementation-plan.md) | 分階段實作步驟、要建立的檔案與完整內容 |
| [`04-configuration-reference.md`](./04-configuration-reference.md) | Railway 服務變數對照表、密鑰產生方式、選用平台設定 |
| [`05-risks-and-verification.md`](./05-risks-and-verification.md) | 風險清單、待驗證假設、驗收檢查表、維運手冊 |
| [`06-model-provider-evaluation.md`](./06-model-provider-evaluation.md) | CLIProxyAPI 評估與 model provider 選項比較 |
| [`07-dashboard-access-control.md`](./07-dashboard-access-control.md) | Google 認證 + 使用者白名單（**Hermes 沒有內建白名單**，必讀） |

---

## 已確認的需求決策

| # | 決策 | 影響 |
|---|---|---|
| 1 | ~~fork 會有自訂修改~~ → **改為不侵入部署** | fork 目前與 upstream 零分歧（`behind_by=0`、無自有 commit），改用上游預建映像 `nousresearch/hermes-agent:v2026.8.13`。**fork repo 完全不動**，階段 0 取消。多數客製化可疊在薄封裝上；只有改核心原始碼才需要自建流水線（`03` 附錄） |
| 2 | **Railway Pro 方案** | 映像大小無限、volume 1 TB、記憶體充足。原本的容量顧慮全部解除 |
| 3 | **Google 認證 + 要能管理可進入的使用者** → **採用 Auth0** | Google 當 Auth0 的 social connection，白名單寫成 Auth0 post-login Action。**Hermes 沒有任何使用者白名單**，這是必須補的一層——見 [`07`](./07-dashboard-access-control.md) |
| 4 | **Telegram**（polling 模式） | 不佔額外對外埠 |
| 5 | **api_server 不對外** | 維持 loopback `127.0.0.1:8642`，只需一個 domain |
| 6 | **需要瀏覽器工具** | 風險比原評估低很多（見下方「關於 #6 的補充」） |
| 7 | **model provider** | CLIProxyAPI 方向正確；但只用 Claude Code 的話 Hermes 原生已支援，不需這一層（見 [`06`](./06-model-provider-evaluation.md)） |
| 8 | **憑證統一管在 Railway 變數** | 需要「純變數 bootstrap」路徑，不跑 `hermes setup` |
| 9 | **先做規劃** | 本目錄只有計畫，不建立實體檔案 |
| 10 | **自有網域 `relvo.cc`（不在 Cloudflare）** | 用子網域 `hermes.relvo.cc` → DNS 商是誰都無所謂（普通 CNAME + TXT）。`HERMES_DASHBOARD_PUBLIC_URL` 必須明確設定、Railway 產生的網域要移除。存取控制改推 **Auth0**（不碰 DNS） |

---

## 決策摘要（TL;DR）

**採用架構**：上游預建映像 + 一層薄封裝 + 單一 Railway service。**不動 fork repo**，Railway 只建薄封裝（秒級）。容器內由 s6-overlay 同時監管 gateway 與 web dashboard，dashboard 綁 `0.0.0.0:$PORT` 作為唯一對外入口，volume 掛 `/opt/data`。

```
        nousresearch/hermes-agent:v2026.8.13   （上游官方預建映像）
                         │ FROM（本 repo 的薄封裝，秒級建置）
┌─ Railway Service (Pro, 1 replica) ────────────────────────┐
│  ENTRYPOINT: entrypoint-dispatch.sh → /init (s6, PID 1)   │
│                                                            │
│   cont-init.d:  01-hermes-setup (chown/seed/migrate)       │
│                 015-supervise-perms                        │
│                 016-railway-bootstrap  ← 本專案新增        │
│                 02-reconcile-profiles  (拉起 gateway slot) │
│                                                            │
│   s6 服務:  gateway-default   ← 代理人本體、Telegram polling│
│             dashboard         ← 0.0.0.0:$PORT  ⇢ 對外      │
│   CMD:      gateway run       ← 容器主程式（心跳）          │
│   loopback: api_server 127.0.0.1:8642（不對外）            │
└──────────┬─────────────────────────────────────────────────┘
           │ Volume mount
      /opt/data  ← config.yaml / .env / sessions / memories / skills / cron
```

### 關鍵決策與理由

1. **用上游預建映像，不自建。**
   上游 `.github/workflows/docker.yml` 的 build job 有 `if: github.repository == 'NousResearch/hermes-agent'` 的守衛，**在 fork 上完全不會執行**，所以 fork 必須有自己的 workflow。不讓 Railway 直接建 fork 原始碼的原因：上游冷建置要編 SQLite、裝 Playwright、`uv sync` 全套 extras、建兩個前端，timeout 設 45 分鐘、映像 5 GB+；GitHub Actions 有 layer cache 且可只建 amd64（Railway 只跑 amd64，省一半時間），Railway 端則維持秒級建置。

2. **Railway 的 start command 必須留空。**
   它會**覆蓋映像的 ENTRYPOINT**，而 Hermes 的 `entrypoint-dispatch.sh` 承載整條 s6 bootstrap（volume chown、`.env`/`config.yaml` seed、config schema migration、監管樹）。把 `CMD ["gateway","run"]` 烤進薄封裝映像，start command 就能留空。

3. **dashboard 當唯一對外入口。**
   Railway 一個 domain 只綁一個埠。dashboard 是完整管理介面 + 內嵌 TUI chat，且有 `/api/health` 這個免驗證輕量端點正好當 healthcheck。多 profile 也只需這一個埠（dashboard 是機器層級的，靠側邊欄切換器）。

4. **一個 service、一顆 volume、固定 1 replica。**
   Hermes 明文禁止兩個 gateway 同時寫同一個資料目錄。Railway 掛了 volume 的 service 本來就無法同時存在兩個 active deployment，方向一致。

5. **純變數 bootstrap，不跑 `hermes setup`。**
   因為你選了「憑證統一管在 Railway 變數」，而 `/opt/data/.env` 是以 `override=True` 載入、會蓋掉平台變數（`hermes_cli/env_loader.py:500`）——跑了 `hermes setup` 就會把 key 寫進 `.env`，從此 Railway 變數失效。所以走 `016-railway-bootstrap` 開機腳本 + `hermes config set` 只落地非憑證類設定（model、terminal backend）。

---

## 關於 #2/#3 的補充：Google 可以用，但白名單要自己補

**兩個更正／發現**（詳見 [`07`](./07-dashboard-access-control.md)）：

1. **Google 直接可用。** 我先前說「self_hosted plugin 不支援 confidential client，所以 Google 的 Web application client 不能用」——查原始碼後這是錯的，**文件頁面已過時**。`plugins/dashboard_auth/self_hosted/__init__.py:35-46` 明確支援 public (PKCE-only) 與 confidential (PKCE + `client_secret`) 兩種，環境變數 `HERMES_DASHBOARD_OIDC_CLIENT_SECRET` 存在。原本的待驗證項 A13 解除。

2. 🔴 **Hermes 沒有任何使用者白名單。** `dashboard.oauth.self_hosted` 的設定面只有 `issuer` / `client_id` / `client_secret` / `scopes`；provider 驗完 ID token 簽章與 `iss`/`aud`/`exp` 就直接建立 session。**若把 Google 當 issuer 且同意畫面是 External，全世界任何一個 Google 帳號都能登入——而 dashboard 等同容器內的 shell。**

**已決定走 Auth0**（`relvo.cc` 不在 Cloudflare，Auth0 不碰 DNS）。三層防線：

| 層 | 機制 | 管理位置 |
|---|---|---|
| 1 | Google 同意畫面設 **Internal** | Google Cloud Console（選配，需 Workspace） |
| 2 | **Auth0 post-login Action** 的 email 白名單 + `email_verified` 檢查 | Auth0 UI，**改了即時生效，不用 redeploy** |
| 3 | Auth0 只掛 Google connection，**Database connection 關閉**（否則可自助註冊） | Auth0 UI |

Hermes 端只需 bundled 的 `self_hosted` provider + 三個環境變數，**不用寫 plugin**，連帶少掉 A18/A19 兩個待驗證項。Auth0 免費方案 25,000 MAU、social connection 無限、免信用卡，且不需要 Auth0 的自訂網域。

被拒的使用者會拿到 `400 OAuth error from provider: access_denied (...)` 並在稽核日誌留下 `LOGIN_FAILURE` — 已從 `hermes_cli/dashboard_auth/routes.py:473-485` 確認，不會是 500。

被否決的選項：Cloudflare Access（要搬 nameserver）、Google 直連 + 自寫 plugin（改名單要 redeploy、多一支程式碼要維護，保留在 `07` 附錄 A）。

---

## 關於 #6 的補充：瀏覽器工具的風險比原估低

原本擔心 Railway 無法設 `--shm-size`（Docker 預設 `/dev/shm` 只有 64 MB，Chromium 會掛）。查證後發現上游已經處理了：

> `AGENT_BROWSER_ARGS` — Hermes **auto-injects `--no-sandbox,--disable-dev-shm-usage`** when running as root or on AppArmor-restricted unprivileged user namespaces (…**many container images**)
> — `website/docs/reference/environment-variables.md:159`

而且 Playwright Chromium 已烤在映像的 `/opt/hermes/.playwright`，`stage2-hook.sh` 開機時會自動偵測並設好 `AGENT_BROWSER_EXECUTABLE_PATH`。

Railway + Pro 方案下有三個可行選項：

| 選項 | 記憶體 | 設定成本 | 備註 |
|---|---|---|---|
| **本地 Chromium**（映像內建） | 2 GB+ | 零（必要時手動設 `AGENT_BROWSER_ARGS`） | 自動注入偵測是否在 Railway 觸發需驗證（A14）；沒觸發就手動設一行變數 |
| **雲端瀏覽器** | ~0 | 一組 API key | Browserbase / Browser Use / Firecrawl / Nous Portal Tool Gateway。完全避開 shm 與記憶體問題 |
| **Lightpanda** 本地引擎 | 低 16 倍 | 需在薄封裝映像裝 binary | 專為「長期跑在小 VM 上的 agent」設計，`AGENT_BROWSER_ENGINE=lightpanda` |

**建議**：先用本地 Chromium（零額外成本，Pro 方案記憶體充足），驗證 A14；若不穩再切雲端瀏覽器。

---

## 下一步

計畫已完整。要動工時的順序是：階段 1（容器落地）→ 階段 2（代理人可用）→ 階段 3（安全）→ 階段 4（維運）。**fork repo 不需要任何改動。**

實體檔案（`Dockerfile`、`railway.toml`、`016-railway-bootstrap`）的完整內容都寫在 [`03-implementation-plan.md`](./03-implementation-plan.md) 裡，可直接複製使用。
