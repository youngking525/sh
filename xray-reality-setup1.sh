#!/bin/bash
# ==============================================================
#  Xray VLESS+Reality 极高兼容性安装脚本 (Alpine/Debian/Ubuntu)
#  用法：bash setup.sh [端口号]
# ==============================================================

set -e

# ─── 颜色定义 ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()    { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }

# ─── 权限与环境检查 ──────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || error "请用 root 用户执行此脚本"

# ─── 获取端口号 ────────────────────────────────────────────────
PORT="$1"
if [ -z "$PORT" ]; then
    read -rp "请输入监听端口号（默认 25443）: " PORT
    PORT="${PORT:-25443}"
fi

# ─── 第一步：安装依赖 ───────────────────────────────────────────
info "同步软件包索引并安装依赖..."
if [ -f /etc/alpine-release ]; then
    apk update -q
    apk add -q curl unzip bash openssl
else
    apt-get update -y -q && apt-get install -y -q curl unzip openssl
fi
success "依赖安装完成"

# ─── 第二步：下载 Xray ──────────────────────────────────────────
info "获取 Xray 最新版本..."
XRAY_VER=$(curl -fsSL -o /dev/null -w "%{url_effective}" \
    https://github.com/XTLS/Xray-core/releases/latest \
    | sed 's|.*/tag/||')
[ -n "$XRAY_VER" ] || error "获取 Xray 版本失败"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

info "下载并安装 Xray (${XRAY_VER})..."
# 默认使用 linux-64，如果你的机子是 ARM 请改为 linux-arm64-v8a
curl -fsSL "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip" \
    -o "$TMPDIR/xray.zip"
unzip -q "$TMPDIR/xray.zip" -d "$TMPDIR/xray"
install -m 755 "$TMPDIR/xray/xray" /usr/local/bin/xray
success "Xray 安装路径: /usr/local/bin/xray"

# ─── 第三步：生成参数 (高兼容性提取逻辑) ───────────────────────────
info "生成配置参数..."
UUID=$(/usr/local/bin/xray uuid)

# 关键：使用 sed 直接提取冒号后的内容并过滤掉所有空格
KEYPAIR=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "$KEYPAIR" | sed -n 's/.*Private.*key: \([^ ]*\).*/\1/p')
PUBLIC_KEY=$(echo "$KEYPAIR" | sed -n 's/.*Public.*key: \([^ ]*\).*/\1/p')

# 二次校验，如果上述提取失败，采用最原始的提取方式
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep -i "Private" | cut -d: -f2 | tr -d '[:space:]')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep -i "Public" | cut -d: -f2 | tr -d '[:space:]')
fi

[ -n "$PRIVATE_KEY" ] || error "私钥提取失败，请检查输出: $KEYPAIR"

SHORT_ID=$(openssl rand -hex 4)
success "参数生成成功"

# ─── 第四步：写入 Xray 配置 ──────────────────────────────────────
info "写入配置文件 /etc/xray/config.json ..."
mkdir -p /etc/xray
cat > /etc/xray/config.json << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${UUID}", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "www.microsoft.com:443",
        "xver": 0,
        "serverNames": ["www.microsoft.com"],
        "privateKey": "${PRIVATE_KEY}",
        "shortIds": ["${SHORT_ID}"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF

# ─── 第五步：服务管理 (兼容 OpenRC/Systemd) ──────────────────────
if [ -f /etc/alpine-release ]; then
    info "创建 Alpine OpenRC 服务..."
    cat > /etc/init.d/xray << 'INITEOF'
#!/sbin/openrc-run
name="xray"
command="/usr/local/bin/xray"
command_args="run -config /etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
depend() { need net; }
INITEOF
    chmod +x /etc/init.d/xray
    rc-service xray start || true
    rc-update add xray default || true
else
    info "创建 Systemd 服务..."
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray
    systemctl start xray
fi

# ─── 最终输出 ──────────────────────────────────────────────────
SERVER_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || echo "请自行确认IP")

echo -e "\n${BOLD}${GREEN}========================================${RESET}"
echo -e "  服务器 IP    : ${YELLOW}${SERVER_IP}${RESET}"
echo -e "  端口        : ${YELLOW}${PORT}${RESET}"
echo -e "  UUID        : ${YELLOW}${UUID}${RESET}"
echo -e "  PublicKey   : ${YELLOW}${PUBLIC_KEY}${RESET}"
echo -e "  ShortId     : ${YELLOW}${SHORT_ID}${RESET}"
echo -e "  Flow        : xtls-rprx-vision"
echo -e "  Security    : reality"
echo -e "  SNI         : www.microsoft.com"
echo -e "${BOLD}${GREEN}========================================${RESET}\n"
