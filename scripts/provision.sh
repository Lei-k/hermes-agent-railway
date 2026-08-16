#!/usr/bin/env bash
#
# 用 railway CLI 佈建 Hermes Agent 的 service：volume、環境變數、自訂網域。
#
# 這些東西「不在」railway.toml 的 schema 裡（config-as-code 只涵蓋 build 與
# deploy 設定），所以用這支腳本讓它可重現。
#
# 用法:
#   cp .env.railway.example .env.railway   # 填入真實值
#   railway login
#   railway link                           # 連到目標 project / environment
#   ./scripts/provision.sh                 # 預覽（dry-run）
#   ./scripts/provision.sh --apply         # 實際執行
#
# 這支腳本是冪等的：重跑會覆蓋變數成 .env.railway 的內容。
set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE="${ENV_FILE:-.env.railway}"
DOMAIN="${DOMAIN:-hermes.relvo.cc}"
VOLUME_MOUNT="/opt/data"   # = $HERMES_HOME，上游 Dockerfile 的 VOLUME 宣告
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
run()  {
    if [ "$APPLY" = 1 ]; then
        echo "+ $*"
        "$@"
    else
        echo "  [dry-run] $*"
    fi
}

command -v railway >/dev/null 2>&1 || die "找不到 railway CLI —— https://docs.railway.com/guides/cli"
[ -f "$ENV_FILE" ] || die "找不到 $ENV_FILE（從 .env.railway.example 複製一份）"

if [ "$APPLY" = 0 ]; then
    echo
    echo "  DRY RUN —— 不會有任何變更。確認無誤後加上 --apply。"
    echo
fi

# ── 1. Volume ─────────────────────────────────────────────────────────
# 掛載點必須是 /opt/data。Hermes 的所有可變狀態都在那裡：config.yaml、
# .env、auth.json、sessions/、memories/、skills/、cron/、SQLite 資料庫。
# 沒有持久磁碟 = 每次部署失憶。
info "Volume —— 掛載於 $VOLUME_MOUNT"
run railway volume add --mount-path "$VOLUME_MOUNT"

# ── 2. 環境變數 ───────────────────────────────────────────────────────
# 從 $ENV_FILE 讀取，略過註解與空行。支援跨行的 "..." 值
# （HERMES_BOOTSTRAP_CONFIG 會用到）。
info "環境變數 —— 來自 $ENV_FILE"
declare -a VARS=()
while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue

    key="${line%%=*}"
    val="${line#*=}"

    # 值以單一 " 開頭 → 收集後續行直到收尾的 "
    if [[ "$val" == '"'* && "$val" != '"'*'"' ]]; then
        val="${val#\"}"
        while IFS= read -r cont; do
            if [[ "$cont" == *'"' ]]; then
                val+=$'\n'"${cont%\"}"
                break
            fi
            val+=$'\n'"$cont"
        done
    else
        val="${val%\"}"; val="${val#\"}"
    fi

    # 空值 = 尚未填寫，跳過（避免用空字串蓋掉 Railway 上已設好的值）
    [ -z "$val" ] && { echo "  略過 $key（$ENV_FILE 中為空）"; continue; }

    case "$val" in
        *'<'*'>'*) die "$key 仍含未替換的佔位符: $val" ;;
    esac

    VARS+=(--set "$key=$val")
    echo "  $key"
done < "$ENV_FILE"

[ ${#VARS[@]} -gt 0 ] || die "$ENV_FILE 裡沒有可套用的變數"
run railway variables "${VARS[@]}"

# ── 3. 部署 ───────────────────────────────────────────────────────────
info "部署"
run railway up

# ── 4. 自訂網域 ───────────────────────────────────────────────────────
# 需要 CNAME + TXT 兩筆 DNS 記錄 —— 只加 CNAME 不會驗證通過（會回 404）。
# 用子網域所以 DNS 商是誰都無所謂；CNAME flattening / ALIAS 只有 apex 才需要。
info "自訂網域 —— $DOMAIN（target port ${PORT:-9119}）"
run railway domain "$DOMAIN"

cat <<EOF

────────────────────────────────────────────────────────────────────
接下來要手動完成的事：

1. 依 Railway 給的值，在 DNS 加上 CNAME + TXT 兩筆記錄。
   只加 CNAME 不會驗證通過。等 Let's Encrypt 憑證簽發（通常一小時內）。

2. 確認 https://$DOMAIN 可用之後，到 Railway 把自動產生的
   *.up.railway.app 網域「移除」。留著它等於 dashboard 有第二個對外
   入口 —— /api/health 與 /api/status 免驗證可讀，會洩漏版本與 gateway 狀態。

3. 驗收：
   curl -s https://$DOMAIN/api/health
   curl -s https://$DOMAIN/api/status | jq '.auth_required, .auth_providers'
       → true / ["self-hosted"]  （出現第二個 provider 就要查）
   用白名單內的 Google 帳號登入，再用白名單外的帳號確認被拒。

4. 檢查 deploy log：
   - 不可出現 "WARNING: container entrypoint is not PID 1"
   - 應出現 "[stage2] Setup complete; starting user services"
   - 應出現 "[railway] bootstrap complete"
────────────────────────────────────────────────────────────────────
EOF
