#!/usr/bin/env bash
# 示例：启动期自动补装 apt 软件包。
# 读取 .env / docker-compose 传入的 EXTRA_APT_PACKAGES（空格分隔），
# 逐个对比 dpkg 已装列表，缺哪个补哪个——已装不重复装，幂等可重复执行。
# 需要 root（容器默认以 root 跑 custom-scripts，之后才降权运行 dsh）。
set -euo pipefail

PACKAGES=${EXTRA_APT_PACKAGES:-}
[ -z "$PACKAGES" ] && exit 0

missing=''
for pkg in $PACKAGES; do
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' \
    || missing="$missing $pkg"
done

if [ -z "$missing" ]; then
  echo "[custom-scripts] apt packages up to date"
  exit 0
fi

echo "[custom-scripts] installing apt packages:$missing"
apt-get update -qq
apt-get install -y --no-install-recommends $missing
rm -rf /var/lib/apt/lists/*
