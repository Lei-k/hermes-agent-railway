# syntax=docker/dockerfile:1
#
# Hermes Agent — Railway 薄封裝映像
#
# 基底是「上游官方預建映像」，不是自建的。fork（Lei-k/hermes-agent）目前
# 與 upstream 零分歧（behind_by=0、沒有任何自己的 commit），所以沒有理由
# 自己建一份 —— 上游 Dockerfile 冷建置要編 SQLite、抓 s6-overlay、裝
# Playwright、uv sync 八個 extras、建兩個前端，上游自己把該 job 的 timeout
# 設在 45 分鐘、映像 5GB+。
#
# 這一層只做兩件事：塞進 Railway 專用的開機 hook、把 CMD 烤進映像。
# 建置是秒級，而且完全不需要碰 fork repo。
#
# 客製化多數不需要 fork —— 見 README「客製化」一節：plugin、skill、config、
# 系統/Python/npm 套件都可以在這一層 COPY / RUN 疊上去。只有要改 Hermes
# 的核心原始碼才需要自建映像流水線（見 plan/03 附錄）。

# 上游官方映像。釘死版本標籤，不要用 latest / main ——
# 未釘版會讓 Railway 的執行環境在無預警下改變。
# 版本清單：https://hub.docker.com/r/nousresearch/hermes-agent/tags
#
# 也可以在 Railway service variables 設同名變數覆寫（Railway 會把
# service variables 當作 build arg 傳進來），升級時不必動程式碼。
ARG HERMES_IMAGE=nousresearch/hermes-agent
ARG HERMES_TAG=v2026.8.13
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
