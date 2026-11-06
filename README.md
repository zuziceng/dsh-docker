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
| `caddy-entrypoint.sh` | 挑证书来源（多地址静态证书 / 内置 CA 兜底）后启动 Caddy |
| `gen-cert.sh` | 生成覆盖本机全部地址的多 SAN 自签证书（宿主机跑一次） |
| `.env.example` | 环境变量模板；复制成 `.env` 使用（`.env` 与 `data/` 不入库） |

## 使用

### 1. 拉 CI 构建的镜像

```bash
cp .env.example .env     # 至少填 LAN_HOST（实际访问用的 IP 或域名）
./gen-cert.sh            # 一次：为所有本机 IP 签同一张证书
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

入口地址全在 `.env`：`LAN_HOST`、`ET_HOST`（都可逗号分隔多个）、`LAN_PORT`（默认
3080）。Caddy 监听所有接口、统一用一张证书，不按 Host 分流。

**证书**：

- `./gen-cert.sh` 生成 `./certs/`（`ca.crt` / `dsh.crt` / `dsh.key`），SAN
  里塞进本机所有 IPv4 + `localhost` + `.env` 里填的域名。换 IP、加网卡后重跑即可
  —— CA 复用，客户端不用重装。加 `--force` 才重建 CA。
- 没跑脚本时退回 Caddy 内置 CA，只为 `LAN_HOST` 的第一个地址签一张证书，其余地址
  仍会报「证书不匹配」。所以 `LAN_HOST` 别填 `0.0.0.0`：那是监听地址，签进证书
  也匹配不了任何真实 IP。

**为什么必须一张证书覆盖所有地址**：浏览器访问裸 IP（`https://192.168.1.10:3080`）
时**不发 SNI** —— RFC 6066 明确禁止对 IP 字面量发送 SNI。Caddy 拿不到 SNI 就无法
按访问地址挑证书，只能给 `default_sni` 那唯一一张，于是多网卡 / 多网段访问时，
除主地址外全报错。把全部 IP 塞进同一张证书才彻底解决。

- **登录**：首次访问 Caddy 自动带上 dsh 的一次性 token 完成登录（entrypoint 把
  token 原子写入 `/shared/token`，Caddy 按 `{file.*}` 读），dsh 换来签名 cookie
  （30 天有效），之后直连根地址即可。
- **任意 IP 免配置**：Caddy 把上游 Host 统一改写为 `127.0.0.1:3080`，dsh 的会话
  cookie 按 Host authority 绑定签名，恒定值让签发与校验始终一致，局域网内任意
  IP / 域名共用一套登录态，无需逐个维护 `--trusted-host`。
- **根证书**：装到客户端「受信任根证书」一次即可消掉证书告警。

  ```bash
  scp certs/ca.crt <客户端>:~/       # 导入「受信任的根证书颁发机构」
  ```

  Windows：`certutil -addstore -f Root ca.crt`；macOS：`sudo security
  add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt`；
  Linux：`sudo cp ca.crt /usr/local/share/ca-certificates/dsh.crt && sudo
  update-ca-certificates`。

- **HTTP/3**：compose 同时发布 TCP 与 UDP 端口，`alt-svc: h3` 广播的 QUIC 走真实
  UDP，不会出现「先试 h3 再回落」的额外一拍。宿主防火墙记得放行 UDP。
  启动日志若有 `failed to sufficiently increase receive buffer size`，是宿主
  UDP 缓冲偏小（`net.core.rmem_max` 默认 208 KiB）：写
  `/etc/sysctl.d/99-quic.conf` 加 `net.core.rmem_max=7500000` 与
  `net.core.wmem_max=7500000`，`sudo sysctl --system`。这条只能在宿主机改 ——
  `net.core.*` 属于宿主网络命名空间，容器里调不动。

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

**证书告警** —— 三种情况：① 没跑 `./gen-cert.sh`，只有 `LAN_HOST` 第一个地址有
证书；② `LAN_HOST` 填了 `0.0.0.0` 之类的通配地址，签出来的证书名字对不上任何
真实 IP（启动日志会直接报错拦住）；③ 客户端没装 `./certs/ca.crt`。
重跑 `/gen-cert.sh` 后记得让浏览器重新握手（关掉所有标签页再开）。

**偶发首屏慢提示「正在尝试 QUIC」** —— Caddy 广播 `alt-svc: h3`，但宿主防火墙
挡了 UDP `LAN_PORT`。compose 已映射 UDP，放行防火墙即可；想彻底关掉 h3 就在
Caddyfile 全局块加 `servers { protocols h1 h2 }`。
