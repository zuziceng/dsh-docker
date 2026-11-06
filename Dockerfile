# dsh (DeepSeek Harness) — release-baked runtime image.
#
# 与旧方案的区别：dsh 本体在**构建期**从 npm 烘焙进镜像（由 GitHub Actions
# 检测 deepseek-ai/deepseek-harness 的新 release 并按版本号出镜像），运行时
# 不再联网安装。镜像标签即 dsh 版本，回滚 = 换镜像标签。
#
# 基础镜像是 Debian（trixie slim），在此之上装齐 dsh 运行所需的系统工具、
# 编译器、Node 与 Python 运行环境。
ARG DEBIAN_IMAGE=debian:trixie-slim
FROM ${DEBIAN_IMAGE}

# 本地构建传 --build-arg APT_MIRROR=mirrors.tuna.tsinghua.edu.cn 走清华源；
# CI（GitHub Actions 在境外）不传即用官方源。apt 有签名校验，http 不影响完整性。
ARG APT_MIRROR=""
ARG NODE_MAJOR=22
ARG DSH_PACKAGE=@deepseek-ai/dsh
# 构建参数：要烘焙进镜像的 dsh 版本号（如 0.2.2-rc.1），由 CI 传入；
# 本地手动构建缺省 latest。
ARG DSH_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# --- 系统基础工具（只保留 dsh 运行必需；编译链与 CLI 工具改为启动期补装） -----
# tini              PID 1：回收僵尸进程、转发信号
# socat             把 dsh 只绑 loopback 的 web 端口重发布到 compose 网络
# git               dsh 插件安装、workspace 工具
# bubblewrap        dsh 的 workspace-write 沙箱后端
# ca-certificates   npm/HTTPS
# curl              NodeSource 安装（构建期）；运行期脚本常用
# python3 全家桶    agent 工作区常用运行环境（venv 持久化见 entrypoint.sh）
# jq                脚本处理 JSON 的通用工具
#
# 编译链（build-essential）、ripgrep/tmux/ssh 等 CLI 工具不在镜像里：通过 .env
# 的 EXTRA_APT_PACKAGES 或 custom-scripts/ 在启动期补装（见 README），镜像更小、
# 需求变化不用重建镜像。
RUN if [ -n "$APT_MIRROR" ]; then \
        sed -i "s|http://deb.debian.org|http://${APT_MIRROR}|g" \
            /etc/apt/sources.list.d/*.sources /etc/apt/sources.list 2>/dev/null || true; \
    fi \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        tini socat git bubblewrap ca-certificates curl gnupg \
        python3 python3-pip python3-venv jq \
 && rm -rf /var/lib/apt/lists/*

# --- Node.js（dsh 是 npm 包，运行时必须） ------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x -o /tmp/nodesource.sh \
 && bash /tmp/nodesource.sh \
 && apt-get install -y --no-install-recommends nodejs \
 && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/nodesource.sh

# --- 烘焙 dsh ----------------------------------------------------------------
# 安装到版本化目录并建 current 软链，目录结构与旧 entrypoint 兼容。
RUN mkdir -p /opt/dsh/versions \
 && npm install --global --prefix "/opt/dsh/versions/${DSH_VERSION}" \
        --no-audit --no-fund --loglevel=error \
        "${DSH_PACKAGE}@${DSH_VERSION}" \
 && ln -sfn "/opt/dsh/versions/${DSH_VERSION}" /opt/dsh/current \
 && printf '%s\n' "$DSH_VERSION" > /opt/dsh/VERSION \
 && npm cache clean --force

# --- 运行用户（复用旧的 dsh 用户约定，uid/gid 1000） --------------------------
RUN useradd --create-home --uid 1000 --user-group --shell /bin/bash dsh \
 && mkdir -p /data/dsh /shared /opt/python /opt/tools/bin \
 && chown -R dsh:dsh /opt/dsh /opt/python /opt/tools /data/dsh /shared

# 运行时用户可写、且按镜像标签对应的版本落盘的说明文件
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENV PATH="/opt/dsh/current/bin:/opt/python/venv/bin:/opt/tools/bin:${PATH}"

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
