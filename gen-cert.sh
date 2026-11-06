#!/usr/bin/env bash
# 生成一张覆盖本机所有访问地址的自签证书（多 SAN），供 Caddy 使用。
#
# 为什么需要：浏览器访问裸 IP 时**不发送 SNI**（RFC 6066 禁止对 IP 字面量发），
# Caddy 就没法按访问地址挑证书，只能拿 default_sni 那唯一一张去比对 —— 除了那
# 一个 IP，其余地址一律「证书不匹配」。把全部 IP 塞进同一张证书的 SAN 是唯一
# 干净的解法。
#
# 用法：./gen-cert.sh          生成/刷新（CA 复用，客户端不用重装根证书）
#       ./gen-cert.sh --force  连 CA 一起重建（客户端需重新安装 ca.crt）
#
# 证书落在 ./certs/：
#   ca.crt     根证书，装到客户端「受信任根证书」一次即可
#   dsh.crt    HTTPS 证书（含全部 IP/域名）
#   dsh.key    私钥
set -euo pipefail
cd "$(dirname "$0")"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

CERT_DIR=${CERT_DIR:-./certs}
DAYS=${CERT_DAYS:-825}
CA_DAYS=${CA_DAYS:-3650}

env_val() { [ -f .env ] && sed -n "s/^$1=//p" .env | tail -n1 | tr -d '\r"' || true; }
LAN_HOST=${LAN_HOST:-$(env_val LAN_HOST)}
ET_HOST=${ET_HOST:-$(env_val ET_HOST)}
DSH_IMAGE=${DSH_IMAGE:-$(env_val DSH_IMAGE)}
DSH_IMAGE=${DSH_IMAGE:-ghcr.io/zuziceng/dsh-docker/deepseek-harness:rc}

# --- 选 openssl：宿主机优先，没有就借现成的 dsh 镜像跑一次 ---------------------
if command -v openssl >/dev/null 2>&1; then
	use_docker=""
elif docker image inspect "$DSH_IMAGE" >/dev/null 2>&1; then
	use_docker=$DSH_IMAGE
	echo "[cert] 宿主机没有 openssl，改用镜像 $DSH_IMAGE"
else
	echo "[cert] 找不到 openssl：apt install openssl（或先 up 一次，借用 dsh 镜像）" >&2
	exit 1
fi

openssl_run() {
	if [ -z "$use_docker" ]; then
		openssl "$@"
	else
		docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/work" -w /work \
			--entrypoint openssl "$use_docker" "$@"
	fi
}

# --- 收集地址 ----------------------------------------------------------------
is_ipv4() { printf '%s' "$1" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; }

# 本机全部全局 IPv4（去掉 loopback / link-local / 容器网桥）。多网卡、多网段是
# 常态，漏掉一个就会在那个地址上报证书错误，所以默认全收；docker0、br-*、veth*
# 这些容器侧地址外部访问不到，签进去只是噪音，排除掉。
local_ips() {
	if command -v ip >/dev/null 2>&1; then
		ip -4 -o addr show scope global 2>/dev/null | awk '{print $2, $4}' \
			| while read -r ifc cidr; do
				case "$ifc" in docker* | br-* | veth* | virbr* | cni* | flannel* | tunl*) continue ;; esac
				printf '%s\n' "${cidr%/*}"
			done
	else
		hostname -I 2>/dev/null | tr ' ' '\n'
	fi | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | grep -vE '^(127\.|169\.254\.)' || true
}

IPS=$(local_ips)
DNS_NAMES="localhost"
IPS=$(printf '%s\n127.0.0.1\n' "$IPS" | sed '/^$/d' | sort -u)

# .env 里填的地址：IP 并进 IP 列表，域名进 DNS 列表
for h in $(printf '%s %s\n' "$LAN_HOST" "$ET_HOST" | tr ',;' '  ' | sed '/^$/d'); do
	if is_ipv4 "$h"; then
		IPS=$(printf '%s\n%s\n' "$IPS" "$h" | sed '/^$/d' | sort -u)
	else
		DNS_NAMES="$DNS_NAMES $h"
	fi
done
DNS_NAMES=$(printf '%s\n' $DNS_NAMES | sed '/^$/d' | sort -u)

mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

# --- 证书配置（SAN 列表） ------------------------------------------------------
{
	printf '[req]\n distinguished_name = dn\n prompt = no\n'
	printf '[dn]\n CN = dsh\n'
	printf '[ext]\n basicConstraints = critical, CA:FALSE\n'
	printf ' keyUsage = critical, digitalSignature, keyEncipherment\n'
	printf ' extendedKeyUsage = serverAuth\n'
	printf ' subjectAltName = @alt\n[alt]\n'
	i=0
	for ip in $IPS; do
		i=$((i + 1))
		printf ' IP.%d = %s\n' "$i" "$ip"
	done
	j=0
	for name in $DNS_NAMES; do
		j=$((j + 1))
		printf ' DNS.%d = %s\n' "$j" "$name"
	done
} >openssl.cnf

echo "[cert] IP  : $(echo $IPS | tr ' ' ',')"
echo "[cert] 域名: $(echo $DNS_NAMES | tr ' ' ',')"

# --- CA：只在缺失时创建，保证客户端已装的根证书长期有效 -------------------------
if [ "$FORCE" = 1 ] || [ ! -s ca.crt ] || [ ! -s ca.key ]; then
	echo "[cert] 生成根证书 ca.crt（有效期 ${CA_DAYS} 天）"
	openssl_run req -x509 -newkey rsa:2048 -nodes -sha256 -days "$CA_DAYS" \
		-keyout ca.key -out ca.crt -subj "/CN=dsh local CA" \
		-addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
		-addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
fi

# --- 叶子证书：每次重签，顺带刷有效期 -------------------------------------------
echo "[cert] 签发 dsh.crt（有效期 ${DAYS} 天）"
openssl_run req -new -newkey rsa:2048 -nodes -sha256 \
	-keyout dsh.key -out dsh.csr -config openssl.cnf 2>/dev/null
openssl_run x509 -req -in dsh.csr -sha256 -days "$DAYS" \
	-CA ca.crt -CAkey ca.key -CAcreateserial \
	-extfile openssl.cnf -extensions ext -out dsh.crt 2>/dev/null
rm -f dsh.csr

chmod 600 dsh.key ca.key
chmod 644 dsh.crt ca.crt
cd - >/dev/null

# --- 让 Caddy 重新加载（容器在跑就顺带重启） ------------------------------------
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'deepseek-harness-caddy'; then
	docker compose restart caddy >/dev/null 2>&1 && echo "[cert] 已重启 caddy 使其加载新证书"
fi

cat <<EOF

完成。客户端安装根证书一次即可消掉告警：
  scp $CERT_DIR/ca.crt <客户端>:   然后导入「受信任根证书」

Windows: certutil -addstore -f Root ca.crt
macOS  : sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt
Linux  : sudo cp ca.crt /usr/local/share/ca-certificates/dsh.crt && sudo update-ca-certificates

换 IP / 加网卡后重跑本脚本即可（CA 不变，客户端不用重装）。
EOF
