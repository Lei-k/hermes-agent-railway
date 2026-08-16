# 06 — Model Provider 評估：CLIProxyAPI

回應需求 #7（更正版）。先前評估的 `fuergaosi233/claude-code-proxy` 方向確實是反的（Anthropic 格式 → OpenAI 格式，後端還要 `OPENAI_API_KEY`）；**`router-for-me/CLIProxyAPI` 才是正確形狀的工具**。

---

## 1. CLIProxyAPI 是什麼

查證來源：[GitHub](https://github.com/router-for-me/CLIProxyAPI)、`config.example.yaml`

一個把**多家 CLI 訂閱**（透過各家的 OAuth 登入）包裝成標準 API 端點的代理伺服器。

| 面向 | 內容 |
|---|---|
| 上游 | Claude Code、OpenAI Codex、Gemini / Antigravity、Grok Build、Kimi，以及 OpenAI 相容端點（如 OpenRouter） |
| 對外格式 | OpenAI `/v1/chat/completions`、Anthropic `/v1/messages`、Gemini、Codex |
| 能力 | 串流 / 非串流 / WebSocket、**function calling / tools**、多模態輸入 |
| 多帳號 | 多組憑證輪替（round-robin），支援 per-credential weight、prefix、base URL、header、model alias |
| 韌性 | retry policy、**credential cooldown**、session affinity routing |
| 監聽 | 預設 port `8317`，`host: ""`（綁全介面） |
| 憑證持久化 | `auth-dir: ~/.cli-proxy-api` |
| 自身保護 | `api-keys:` 清單（呼叫方要帶其中一把） |
| 管理面 | Management API + secret key（`allow-remote` 預設 false）、可選的 Control Panel UI（[CPAMC](https://github.com/router-for-me/Cli-Proxy-API-Management-Center)） |
| 容器化 | 有 `Dockerfile`、`docker-compose.yml`、`docker-compose.cluster.yml` |

方向正確：它是 **server**，Hermes 是 **client**，兩者接得上。

---

## 2. 但先問一個問題：只為了 Claude Code 的話，需要它嗎？

**不需要。Hermes 原生就支援 Claude Code 憑證。**

出處：
- `website/docs/reference/environment-variables.md:108` — `CLAUDE_CODE_OAUTH_TOKEN`
- `skills/.../providers-and-models.md:12` — `anthropic | API key | ANTHROPIC_API_KEY (also CLAUDE_CODE_OAUTH_TOKEN)`
- `website/docs/developer-guide/provider-runtime.md:132-137` — 憑證解析**優先採用可刷新的 Claude Code credentials**；原生 Messages API 呼叫前會先 preflight 憑證刷新

設定只有兩行、零額外元件、零額外 Railway service：

```yaml
model: { provider: anthropic, model: <claude-model-id> }
```
```bash
CLAUDE_CODE_OAUTH_TOKEN=<claude setup-token 產生>
```

而且 Hermes 自己有**憑證池 + 跨 provider fallback**（`credential-pools.md`、`fallback-providers.md`），功能與 CLIProxyAPI 的多帳號輪替**重疊**：

```
請求
 → 憑證池：同 provider 多把 key 輪替
     └─「plan/usage limit reached」型 429 → 立刻換下一把（不重試，重試也不會過）
     └─ 一般 transient 429 → 同一把重試一次，再 429 才輪替
 → 池子全空 → fallback_providers 切到不同 provider（不中斷對話）
 → auxiliary task（vision / 壓縮 / 網頁擷取）有獨立的 provider 解析
```

---

## 3. 那 CLIProxyAPI 什麼時候值得？

當你要的不只是 Claude Code 一家。它的真正價值在**聚合層**：

| 情境 | 值不值得 |
|---|---|
| 只有 Claude Code 訂閱 | ❌ 多餘的一層。用 Hermes 原生的 |
| 有 Claude Code + Codex + Gemini + Grok 等**多家 CLI 訂閱**想池化成一個端點 | ✅ 這正是它存在的理由。Hermes 的憑證池是同 provider 內輪替，跨家聚合要靠 fallback 鏈，設定較零散 |
| 同一家有**多個帳號**要輪替 | ⚖️ 兩邊都能做。CLIProxyAPI 的 per-credential weight / cooldown 比較細緻 |
| 想讓 Hermes **以外**的工具（其他 IDE、腳本）共用同一組訂閱 | ✅ 一個代理服務多方共用，比每個 client 各自持有憑證乾淨 |
| 想要一個 UI 看用量 / 管理憑證 | ✅ Control Panel |

---

## 4. 在 Railway 上部署的實際成本

如果採用，架構會變成**兩個 Railway service**：

```
┌─ service: cliproxy ──────────────┐      ┌─ service: hermes-agent ────────┐
│  CLIProxyAPI                     │      │  Hermes Agent                   │
│  :8317                           │◀─────│  provider: anthropic            │
│  volume → auth-dir（OAuth 憑證） │ 私有 │  ANTHROPIC_BASE_URL=            │
│  api-keys: [<key>]               │ 網路 │    http://cliproxy.railway      │
│  無對外 domain                    │      │      .internal:8317            │
└──────────────────────────────────┘      │  volume → /opt/data             │
                                          └────────────────────────────────┘
```

**加分項**：Railway 有私有網路（`<service>.railway.internal`，同專案同環境自動 DNS 發現、WireGuard 加密、零設定）。CLIProxyAPI **不需要對外 domain**，攻擊面只在私有網路內。

**成本項**：

1. **第二顆 volume**。`auth-dir` 存的是各家的 OAuth 憑證與刷新 token，掉了就要重新登入所有帳號。
2. **互動式 OAuth bootstrap**。各家的登入是瀏覽器 OAuth 流程；在 Railway 這種無頭環境要靠 `railway ssh` 進容器跑登入指令、把 URL 複製出來、再把 callback 貼回去。這是**每個上游帳號都要做一次**的一次性工作，且憑證過期或撤銷時要重做。
3. **IPv6 綁定**。Railway 私有網路是 IPv6；服務必須綁 `::` 而非只綁 `0.0.0.0` 才連得到。CLIProxyAPI 預設 `host: ""`（Go 通常會雙棧綁定）應該可行，但這是 Railway 上的經典坑，列為待驗證 **A20**。
4. **多一個要維運的元件**：版本升級、憑證輪替、故障排查都多一份。
5. **雙重輪替邏輯**。Hermes 的憑證池 / fallback 與 CLIProxyAPI 的 credential cooldown 會疊在一起——Hermes 只看到一個端點，不知道背後換了帳號；行為可能不好推理（例如 CLIProxyAPI 內部全部 cooldown 時對 Hermes 回什麼？Hermes 的 fallback 會不會正確觸發？）。要嘛把輪替**只放一邊**，要嘛實測清楚。

---

## 5. Hermes 端的接法

CLIProxyAPI 同時提供 Anthropic 與 OpenAI 兩種格式，兩條路都可行：

**Anthropic 格式（推薦，工具呼叫的原生路徑）**
```bash
# Railway 變數（hermes-agent service）
ANTHROPIC_BASE_URL=http://cliproxy.railway.internal:8317
ANTHROPIC_API_KEY=<CLIProxyAPI 的 api-keys 之一>
```
```yaml
model: { provider: anthropic, model: <model-id 或 CLIProxyAPI 的 alias> }
```

**OpenAI 相容格式**
```bash
OPENAI_BASE_URL=http://cliproxy.railway.internal:8317/v1
OPENAI_API_KEY=<CLIProxyAPI 的 api-keys 之一>
```

> Hermes 是**重度 tool-calling** 的 agent（40+ 工具、subagent 委派、RPC 腳本）。任何中介層都要實測 function calling 與串流的保真度，尤其是 Anthropic ↔ OpenAI 之間的格式轉換路徑。CLIProxyAPI 明確宣稱支援 function calling，但仍列為待驗證 **A21**。

---

## 6. 三個選項的比較

| | 額外元件 | 首次設定 | 多家訂閱聚合 | 多帳號輪替 | 純變數部署 |
|---|---|---|---|---|---|
| **A. Hermes 原生 Claude Code + fallback** | 無 | `claude setup-token` 一次 | ❌ | Hermes 憑證池 | ✅ |
| **B. CLIProxyAPI 中介** | +1 service +1 volume | 每個上游帳號一次互動式 OAuth | ✅ | ✅ 較細緻 | ⚠️ 憑證需 volume |
| C. 純 `ANTHROPIC_API_KEY` | 無 | 貼一把 key | ❌ | — | ✅ |

## 7. 建議

**取決於你有幾家訂閱：**

- **只有 Claude Code** → 選 **A**。CLIProxyAPI 在這個情境是多餘的一層，而 Hermes 原生路徑已經涵蓋（含限額時的自動切換）。
- **有多家 CLI 訂閱要池化，或想讓其他工具共用** → 選 **B**，它的設計正好是為這件事。接受兩個 service、第二顆 volume、互動式 bootstrap 的成本。

**不論選哪個，都建議配一個按量計費的 `fallback_providers`**：Claude Code 訂閱是滾動時間窗限額、設計前提是互動式使用；而你要跑的是常駐 gateway + Telegram + cron + 學習迴圈的無人值守負載，撞頂機率高。撞頂後代理人會整段啞掉——Telegram 沒回應、cron 靜默失敗。

```yaml
fallback_providers:
  - provider: openrouter
    model: <備援 model-id>
```

> **另註**：用訂閱憑證驅動第三方 agent 是否在各家的訂閱條款範圍內，需你自行確認。這適用於 A 與 B，CLIProxyAPI 並不改變這件事。
