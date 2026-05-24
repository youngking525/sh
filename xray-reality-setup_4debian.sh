#!/bin/bash
# ==============================================================
#  Xray VLESS+Reality 一键安装脚本（Debian 11/12）
#  用法：bash xray-reality-setup-debian.sh [端口号]
#  示例：bash xray-reality-setup-debian.sh 25443
#        bash xray-reality-setup-debian.sh        # 不填则交互输入
# ==============================================================

set -eo pipefail

# ─── 颜色 ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }

# ─── 必须 root ────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || error "请用 root 用户执行此脚本"

# ─── 确认是 Debian ────────────────────────────────────────────
if [ ! -f /etc/debian_version ]; then
    warn "未检测到 Debian 系统，脚本可能不兼容，继续执行..."
fi

# ─── 获取端口号 ───────────────────────────────────────────────
PORT="$1"
if [ -z "$PORT" ]; then
    read -rp "请输入监听端口号（默认 25443）: " PORT
    PORT="${PORT:-25443}"
fi

# 校验端口范围
if ! echo "$PORT" | grep -qE '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    error "端口号无效：$PORT（需为 1-65535 的整数）"
fi

echo
echo -e "${BOLD}==============================${RESET}"
echo -e "${BOLD}  Xray VLESS+Reality 安装器  ${RESET}"
echo -e "${BOLD}==============================${RESET}"
echo -e "  监听端口：${YELLOW}${PORT}${RESET}"
echo

# ─── 第一步：安装依赖 ─────────────────────────────────────────
info "更新软件包列表..."
apt-get update -q
info "安装系统依赖..."
apt-get install -y -q curl unzip bash openssl
success "依赖安装完成"

# ─── 第二步：下载 Xray ────────────────────────────────────────
info "获取 Xray 最新版本..."

XRAY_VER=$(curl -fsSL -o /dev/null -w "%{url_effective}" \
    https://github.com/XTLS/Xray-core/releases/latest \
    | sed 's|.*/tag/||')

[ -n "$XRAY_VER" ] || error "获取 Xray 版本失败，请检查网络"

info "最新版本：${XRAY_VER}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

info "下载 Xray 二进制..."

curl -fsSL \
    "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip" \
    -o "$TMPDIR/xray.zip" \
    || error "下载失败，请检查网络"

unzip -q "$TMPDIR/xray.zip" -d "$TMPDIR/xray"

install -m 755 "$TMPDIR/xray/xray" /usr/local/bin/xray

success "Xray ${XRAY_VER} 安装完成 → /usr/local/bin/xray"

# ─── 第三步：生成参数 ─────────────────────────────────────────
info "生成 UUID..."

UUID=$(xray uuid)

[ -n "$UUID" ] || error "UUID 生成失败"

success "UUID：${UUID}"

info "生成 Reality 密钥对..."

KEYPAIR=$(xray x25519 2>&1 || true)

PRIVATE_KEY=$(echo "$KEYPAIR" \
    | grep -E "PrivateKey|Private key" \
    | head -n1 \
    | cut -d ':' -f2- \
    | xargs)

PUBLIC_KEY=$(echo "$KEYPAIR" \
    | grep -E "PublicKey|Public key" \
    | head -n1 \
    | cut -d ':' -f2- \
    | xargs)

# 兼容某些新版输出：Password (PublicKey)
if [ -z "$PUBLIC_KEY" ]; then
    PUBLIC_KEY=$(echo "$KEYPAIR" \
        | grep "Password (PublicKey)" \
        | head -n1 \
        | cut -d ':' -f2- \
        | xargs)
fi

[ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] \
    || error "密钥对生成失败，原始输出：${KEYPAIR}"

success "密钥对生成完成"

info "生成 ShortId..."

SHORT_ID=$(openssl rand -hex 4)

[ -n "$SHORT_ID" ] || error "ShortId 生成失败"

success "ShortId：${SHORT_ID}"

# ─── 第四步：写配置文件 ───────────────────────────────────────
info "写入 Xray 配置..."

mkdir -p /etc/xray

cat > /etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray-access.log",
    "error": "/var/log/xray-error.log"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": [
            "www.microsoft.com"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

# ─── 验证配置 ────────────────────────────────────────────────
info "验证配置文件..."

TEST_OUTPUT=$(xray run -test -config /etc/xray/config.json 2>&1 || true)

echo "$TEST_OUTPUT" | grep -q "Configuration OK"

if [ $? -eq 0 ]; then
    success "配置文件验证通过"
else
    echo
    echo "========== Xray 原始输出 =========="
    echo "$TEST_OUTPUT"
    echo "=================================="
    echo
    error "配置文件验证失败"
fi

# ─── 第五步：创建 systemd 服务 ────────────────────────────────
info "创建 systemd 服务..."

cat > /etc/systemd/system/xray.service << 'UNITEOF'
[Unit]
Description=Xray Proxy Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

# 日志重定向（可选，配置文件里已有日志路径）
StandardOutput=journal
StandardError=journal
SyslogIdentifier=xray

[Install]
WantedBy=multi-user.target
UNITEOF

# 重载 systemd 配置
systemctl daemon-reload

# ─── 启动服务 ────────────────────────────────────────────────
info "启动 Xray 服务..."

systemctl restart xray 2>/dev/null || \
systemctl start xray 2>/dev/null || \
error "Xray 启动失败，请查看日志：journalctl -u xray -n 50"

# 设为开机自启
systemctl enable xray > /dev/null 2>&1

success "Xray 服务已启动并设为开机自启"

# ─── 获取服务器公网 IP ───────────────────────────────────────
info "获取公网 IP..."

SERVER_IP=$(
    curl -4fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -4fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
    || echo "请手动填写"
)

# ─── 最终输出 ─────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}========================================${RESET}"
echo -e "${BOLD}${GREEN}       安装完成！客户端配置如下         ${RESET}"
echo -e "${BOLD}${GREEN}========================================${RESET}"

echo -e "  ${BOLD}服务器 IP${RESET}   : ${YELLOW}${SERVER_IP}${RESET}"
echo -e "  ${BOLD}端口${RESET}        : ${YELLOW}${PORT}${RESET}"
echo -e "  ${BOLD}协议${RESET}        : VLESS"
echo -e "  ${BOLD}UUID${RESET}        : ${YELLOW}${UUID}${RESET}"
echo -e "  ${BOLD}Flow${RESET}        : xtls-rprx-vision"
echo -e "  ${BOLD}传输${RESET}        : TCP"
echo -e "  ${BOLD}安全${RESET}        : reality"
echo -e "  ${BOLD}SNI${RESET}         : www.microsoft.com"
echo -e "  ${BOLD}PublicKey${RESET}   : ${YELLOW}${PUBLIC_KEY}${RESET}"
echo -e "  ${BOLD}ShortId${RESET}     : ${YELLOW}${SHORT_ID}${RESET}"
echo -e "  ${BOLD}Fingerprint${RESET} : chrome"

echo -e "${BOLD}${GREEN}========================================${RESET}"
echo

echo -e "查看错误日志：${CYAN}tail -f /var/log/xray-error.log${RESET}"
echo -e "查看系统日志：${CYAN}journalctl -u xray -f${RESET}"
echo -e "重启服务：    ${CYAN}systemctl restart xray${RESET}"
echo -e "停止服务：    ${CYAN}systemctl stop xray${RESET}"
echo -e "查看状态：    ${CYAN}systemctl status xray${RESET}"
echo
