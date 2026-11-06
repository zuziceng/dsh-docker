#!/usr/bin/env bash
# 示例：把容器内软件源换成国内镜像（apt / npm / pip），让启动期装包更快更稳。
# 建议放在 05- 开头——按文件名顺序它先于 10-apt-packages.sh 执行，装包前源已切好。
#
# 幂等：源文件里已经是目标镜像地址就跳过，不重复改写。
# 变量可由 .env → compose 覆盖：APT_MIRROR / NPM_MIRROR / PIP_MIRROR（留空跳过该类）。
# 注意：改动在容器层，重建容器后本脚本会自动重新执行。
set -euo pipefail

APT_MIRROR=${APT_MIRROR:-mirrors.tuna.tsinghua.edu.cn}
NPM_MIRROR=${NPM_MIRROR:-https://registry.npmmirror.com}
PIP_MIRROR=${PIP_MIRROR:-https://pypi.tuna.tsinghua.edu.cn/simple}

# --- apt：官方源 deb.debian.org → 国内镜像（同时支持 deb822 .sources 与旧式 .list）
if [ -n "$APT_MIRROR" ]; then
  if grep -rq 'deb.debian.org' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    echo "[mirrors] apt → $APT_MIRROR"
    sed -i "s|http://deb.debian.org|http://${APT_MIRROR}|g; s|https://deb.debian.org|http://${APT_MIRROR}|g" \
      /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null || true
  else
    echo "[mirrors] apt 源已配置，跳过"
  fi
fi

# --- npm：写全局配置 /usr/local/etc/npmrc（对所有用户生效，包括运行用户 dsh）
if [ -n "$NPM_MIRROR" ]; then
  NPMRC=/usr/local/etc/npmrc
  if ! grep -qs "registry=${NPM_MIRROR}" "$NPMRC" 2>/dev/null; then
    echo "[mirrors] npm → $NPM_MIRROR"
    mkdir -p "$(dirname "$NPMRC")"
    grep -qs '^registry=' "$NPMRC" 2>/dev/null \
      && sed -i "s|^registry=.*|registry=${NPM_MIRROR}|" "$NPMRC" \
      || echo "registry=${NPM_MIRROR}" >> "$NPMRC"
  else
    echo "[mirrors] npm 源已配置，跳过"
  fi
fi

# --- pip：写全局配置 /etc/pip.conf（对所有用户与 venv 生效）
if [ -n "$PIP_MIRROR" ]; then
  PIPCONF=/etc/pip.conf
  if ! grep -qs "index-url = ${PIP_MIRROR}" "$PIPCONF" 2>/dev/null; then
    echo "[mirrors] pip → $PIP_MIRROR"
    {
      echo '[global]'
      echo "index-url = ${PIP_MIRROR}"
      echo 'trusted-host = '"$(printf '%s' "$PIP_MIRROR" | sed -E 's|https?://([^/]+)/?.*|\1|')"
    } > "$PIPCONF"
  else
    echo "[mirrors] pip 源已配置，跳过"
  fi
fi
