# 07 — Dashboard 存取控制：Google 認證 + 使用者白名單

回應需求 #2：**用 Google 認證，但要能管理誰可以進入系統。**

---

## 1. 兩個關鍵查證結果

### 1.1 ✅ Google 可以用（我先前說錯了）

先前根據文件頁面說「self_hosted plugin 不支援 confidential client，所以 Google 的 Web application client 不能用」。**查原始碼後這是錯的——文件頁面已過時。**

`plugins/dashboard_auth/self_hosted/__init__.py:35-46`：

> Both **public** (PKCE-only) and **confidential** (PKCE + `client_secret`) clients are supported. […] the provider additionally authenticates the client at the token endpoint, choosing `client_secret_basic` (HTTP Basic header) or `client_secret_post` (secret in the form body) from the IDP's advertised `token_endpoint_auth_methods_supported`. PKCE is sent in **both** modes — the secret is client authentication layered on top, never a replacement for PKCE (OAuth 2.1 / RFC 9700 keep PKCE mandatory regardless).

環境變數 `HERMES_DASHBOARD_OIDC_CLIENT_SECRET` 存在（`__init__.py:822`）。**原本的待驗證項 A13 解除**，Google Web application client 直接可用。

### 1.2 🔴 Hermes **沒有**任何使用者白名單

`dashboard.oauth.self_hosted` 的完整設定面只有 `issuer` / `client_id` / `client_secret` / `scopes`（`hermes_cli/config_defaults.py` 的 `dashboard:` 區塊已確認）。provider 的 `_verify_id_token()` 只驗簽章、`iss`、`aud`、`exp`，然後把 `sub`/`email`/`name`/`groups` 映射成 Session 就放行。

原始碼裡唯一提到 "allowlist" 的地方是 `_validate_redirect_uri()` 的註解「The IDP's own allowlist is authoritative」——那講的是 redirect_uri，不是使用者。

**後果**：如果直接把 Google 當 issuer 且 OAuth 同意畫面設為 **External**，**全世界任何一個 Google 帳號**只要走完流程就拿得到有效 session，而 dashboard 等同容器內的 shell（Hermes 的工具集含 terminal 執行）。

> 這是本計畫目前最高風險的單一設定項。存取控制**必須**明確處理，不能預設「用 Google 登入就安全」。

---

## 2. 部署網域：`relvo.cc`

已確認使用自有網域。建議 `hermes.relvo.cc`（或任何子網域）。這件事對存取控制有三個直接影響：

### 2.1 `HERMES_DASHBOARD_PUBLIC_URL` 從「選填」變成「必填」

原本 `016-railway-bootstrap` 會從 `RAILWAY_PUBLIC_DOMAIN` 自動推導公開網址。但 Railway 對這個變數的定義是「The public service or **customer** domain, of the form `example.up.railway.app`」——**加了自訂網域之後它取哪一個值，官方文件沒有說明**。

如果它仍然是 `xxx.up.railway.app`，OAuth callback 會被組成 `https://xxx.up.railway.app/auth/callback`，與 Google 註冊的 `https://hermes.relvo.cc/auth/callback` 不符，登入直接失敗（`redirect_uri_mismatch`）。

**對策：明確設死，不要依賴推導。**
```bash
HERMES_DASHBOARD_PUBLIC_URL=https://hermes.relvo.cc
```
`016-railway-bootstrap` 的推導邏輯是 `if [ -z "${HERMES_DASHBOARD_PUBLIC_URL:-}" ]`，所以顯式設定會勝出；推導只留作後備。列為待驗證 **A22**。

### 2.2 Railway 產生的網域是第二個入口，要拆掉

加了自訂網域後，`xxx.up.railway.app` **仍然是活的**，dashboard 從兩個 host 都到得了。雖然從那個 host 登入會因為 redirect_uri 不符而失敗，但它仍是一個對外暴露面（掃描器找得到、`/api/health` 與 `/api/status` 免驗證可讀）。

**確認自訂網域可用之後，把 Railway 產生的網域移除**，讓公開入口只有一個。

### 2.3 網域數量限制大幅放寬（Pro = 20 個）

| 方案 | 每個 service 的自訂網域數 |
|---|---|
| Trial | 1 |
| Hobby | 2 |
| **Pro** | **20**（可申請增加） |

原本「Railway 一個 domain 只綁一個埠」是個硬限制，現在有 20 個額度，`api.relvo.cc`（api_server:8642）、`tg.relvo.cc`（Telegram webhook:8443）這些都變成隨時可加。**不改變 #4/#5 的既有決策**（Telegram 仍用 polling、api_server 仍不對外），但要知道這個限制已經不再是理由。

### 2.4 DNS 設定

Railway 會給兩筆記錄，**兩筆都必須加，只加 CNAME 不會驗證通過**（會回 404）：

| 類型 | 用途 |
|---|---|
| `CNAME` | 指向 Railway 給的端點（如 `g05ns7.up.railway.app`） |
| `TXT` | 網域所有權驗證 |

- Railway 自動簽發 Let's Encrypt 憑證（90 天、剩 30 天自動續），DNS 生效後通常一小時內完成
- **`relvo.cc` 目前不在 Cloudflare——但因為用子網域 `hermes.relvo.cc`，DNS 商是誰都無所謂**：一筆普通 CNAME + 一筆 TXT，任何 DNS 服務都支援。Apex 根網域才需要 CNAME flattening / ALIAS（Cloudflare、DNSimple、Namecheap、bunny.net 支援；Route 53、GoDaddy、Azure DNS 不支援），用子網域完全繞開這個限制。
- 若日後把 DNS 搬到 Cloudflare 並開 proxy（橘雲）：`_acme-challenge` 記錄必須關閉 proxy，否則憑證簽不出來；SSL/TLS 模式要設 **Full (strict)**，否則會有重導迴圈

---

## 3. 決策：Auth0 + Google（已確認）

Google 當 Auth0 的 social connection，白名單用 Auth0 的 post-login Action。使用者體驗仍是「用 Google 登入」，但存取控制在 Auth0。

**為什麼是這個組合**：

- **不碰 DNS。** `relvo.cc` 不在 Cloudflare，而 Cloudflare Access 那條路要把整個 zone 的 nameserver 搬過去——只為 dashboard 門禁動到網域上所有服務，不划算。Auth0 是託管服務，與 DNS 完全無關。
- **改名單即時生效。** 編輯 Auth0 Action 就好，不用 redeploy、不用改 Railway 變數。
- **Hermes 端零程式碼。** 用 bundled 的 `self_hosted` provider，不需要自寫 allowlist plugin（附錄 A 保留該方案供參考），連帶少掉 A18/A19 兩個待驗證項。
- **免費額度綽綽有餘**：25,000 MAU、social connection 無限（Google 含在內）、5 個 Actions、5 個 Organizations、註冊免信用卡。
- **不需要 Auth0 的自訂網域**（免費方案的那 1 個要信用卡驗證）——預設的 `<tenant>.<region>.auth0.com` 就是 OIDC issuer。
- 附帶拿到登入稽核日誌、MFA、暴力破解防護。

被否決的選項：**Cloudflare Access**（要搬 nameserver）、**Google 直連 + 自寫 plugin**（改名單要 redeploy、多一支程式碼要維護）、**只靠 Google 直連**（等於沒有白名單）。

Google 同意畫面設 **Internal** 仍值得做（若你的公司網域掛在 Workspace 上），當作 Auth0 白名單之外的第一層——見第 4 節。

---

## 4. 第一層（選配）：Google 同意畫面設 Internal

Auth0 的 Google social connection 需要一組你自己的 Google OAuth client（Auth0 有開發用的共用 key，但正式部署應該用自己的）。建這組 client 時順手把範圍收窄：

1. **Google Cloud Console → APIs & Services → OAuth consent screen → User Type = Internal**
   只有你的 Google Workspace 組織內的帳號能通過。External 則是全世界。
2. **Credentials → Create OAuth client ID → Web application**
3. Authorized redirect URI 填 **Auth0 的** callback：`https://<tenant>.<region>.auth0.com/login/callback`
   ⚠️ 不是 Hermes 的 callback——這一層是 Auth0 對 Google。Hermes 的 callback 設在 Auth0 的 Application 裡。
4. 把 `client_id` / `client_secret` 填進 Auth0 的 Google connection

> **Internal 的前提是你的公司網域掛在 Google Workspace 上，且 GCP 專案屬於該組織。** 若只是一般 Gmail 或非 Workspace 網域，Internal 選項不會出現——沒關係，Auth0 的 Action 白名單才是主要防線，這一層只是加分。
>
> 對外服務的網域是 `relvo.cc`，與同意畫面的 Internal/External 判定**無關**——後者看的是 GCP 專案所屬的 Workspace 組織，不是服務架在哪個網域。

---

## 5. Auth0 設定步驟

### 5.1 建立 tenant 與 Google connection

1. **註冊 Auth0，建立 tenant**，記下預設網域 `<tenant>.<region>.auth0.com`（例：`relvo.us.auth0.com`）。這就是 OIDC issuer，不需另購自訂網域。
2. **Authentication → Social → Create Connection → Google**，填入第 4 節建立的 Google `client_id` / `client_secret`。
3. **Authentication → Database**：把預設的 `Username-Password-Authentication` connection **停用或不掛到 Application 上**。留著它等於開放任何人自助註冊一個帳號——白名單只比對 email，而自助註冊的 email 是使用者自己填的。

### 5.2 建立 Application

**Applications → Create Application**

- 型別選 **Regular Web Application**（confidential，帶 `client_secret`）。SPA（public + PKCE）也可以，Hermes 兩種都支援，但 Regular Web App 搭 refresh token 較單純。
- **Allowed Callback URLs** = `https://hermes.relvo.cc/auth/callback`
- **Allowed Logout URLs** = `https://hermes.relvo.cc/`
- **Connections** 分頁：只勾 Google，取消勾選所有 Database connection

### 5.3 白名單 Action

**Actions → Library → Build Custom → 選 Login / post-login trigger**：

```javascript
exports.onExecutePostLogin = async (event, api) => {
  const allowed = [
    'you@your-company.example',
  ];
  const email = (event.user.email || '').toLowerCase();
  if (!event.user.email_verified || !allowed.includes(email)) {
    api.access.deny('Not authorized for this application.');
  }
};
```

Deploy 後把它拖進 **Login flow** 並 Apply。**之後改名單只要編輯這個 Action，即時生效，不必碰 Railway。**

> 白名單清單請填實際要放行的帳號。**這個 repo 是公開的**，文件與範本一律只放佔位符，真實信箱只存在於 Auth0 的 Action 與 Railway 變數裡。


> **`email_verified` 的檢查不可省。** 沒有它，只要任何一個 connection 允許自助註冊，攻擊者就能建一個宣稱是白名單 email 的帳號。5.1 關掉 Database connection 是第二道保險，兩者都要做。

**被拒的使用者會看到什麼**：Auth0 帶著 `error=access_denied&error_description=Not+authorized...` 導回 Hermes 的 callback；`hermes_cli/dashboard_auth/routes.py:473-485` 會記一筆 `LOGIN_FAILURE`（`reason="idp_error"`）的稽核事件，並回 **HTTP 400 `OAuth error from provider: access_denied (Not authorized for this application.)`**。訊息可讀、不會是 500——這半個 A24 已從原始碼確認。

### 5.4 Railway 變數

```bash
HERMES_DASHBOARD_OIDC_ISSUER=https://<tenant>.<region>.auth0.com/
HERMES_DASHBOARD_OIDC_CLIENT_ID=<Auth0 client id>
HERMES_DASHBOARD_OIDC_CLIENT_SECRET=<Auth0 client secret>
HERMES_DASHBOARD_PUBLIC_URL=https://hermes.relvo.cc
```

用的是 **bundled 的 `self_hosted` provider**，不需要自寫 plugin，`HERMES_ALLOWLIST_*` 完全用不到。

**兩個細節**：

- **issuer 的尾斜線**：Auth0 的 issuer 是 `https://<tenant>.<region>.auth0.com/`（有尾斜線）。Hermes 的 provider 容忍尾斜線差異，照抄 Auth0 顯示的值即可。
- **想要免重新登入的續期，要加 `offline_access`**：Hermes 預設 scopes 是 `openid profile email`，**不含 `offline_access`**，所以 Auth0 不會發 refresh token，ID token 到期（Auth0 預設 10 小時）就要重新走一次登入。Hermes 支援標準 `refresh_token` grant 做靜默續期，要用的話設：
  ```bash
  HERMES_DASHBOARD_OIDC_SCOPES=openid profile email offline_access
  ```
  並在 Auth0 Application 的 Advanced Settings → Grant Types 確認 `Refresh Token` 已勾選。

## 6. 最終設定

```bash
# Dashboard 驗證 —— Auth0（Google 當 social connection，白名單在 Auth0 Action）
HERMES_DASHBOARD_OIDC_ISSUER=https://<tenant>.<region>.auth0.com/
HERMES_DASHBOARD_OIDC_CLIENT_ID=<Auth0 client id>
HERMES_DASHBOARD_OIDC_CLIENT_SECRET=<Auth0 client secret>
# 選配：要靜默續期才加 offline_access（Auth0 端也要勾 Refresh Token grant）
# HERMES_DASHBOARD_OIDC_SCOPES=openid profile email offline_access

# 自訂網域下必填 —— 不能依賴 RAILWAY_PUBLIC_DOMAIN 推導（見 §2.1）
HERMES_DASHBOARD_PUBLIC_URL=https://hermes.relvo.cc
```

`HERMES_ALLOWLIST_*` 與 allowlist plugin 都**不需要**（那是附錄 A 的替代路線）。

### 三層防線

| 層 | 機制 | 管理位置 |
|---|---|---|
| 1 | Google 同意畫面 Internal | Google Cloud Console（選配，需 Workspace） |
| 2 | Auth0 post-login Action 的 email 白名單 + `email_verified` | Auth0 UI，**即時生效** |
| 3 | Auth0 只掛 Google connection，Database connection 關閉 | Auth0 UI |

### 驗收

- `curl -s https://hermes.relvo.cc/api/status | jq '.auth_providers'` → **只有** `["self-hosted"]`（出現第二個就是有別的 provider 也註冊了，要查）
- 白名單內的 Google 帳號可登入；`GET /api/auth/me` 回傳該身分、`provider: self-hosted`
- **白名單外的 Google 帳號被拒**，看到 `400 OAuth error from provider: access_denied (...)`（一定要實測）
- Auth0 Logs 有對應的 failed login 記錄
- Railway 產生的 `xxx.up.railway.app` 網域已移除，公開入口只有 `hermes.relvo.cc`
- `https://hermes.relvo.cc/auth/callback` 與 Auth0 Application 的 Allowed Callback URLs 完全一致
- Google OAuth client 的 redirect URI 是 **Auth0 的** `https://<tenant>.<region>.auth0.com/login/callback`，不是 Hermes 的

---

## 附錄 A — 自寫 allowlist plugin（未採用，保留供參考）

> 已決定走 Auth0，本節**不需實作**。保留是為了兩個情境：日後想拿掉第三方 IdP 依賴，或想在 Auth0 之外再加一層 Hermes 端的縱深防禦。走這條路才需要 `HERMES_ALLOWLIST_*` 變數與 A18/A19 兩個驗證項。

### A.0 概要

### A.1 為什麼放在映像裡而不是 volume

plugin 搜尋路徑有兩處（`hermes_cli/plugins.py:4062,4078`）：

| 路徑 | 可寫性 |
|---|---|
| `get_bundled_plugins_dir()` = `/opt/hermes/plugins` | root-only，**代理人改不動** ✅ |
| `get_hermes_home()/plugins` = `/opt/data/plugins` | 在 volume 上，**代理人可以改** ⚠️ |

官方文件說「agent self-improvement is scoped to skills, memory, **plugins**, and config under `/opt/data`」——也就是代理人有能力改寫 `/opt/data/plugins` 底下的東西。**把驗證邏輯放在那裡，等於讓代理人有機會關掉自己的門禁。**

所以 allowlist plugin 要在薄封裝 Dockerfile 用 `COPY` 放進 `/opt/hermes/plugins/dashboard_auth/allowlist/`。

### A.2 避免旁路：不能讓兩個 provider 同時註冊

bundled 的 `self_hosted` plugin 只要 `HERMES_DASHBOARD_OIDC_ISSUER` + `_CLIENT_ID` 有值就會**自動註冊**。而登入頁會列出**所有**已註冊的 provider 讓使用者挑（`website/docs/user-guide/features/web-dashboard.md`：「The login page lists all registered providers; multiple providers can be stacked and the user picks one at `/login`」）。

**如果兩個都註冊，使用者可以直接點沒有白名單的那個按鈕——白名單形同虛設。**

解法：allowlist plugin 讀**自己的一組環境變數**，bundled 的那組保持未設定，於是它不會註冊。

| 變數 | 用途 |
|---|---|
| `HERMES_ALLOWLIST_OIDC_ISSUER` | 給 allowlist plugin |
| `HERMES_ALLOWLIST_OIDC_CLIENT_ID` | 給 allowlist plugin |
| `HERMES_ALLOWLIST_OIDC_CLIENT_SECRET` | 給 allowlist plugin |
| `HERMES_ALLOWLIST_EMAILS` | 逗號分隔的 email 清單 |
| ~~`HERMES_DASHBOARD_OIDC_*`~~ | **保持未設定**，否則 bundled provider 會一起註冊 |

（另一條路是用 `plugins.disabled` 停用 `dashboard_auth/self_hosted`，但分開環境變數比較不容易誤設。）

### A.3 plugin 實作

`docker/plugins/dashboard_auth/allowlist/plugin.yaml`
```yaml
name: allowlist-oidc
version: 1.0.0
description: "Dashboard auth provider — OIDC with an explicit email allowlist. Wraps the bundled self-hosted OIDC provider and rejects any authenticated identity whose email is not in HERMES_ALLOWLIST_EMAILS."
author: hermes-agent-railway
kind: backend
requires_env:
  - HERMES_ALLOWLIST_OIDC_ISSUER
  - HERMES_ALLOWLIST_OIDC_CLIENT_ID
  - HERMES_ALLOWLIST_EMAILS
```

`docker/plugins/dashboard_auth/allowlist/__init__.py`
```python
"""OIDC dashboard auth with an explicit email allowlist.

Hermes has no built-in user allowlist: the bundled self-hosted OIDC provider
creates a session for anyone the IdP authenticates. With Google as the issuer
and an "External" consent screen, that is every Google account on the planet —
and the dashboard is equivalent to a shell inside the container.

This provider delegates the entire OIDC dance to the bundled
SelfHostedOIDCProvider (so we inherit its PKCE, JWKS verification, iss/aud
pinning, refresh and revocation) and only adds one thing: an email check on
every path that can produce or renew a Session.

Deliberately reads its OWN env vars. If it reused HERMES_DASHBOARD_OIDC_*,
the bundled plugin would register too and the login page would offer both
providers side by side — letting a caller pick the one without the allowlist.
"""
from __future__ import annotations

import importlib.util
import logging
import os
from pathlib import Path

from hermes_cli.dashboard_auth import DashboardAuthProvider, ProviderError

logger = logging.getLogger(__name__)

LAST_SKIP_REASON = ""

_BUNDLED = Path(__file__).resolve().parent.parent / "self_hosted" / "__init__.py"


def _load_bundled_provider_class():
    """Import SelfHostedOIDCProvider from the sibling bundled plugin.

    Bundled plugins are imported by the loader as ``hermes_plugins.<slug>``,
    which is not a stable import path to depend on from another plugin, so we
    load the module by file path instead.
    """
    spec = importlib.util.spec_from_file_location(
        "_hermes_bundled_self_hosted_oidc", _BUNDLED
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.SelfHostedOIDCProvider


def _parse_allowlist(raw: str) -> frozenset[str]:
    return frozenset(
        part.strip().lower() for part in raw.split(",") if part.strip()
    )


class AllowlistOIDCProvider(DashboardAuthProvider):
    name = "allowlist-oidc"
    display_name = "Sign in with Google"

    def __init__(self, *, inner, allowed_emails: frozenset[str]) -> None:
        self._inner = inner
        self._allowed = allowed_emails

    # -- the allowlist itself -------------------------------------------
    def _enforce(self, session):
        email = (getattr(session, "email", "") or "").strip().lower()
        if not email:
            # No email claim → cannot authorize. Fail closed rather than
            # letting an identity through unchecked.
            logger.warning("allowlist-oidc: rejecting session with no email claim")
            raise ProviderError("This identity has no email claim; access denied.")
        if email not in self._allowed:
            logger.warning("allowlist-oidc: rejecting %s (not in allowlist)", email)
            raise ProviderError(f"{email} is not authorized for this dashboard.")
        return session

    # -- delegate everything else ---------------------------------------
    def start_login(self, *, redirect_uri):
        return self._inner.start_login(redirect_uri=redirect_uri)

    def complete_login(self, *, code, state, code_verifier, redirect_uri):
        return self._enforce(
            self._inner.complete_login(
                code=code,
                state=state,
                code_verifier=code_verifier,
                redirect_uri=redirect_uri,
            )
        )

    def verify_session(self, *, access_token):
        # Re-checked on every request path that verifies a session, so
        # removing an email from the allowlist takes effect on the next
        # verification instead of waiting for the session to expire.
        return self._enforce(self._inner.verify_session(access_token=access_token))

    def refresh_session(self, *, refresh_token):
        return self._enforce(self._inner.refresh_session(refresh_token=refresh_token))

    def revoke_session(self, *, refresh_token):
        return self._inner.revoke_session(refresh_token=refresh_token)


def register(ctx) -> None:
    global LAST_SKIP_REASON
    LAST_SKIP_REASON = ""

    issuer = os.getenv("HERMES_ALLOWLIST_OIDC_ISSUER", "").strip()
    client_id = os.getenv("HERMES_ALLOWLIST_OIDC_CLIENT_ID", "").strip()
    client_secret = os.getenv("HERMES_ALLOWLIST_OIDC_CLIENT_SECRET", "").strip()
    scopes = os.getenv("HERMES_ALLOWLIST_OIDC_SCOPES", "").strip() or "openid profile email"
    allowed = _parse_allowlist(os.getenv("HERMES_ALLOWLIST_EMAILS", ""))

    if not issuer or not client_id:
        LAST_SKIP_REASON = (
            "HERMES_ALLOWLIST_OIDC_ISSUER / _CLIENT_ID are not both set"
        )
        return

    # Fail closed: an OIDC provider with an EMPTY allowlist would authorize
    # nobody, but an operator who forgot the var would more likely expect
    # "everyone". Refuse to register instead of guessing.
    if not allowed:
        LAST_SKIP_REASON = (
            "HERMES_ALLOWLIST_EMAILS is empty — refusing to register an "
            "OIDC provider with no allowlist"
        )
        logger.error("allowlist-oidc: %s", LAST_SKIP_REASON)
        return

    inner_cls = _load_bundled_provider_class()
    inner = inner_cls(
        issuer=issuer,
        client_id=client_id,
        client_secret=client_secret,
        scopes=scopes,
    )
    ctx.register_dashboard_auth_provider(
        AllowlistOIDCProvider(inner=inner, allowed_emails=allowed)
    )
    logger.info("allowlist-oidc: registered with %d allowed email(s)", len(allowed))
```

Dockerfile 加一行：
```dockerfile
COPY docker/plugins/dashboard_auth/allowlist/ \
     /opt/hermes/plugins/dashboard_auth/allowlist/
```

### A.4 需要驗證的細節

`SelfHostedOIDCProvider.__init__` 的關鍵字參數名稱（`issuer` / `client_id` / `client_secret` / `scopes`）與 `DashboardAuthProvider` 五個方法的確切簽章，都要在實作時對照 `hermes_cli/dashboard_auth/__init__.py` 與 bundled plugin 的 `register()` 再確認一次（bundled 的 `register()` 在 `__init__.py:809-844` 就是現成範例）。列為待驗證 **A18**。

另外要確認 `ProviderError` 在 `complete_login` 拋出時，routes 層會呈現成使用者看得懂的錯誤而非 500——列為 **A19**。
