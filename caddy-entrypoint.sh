#!/bin/sh
# Caddy 容器入口：决定用哪张证书，然后把 Caddyfile 交给 caddy。
#
# 只做一件事 —— 选出 TLS 指令。两种来源：
#   /certs/dsh.crt + dsh.key   ./gen-cert.sh 生成，一张证书覆盖所有访问地址
#   否则                        Caddy 内置 CA，只为 LAN_HOST 的第一个地址签
#
# 之所以要前者：浏览器访问裸 IP 时不发 SNI（RFC 6066），Caddy 无法按地址挑证书，
# 只能拿 default_sni 那一张去比对，于是除了那一个 IP 之外全报「证书不匹配」。
# 把全部地址塞进同一张证书的 SAN 是唯一干净的解法。
set -eu

PORT=${LAN_PORT:-3080}
CERT=${TLS_CERT:-/certs/dsh.crt}
KEY=${TLS_KEY:-/certs/dsh.key}

# hostname -I 之类探测放在 gen-cert.sh 里做；这里只按 .env 解析第一个地址。
first_host() {
	printf '%s\n' "$1" | tr ',;' '\n' | tr -s '[:space:]' '\n' | sed '/^$/d' | head -n1
}

if [ -s "$CERT" ] && [ -s "$KEY" ]; then
	TLS_DIRECTIVE="tls $CERT $KEY"
	SNI_DIRECTIVE="# 静态证书已覆盖全部入口地址，无需 default_sni"
	echo "[caddy] 证书：$CERT"
else
	host=$(first_host "${LAN_HOST:-}")
	if [ -z "$host" ]; then
		echo "[caddy] 既没有 $CERT，LAN_HOST 也没填 —— 无法启用 HTTPS。" >&2
		echo "[caddy] 在宿主机跑 ./gen-cert.sh 生成多地址证书，或把 LAN_HOST 填成实际访问的 IP/域名。" >&2
		exit 1
	fi
	case "$host" in
	0.0.0.0 | :: | '*')
		echo "[caddy] LAN_HOST=$host 是通配地址，签出来的证书覆盖不了真实 IP。" >&2
		echo "[caddy] 改成实际访问的 IP/域名（多个用逗号分隔），或先跑 ./gen-cert.sh。" >&2
		exit 1
		;;
	esac
	TLS_DIRECTIVE="tls internal"
	SNI_DIRECTIVE="default_sni $host"
	echo "[caddy] 未找到静态证书，回退内置 CA，证书名：$host"
	echo "[caddy] （这次只覆盖这一个地址；跑 ./gen-cert.sh 可以一次覆盖全部）"
fi

export TLS_DIRECTIVE SNI_DIRECTIVE LAN_PORT="$PORT"

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile "$@"
