#!/usr/bin/env bash
# 示例：往持久化 Python 环境里装 pip 包（也可放二进制、改配置等任何初始化）。
# 读取 .env / docker-compose 传入的 PIP_PACKAGES（空格分隔）。
# 幂等：pip 对已安装且版本满足的包不会重复安装。
#
# 注意：这里装到持久卷上的 venv（/opt/python/venv，若脚本/环境里先创建了它），
# 或直接用系统 python3；按需自行扩展（例如下载工具到 /opt/tools/bin）。
set -euo pipefail

PACKAGES=${PIP_PACKAGES:-}
[ -z "$PACKAGES" ] && exit 0

# 优先用持久化 venv（存在则已在 PATH 或显式指定），否则落到系统 pip
PIP_BIN="$(command -v pip || command -v pip3)"

echo "[custom-scripts] pip install:$PACKAGES"
"$PIP_BIN" install --disable-pip-version-check $PACKAGES
