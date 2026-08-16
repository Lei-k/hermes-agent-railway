# syntax=docker/dockerfile:1
#
# Hermes Agent — Railway 薄封裝映像
#
# 這一層刻意只做三件事：釘住上游版本、塞進 Railway 專用的開機 hook、
# 把 CMD 烤進映像。完整的 Hermes 映像（編 SQLite、s6-overlay、Node 26、
# Playwright、uv sync 八個 extras、兩個前端）由 Lei-k/hermes-agent 的
# .github/workflows/fork-image.yml 在 GitHub Actions 建好推到 GHCR ——
# 上游自己把那個 job 的 timeout 設在 45 分鐘、映像 5GB+，不適合放在
# Railway 的部署流程裡重跑。這一層的建置是秒級。

# 基底映像 = fork 自建映像。
#
# ⚠️ 第一次部署前，把 HERMES_TAG 從 main 改成 fork-image.yml 產出的
#    commit sha。用 :main 等於讓 Railway 的執行環境在無預警下改變。
#    也可以在 Railway service variables 設同名變數覆寫（Railway 會把
#    service variables 當作 build arg 傳進來）。
ARG HERMES_IMAGE=ghcr.io/lei-k/hermes-agent
ARG HERMES_TAG=main
FROM ${HERMES_IMAGE}:${HERMES_TAG}

# Railway 專用開機 hook。
#
# cont-init.d 依「字典序」執行，上游既有的順序是：
#   01-hermes-setup → 015-supervise-perms → 02-reconcile-profiles
#
# 02-reconcile-profiles 會依 gateway_state.json 把 gateway 的 s6 slot
# 拉起來，所以我們的埠對齊與 config bootstrap 必須排在它前面。
# 編號取 016：字元比較下 "016" < "02"（第二個字元 1 < 2），
# 同時 "015" < "016"，剛好卡在正確位置。
COPY --chmod=0755 docker/cont-init.d/016-railway-bootstrap \
     /etc/cont-init.d/016-railway-bootstrap

# Railway 的 custom start command 會以 exec form 覆蓋映像的 ENTRYPOINT，
# 而 Hermes 的 ENTRYPOINT (entrypoint-dispatch.sh) 承載整條 s6 bootstrap:
# volume chown、.env/config.yaml 首次 seed、config schema migration、
# 監管樹。被覆蓋掉就等於整套跳過。
#
# 把參數烤進 CMD，Railway 的 start command 欄位就能留空 —— 這是唯一
# 安全的做法。(若因故非設不可，唯一安全的值是把 ENTRYPOINT 手動寫回去:
#  /opt/hermes/docker/entrypoint-dispatch.sh gateway run)
CMD ["gateway", "run"]
