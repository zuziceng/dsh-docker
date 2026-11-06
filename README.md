# deepseek-harness 镜像

为 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`）
构建可自托管运行的 Docker 镜像，由 GitHub Actions 检测上游 release 自动构建并推送。

```
上游 release（dsh-vX.Y.Z）──GitHub Actions 检测──▶ 构建镜像 ──▶ ghcr.io/<owner>/<repo>/deepseek-harness
                                                                      ├── latest / <版本>   最新正式版
                                                                      └── rc / rc-<版本>    最新 release（含 rc/alpha）
```

## 仓库内容

| 文件 | 职责 |
|---|---|
| `.github/workflows/build-dsh-release.yml` | 每 2 小时检测上游 release，构建双架构镜像推送到 GHCR |
| `Dockerfile` | Debian trixie-slim 基础；构建期通过 `ARG DSH_VERSION` 从 npm 烘焙 dsh |
| `entrypoint.sh` | 执行 `custom-scripts/*.sh` → 启动 dsh → 把登录 token 原子落盘 |
| `custom-scripts/` | 启动期自定义脚本（换软件源、补装 apt/pip 包） |
| `docker-compose.yml` | 运行栈：dsh + Caddy 双容器 |
| `Caddyfile` | 局域网 HTTPS 入口：自签 TLS + 首次访问自动带 token 登录 |
| `.env.example` | 环境变量模板；复制成 `.env` 使用（`.env` 与 `data/` 不入库） |

## 使用

### 1. 拉 CI 构建的镜像

```bash
cp .env.example .env     # 至少填 LAN_HOST（局域网 IP 或域名）
docker compose up -d
docker logs -f deepseek-harness    # 带 ?token= 的登录地址在这里
```

首次构建完成后建议把 GHCR package 设为 public（Package settings → Change
visibility），拉取免凭据。镜像地址可以在 `.env` 里用 `DSH_IMAGE` 覆盖（换加速
源、指向本地构建的 tag 都改这一项）。

### 2. 本地构建

```bash
docker build -t deepseek-harness:local \
  --build-arg DSH_VERSION=rc \
  --build-arg APT_MIRROR=mirrors.tuna.tsinghua.edu.cn .
# 然后 .env 里写 DSH_IMAGE=deepseek-harness:local
docker compose up -d
```

`DSH_VERSION` 取 `latest` / `rc` / 具体版本号（如 `0.2.2-rc.1`）。不传
`APT_MIRROR` 就走官方源（CI 在境外构建时即如此）。

### 3. 局域网 HTTPS 访问（Caddy，默认随栈启动）

入口地址全在 `.env`：`LAN_HOST`（必填）、`ET_HOST`（可选第二入口）、`LAN_PORT`
（默认 3080）。同一站点块里的两个地址会签进**同一张证书**，所以想同时用两个
IP / 域名访问，分别填进这两项即可，不用维护两套配置。

- **登录**：首次访问 Caddy 自动带上 dsh 的一次性 token 完成登录（entrypoint 把
  token 原子写入 `/shared/token`，Caddy 按 `{file.*}` 读），dsh 换来签名 cookie
  （30 天有效），之后直连根地址即可。
- **任意 IP 免配置**：Caddy 把上游 Host 统一改写为 `127.0.0.1:3080`，dsh 的会话
  cookie 按 Host authority 绑定签名，恒定值让签发与校验始终一致，局域网内任意
  IP / 域名共用一套登录态，无需逐个维护 `--trusted-host`。
- **根证书**：装到客户端「受信任根证书」一次即可消掉证书告警。

  ```bash
  docker cp deepseek-harness-caddy:/data/caddy/pki/authorities/local/root.crt ./dsh-root.crt
  ```

### 4. 加一层 HTTP Basic 认证（可选）

局域网内不止你一个人、或入口暴露面较大时，在 Caddy 上再叠一层：

```bash
docker run --rm -it caddy:2-alpine caddy hash-password    # 交互输入密码，拿哈希
```

打开 `Caddyfile`，取消 `basic_auth` 块的注释并填入用户名与哈希，然后
`docker compose restart caddy`。生效后每次新会话先过 Basic 认证，再到 dsh 的
token/cookie 登录，双重门槛。

## 自定义脚本（custom-scripts/）

容器**每次启动**按文件名顺序执行 `custom-scripts/*.sh`（以 root 运行，之后才降权
启动 dsh）。目录为空、没挂载、没有 `.sh` 文件都不报错；单个脚本失败只记 WARN。

- 用途：补装 apt 包、pip 装包、下载二进制到 `/opt/tools/bin`（已在 PATH）、改配置
  —— 一切不想固化进镜像、想随时调整的东西。
- 要求：**幂等**（每次启动都会跑，先检查再执行）。
- 参数：`.env` → compose `environment` → 脚本的环境变量。内置三个示例：
  `05-mirrors.sh`（换 apt/npm/pip 国内源）、`10-apt-packages.sh`（读
  `EXTRA_APT_PACKAGES`）、`20-pip-packages.sh`（读 `PIP_PACKAGES`）。

改 `.env` 后 `docker compose up -d` 重建容器即生效，不用重建镜像。注意 apt 包装在
容器层：同一容器重启不重装，重建容器才会按需补装，需要网络。想完全固化就写进
Dockerfile。

## 版本策略

- 镜像版本 = 上游 release 版本，构建期烘焙（`/opt/dsh/VERSION`），运行时不联网装 dsh。
- `latest` / `<版本号>` 跟正式 release（上游暂无则跳过，出现后自动开始）；
  `rc` / `rc-<版本号>` 跟最新 release（含 rc/alpha，当前只有这种）。
- 手动触发：Actions 页面 Run workflow，可填具体版本号（进 rc 系列 tag）。

## 构建细节

- 基础镜像 `debian:trixie-slim`；Node 22（NodeSource）、Python3 + venv/pip、
  tini/socat/git/bubblewrap/jq/curl 内置；编译链与 CLI 工具留给 custom-scripts。
- 双架构 `linux/amd64` + `linux/arm64`（原生模块在对应平台用容器内工具链编译）。
- dsh 的 web 只绑 `127.0.0.1`，entrypoint 用 socat 重发布到容器端口 3081。
- 数据持久化：`/data/dsh`（会话/凭据/workspace）、`/home/dsh`、`/opt/python`（venv）、
  `/opt/tools`（自定义工具）都是挂载卷，换镜像升级不丢数据。
- 沙箱：dsh 的 workspace-write 用 bubblewrap，compose 已带 `seccomp=unconfined` + `SYS_ADMIN`。

## 排障

**页面一直显示「重新连接中」** —— 页面主连接是 `/api/remote.mux` 的 WebSocket，被
挡在 403 就会无限退避重试。dsh 的浏览器信任栅栏要求 **Origin 的 authority 与 Host
相同**；Caddy 改写了 Host 却没对齐 Origin 时两者对不上，就是这个症状。`Caddyfile`
里已同时下发 `header_up Host 127.0.0.1:3080` 与 `header_up Origin
http://127.0.0.1:3080`，两者必须成对出现，删掉任何一条都会复发。

**证书告警** —— `LAN_HOST` 要填实际访问用的地址（填 `0.0.0.0` 签出来的证书覆盖不了
真实 IP）；根证书没装的话浏览器只给一次性例外。

**偶发首屏慢** —— Caddy 会广播 `alt-svc: h3`，但 compose 只发布了 TCP 端口，浏览器
可能先试 QUIC 再回落。想彻底消除就把端口改成 `3080:3080/tcp` + `3080:3080/udp`，或在
`Caddyfile` 全局加 `servers { protocols h1 h2 }` 关掉 h3。
