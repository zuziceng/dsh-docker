#!/usr/bin/env bash
# DeepSeek Harness (dsh) 容器入口脚本。
#
# 只做三件事：
#   1. 执行挂载进来的自定义脚本 /custom-scripts/*.sh（目录不存在则跳过，不报错）
#   2. （可选）socat 把只绑 loopback 的 web 端口重发布到容器网络
#   3. 启动 dsh web，前台等待；设了 DSH_TOKEN_FILE 时把一次性登录 token 原子落盘
#      （供 Caddy 的 {file.*} 占位符读取，实现首次访问自动登录）
#
# dsh 本体已在构建期烘焙进镜像（见 Dockerfile），版本检测由 GitHub Actions 完成；
# 本脚本不安装任何软件。
set -euo pipefail

# --- 配置（全部有默认值，.env/docker-compose 可覆盖） --------------------------
DSH_BIN=${DSH_BIN:-/opt/dsh/current/bin/dsh}
CUSTOM_SCRIPTS_DIR=${CUSTOM_SCRIPTS_DIR:-/custom-scripts}
DSH_USER=${DSH_USER:-dsh}            # 非交互运行用户（root 启动时降权到此用户）

DSH_HOME=${DSH_HOME:-/data/dsh}
WEB_PORT=${WEB_PORT:-3080}           # dsh 自身只监听 127.0.0.1
PROXY_PORT=${PROXY_PORT:-3081}       # socat 在 0.0.0.0 上重发布；设为 0 关闭
PUBLIC_URL=${PUBLIC_URL:-}           # 可选：外部访问地址，如 https://host:port/
TRUSTED_HOSTS=${TRUSTED_HOSTS:-}     # 可选：空格分隔的额外信任 Host
DSH_TOKEN_FILE=${DSH_TOKEN_FILE:-}   # 可选：token 落盘路径，如 /shared/token

log() { printf '[dsh] %s\n' "$*"; }
is_root() { [ "$(id -u)" = "0" ]; }

# --- 进程登记与清理 ------------------------------------------------------------
PIDS=()
register() { [ -n "${1:-}" ] && PIDS+=("$1") || true; }
cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
  done
}
trap cleanup TERM INT
trap 'cleanup; rm -f "${FIFO:-}"' EXIT

# --- root 启动时的最小准备：数据目录存在且归运行用户所有 ------------------------
if is_root; then
  mkdir -p "$DSH_HOME" /home/dsh
  chown -R "$DSH_USER:$DSH_USER" "$DSH_HOME" /home/dsh 2>/dev/null || true
fi

# --- 1. 自定义脚本（可选；没有目录/没有脚本都不报错） ---------------------------
if [ -d "$CUSTOM_SCRIPTS_DIR" ]; then
  for script in "$CUSTOM_SCRIPTS_DIR"/*.sh; do
    [ -e "$script" ] || break
    log "custom script: $(basename "$script")"
    bash "$script" || log "WARN: $(basename "$script") exited nonzero — continuing"
  done
fi

# --- 2. dsh 启动命令（数组，避免字符串分词问题） ---------------------------------
DSH_ARGS=(web --host 127.0.0.1 --port "$WEB_PORT" --no-open)
[ -n "$PUBLIC_URL" ] && DSH_ARGS+=(--public-url "$PUBLIC_URL")
for h in $TRUSTED_HOSTS; do
  DSH_ARGS+=(--trusted-host "$h")
done

if is_root; then
  DSH_CMD=(setpriv --reuid dsh --regid dsh --init-groups --reset-env \
    env HOME=/home/dsh DSH_HOME="$DSH_HOME" PATH="$PATH")
  [ -n "${TZ:-}" ] && DSH_CMD+=("TZ=$TZ")
  DSH_CMD+=("$DSH_BIN")
else
  DSH_CMD=("$DSH_BIN")
fi

# --- 3. socat 重发布（可选） -----------------------------------------------------
if [ "$PROXY_PORT" != "0" ]; then
  socat TCP-LISTEN:"$PROXY_PORT",fork,reuseaddr,bind=0.0.0.0 \
        TCP:127.0.0.1:"$WEB_PORT" &
  register "$!"
fi

# --- 4. 启动 dsh（统一路径：后台 + 前台 wait，token relay 按需挂上） --------------
cd "$DSH_HOME"

if [ -n "$DSH_TOKEN_FILE" ]; then
  # dsh 只在启动时打印一次带 token 的 URL。stdout 过 FIFO，relay 一边转发给
  # docker logs，一边原子写 token 文件；事件驱动，零轮询。
  FIFO=/tmp/dsh.stdout
  rm -f "$FIFO"
  mkfifo "$FIFO"
  "${DSH_CMD[@]}" "${DSH_ARGS[@]}" >"$FIFO" 2>&1 &
  register "$!"
  relay_tokens() {
    local line token
    while IFS= read -r line; do
      printf '%s\n' "$line"
      if [[ $line == *token=* ]]; then
        token=${line##*token=}
        token=${token%%[!A-Za-z0-9_-]*}
        if [ -n "$token" ]; then
          printf '%s' "$token" > "$DSH_TOKEN_FILE.new" &&
            mv -f "$DSH_TOKEN_FILE.new" "$DSH_TOKEN_FILE" &&
            log "login token published → $DSH_TOKEN_FILE"
        fi
      fi
    done
  }
  relay_tokens <"$FIFO" &
  register "$!"
else
  "${DSH_CMD[@]}" "${DSH_ARGS[@]}" &
  register "$!"
fi

# tini 把 SIGTERM 转给本脚本，cleanup 逐个转发；wait 随 dsh 退出结束容器。
wait "${PIDS[0]}"
