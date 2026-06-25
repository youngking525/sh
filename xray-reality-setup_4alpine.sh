#!/bin/bash
# ==============================================================
#  Xray VLESS+Reality 分步安装脚本（Alpine Linux）
#
#  用法：
#    bash xray-reality-steps.sh          # 显示步骤菜单
#    bash xray-reality-steps.sh <步骤号>  # 直接执行某步
#    bash xray-reality-steps.sh all      # 一次性执行全部步骤
#
#  步骤列表：
#    1  安装系统依赖
#    2  下载并安装 Xray 二进制
#    3  生成 UUID / 密钥对 / ShortId（写入状态文件）
#    4  写入 Xray 配置文件（读取状态文件）
#    5  验证配置文件
#    6  创建并启动 OpenRC 服务
#    7  输出客户端配置 & 分享链接
#
#  状态文件：/etc/xray/.install_state
#  如需更换端口，修改 PORT 变量后从步骤 3 重新执行即可。
# ==============================================================

set -eo pipefail

# ─── 颜色 ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }

# ─── 状态文件路径 ─────────────────────────────────────────────
STATE_FILE="/etc/xray/.install_state"

# ─── 保存 / 读取状态 ──────────────────────────────────────────
save_state() {
    mkdir -p /etc/xray
    cat > "$STATE_FILE" << STEOF
PORT="${PORT}"
UUID="${UUID}"
PRIVATE_KEY="${PRIVATE_KEY}"
PUBLIC_KEY="${PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
STEOF
    chmod 600 "$STATE_FILE"
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        # shellcheck source=/dev/null
        . "$STATE_FILE"
    fi
}

# ─── 必须 root ────────────────────────────────────────────────
check_root() {
    [ "$(id -u)" -eq 0 ] || error "请用 root 用户执行此脚本"
}

# ==============================================================
#  各步骤函数
# ==============================================================

step1_install_deps() {
    echo -e "\n${BOLD}[步骤 1] 安装系统依赖${RESET}"
    [ -f /etc/alpine-release ] || warn "未检测到 Alpine Linux，继续执行..."
    apk update -q
    apk add -q curl unzip bash openssl
    success "依赖安装完成（curl unzip bash openssl）"
}

step2_download_xray() {
    echo -e "\n${BOLD}[步骤 2] 下载并安装 Xray${RESET}"

    info "获取 Xray 最新版本..."
    XRAY_VER=$(curl -fsSL -o /dev/null -w "%{url_effective}" \
        https://github.com/XTLS/Xray-core/releases/latest \
        | sed 's|.*/tag/||')
    [ -n "$XRAY_VER" ] || error "获取 Xray 版本失败，请检查网络"
    info "最新版本：${XRAY_VER}"

    TMPDIR_DL=$(mktemp -d)
    # 不用 trap EXIT，避免干扰外层
    info "下载 Xray-linux-64.zip..."
    curl -fsSL \
        "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip" \
        -o "$TMPDIR_DL/xray.zip" \
        || error "下载失败，请检查网络"

    unzip -q "$TMPDIR_DL/xray.zip" -d "$TMPDIR_DL/xray"
    install -m 755 "$TMPDIR_DL/xray/xray" /usr/local/bin/xray
    rm -rf "$TMPDIR_DL"

    success "Xray ${XRAY_VER} 安装完成 → /usr/local/bin/xray"
}

step3_gen_params() {
    echo -e "\n${BOLD}[步骤 3] 生成 UUID / 密钥对 / ShortId${RESET}"

    # 读取已有状态中的 PORT，允许命令行覆盖
    load_state
    if [ -n "$CMD_PORT" ]; then
        PORT="$CMD_PORT"
    elif [ -z "$PORT" ]; then
        read -rp "请输入监听端口号（默认 25443）: " PORT
        PORT="${PORT:-25443}"
    else
        info "沿用上次保存的端口：${PORT}"
    fi

    if ! echo "$PORT" | grep -qE '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        error "端口号无效：$PORT（需为 1-65535 的整数）"
    fi

    command -v xray > /dev/null 2>&1 || error "未找到 xray，请先执行步骤 2"

    info "生成 UUID..."
    UUID=$(xray uuid)
    [ -n "$UUID" ] || error "UUID 生成失败"
    success "UUID：${UUID}"

    info "生成 Reality 密钥对..."
    KEYPAIR=$(xray x25519 2>&1 || true)

    PRIVATE_KEY=$(echo "$KEYPAIR" \
        | grep -E "PrivateKey|Private key" \
        | head -n1 | cut -d ':' -f2- | xargs)

    PUBLIC_KEY=$(echo "$KEYPAIR" \
        | grep -E "PublicKey|Public key" \
        | head -n1 | cut -d ':' -f2- | xargs)

    if [ -z "$PUBLIC_KEY" ]; then
        PUBLIC_KEY=$(echo "$KEYPAIR" \
            | grep "Password (PublicKey)" \
            | head -n1 | cut -d ':' -f2- | xargs)
    fi

    [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] \
        || error "密钥对生成失败，原始输出：${KEYPAIR}"
    success "密钥对生成完成"
    success "  PrivateKey : ${PRIVATE_KEY}"
    success "  PublicKey  : ${PUBLIC_KEY}"

    info "生成 ShortId..."
    SHORT_ID=$(openssl rand -hex 4)
    [ -n "$SHORT_ID" ] || error "ShortId 生成失败"
    success "ShortId：${SHORT_ID}"

    save_state
    success "参数已保存到 ${STATE_FILE}"
}

step4_write_config() {
    echo -e "\n${BOLD}[步骤 4] 写入 Xray 配置文件${RESET}"

    load_state
    [ -n "$UUID" ]        || error "缺少 UUID，请先执行步骤 3"
    [ -n "$PRIVATE_KEY" ] || error "缺少 PrivateKey，请先执行步骤 3"
    [ -n "$PORT" ]        || error "缺少 PORT，请先执行步骤 3"
    [ -n "$SHORT_ID" ]    || error "缺少 ShortId，请先执行步骤 3"

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
      "listen": "::",
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
          "dest": "www.zhihu.com:443",
          "xver": 0,
          "serverNames": [
            "www.zhihu.com"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
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

    success "配置文件已写入 /etc/xray/config.json"
}

step5_verify_config() {
    echo -e "\n${BOLD}[步骤 5] 验证配置文件${RESET}"

    command -v xray > /dev/null 2>&1 || error "未找到 xray，请先执行步骤 2"
    [ -f /etc/xray/config.json ]     || error "配置文件不存在，请先执行步骤 4"

    info "运行 xray 配置测试..."
    TEST_OUTPUT=$(xray run -test -config /etc/xray/config.json 2>&1 || true)

    if echo "$TEST_OUTPUT" | grep -q "Configuration OK"; then
        success "配置文件验证通过"
    else
        echo
        echo "========== Xray 原始输出 =========="
        echo "$TEST_OUTPUT"
        echo "===================================="
        error "配置文件验证失败，请检查步骤 3/4 的输出"
    fi
}

step6_setup_service() {
    echo -e "\n${BOLD}[步骤 6] 创建并启动 OpenRC 服务${RESET}"

    [ -f /etc/xray/config.json ] || error "配置文件不存在，请先执行步骤 4"

    info "写入 /etc/init.d/xray..."
    cat > /etc/init.d/xray << 'INITEOF'
#!/sbin/openrc-run

name="xray"
description="Xray Proxy Service"

command="/usr/local/bin/xray"
command_args="run -config /etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"

output_log="/var/log/xray-stdout.log"
error_log="/var/log/xray-error.log"

depend() {
    need net
    after firewall
}
INITEOF

    chmod +x /etc/init.d/xray
    success "OpenRC 服务文件写入完成"

    info "启动 Xray 服务..."
    rc-service xray restart > /dev/null 2>&1 \
        || rc-service xray start > /dev/null 2>&1 \
        || error "Xray 启动失败，查看日志：tail -f /var/log/xray-error.log"

    rc-update add xray default > /dev/null 2>&1
    success "Xray 服务已启动并设为开机自启"

    info "当前服务状态："
    rc-service xray status || true
}

step7_show_info() {
    echo -e "\n${BOLD}[步骤 7] 输出客户端配置${RESET}"

    load_state
    [ -n "$UUID" ]       || error "缺少配置参数，请先执行步骤 3"
    [ -n "$PUBLIC_KEY" ] || error "缺少 PublicKey，请先执行步骤 3"
    [ -n "$PORT" ]       || error "缺少 PORT，请先执行步骤 3"
    [ -n "$SHORT_ID" ]   || error "缺少 ShortId，请先执行步骤 3"

    info "获取公网 IP..."

    SERVER_IPV4=$(
        curl -4fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -4fsSL --max-time 5 https://api4.ipify.org 2>/dev/null \
        || curl -4fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
        || echo ""
    )

    SERVER_IPV6=$(
        curl -6fsSL --max-time 5 https://api6.ipify.org 2>/dev/null \
        || curl -6fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
        || echo ""
    )

    VLESS_PARAMS="encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.zhihu.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp"

    [ -n "$SERVER_IPV4" ] && VLESS_LINK_V4="vless://${UUID}@${SERVER_IPV4}:${PORT}?${VLESS_PARAMS}#Xray-Reality-v4"
    [ -n "$SERVER_IPV6" ] && VLESS_LINK_V6="vless://${UUID}@[${SERVER_IPV6}]:${PORT}?${VLESS_PARAMS}#Xray-Reality-v6"

    echo
    echo -e "${BOLD}${GREEN}============================================${RESET}"
    echo -e "${BOLD}${GREEN}        安装完成！客户端配置如下           ${RESET}"
    echo -e "${BOLD}${GREEN}============================================${RESET}"
    echo
    echo -e "  ${BOLD}--- 基本信息 ---${RESET}"
    if [ -n "$SERVER_IPV4" ]; then
        echo -e "  ${BOLD}IPv4 地址${RESET}   : ${YELLOW}${SERVER_IPV4}${RESET}"
    else
        echo -e "  ${BOLD}IPv4 地址${RESET}   : ${RED}未检测到${RESET}"
    fi
    if [ -n "$SERVER_IPV6" ]; then
        echo -e "  ${BOLD}IPv6 地址${RESET}   : ${YELLOW}${SERVER_IPV6}${RESET}"
    else
        echo -e "  ${BOLD}IPv6 地址${RESET}   : ${RED}未检测到${RESET}"
    fi
    echo -e "  ${BOLD}端口${RESET}        : ${YELLOW}${PORT}${RESET}"
    echo -e "  ${BOLD}协议${RESET}        : VLESS"
    echo -e "  ${BOLD}UUID${RESET}        : ${YELLOW}${UUID}${RESET}"
    echo -e "  ${BOLD}Flow${RESET}        : xtls-rprx-vision"
    echo -e "  ${BOLD}传输${RESET}        : TCP"
    echo -e "  ${BOLD}安全${RESET}        : reality"
    echo -e "  ${BOLD}SNI${RESET}         : www.zhihu.com"
    echo -e "  ${BOLD}PublicKey${RESET}   : ${YELLOW}${PUBLIC_KEY}${RESET}"
    echo -e "  ${BOLD}ShortId${RESET}     : ${YELLOW}${SHORT_ID}${RESET}"
    echo -e "  ${BOLD}Fingerprint${RESET} : chrome"

    if [ -n "$VLESS_LINK_V4" ] || [ -n "$VLESS_LINK_V6" ]; then
        echo
        echo -e "  ${BOLD}--- 分享链接（可直接导入客户端）---${RESET}"
        [ -n "$VLESS_LINK_V4" ] && echo -e "  ${BOLD}IPv4 链接${RESET} :\n  ${CYAN}${VLESS_LINK_V4}${RESET}"
        [ -n "$VLESS_LINK_V6" ] && echo -e "  ${BOLD}IPv6 链接${RESET} :\n  ${CYAN}${VLESS_LINK_V6}${RESET}"
    fi

    echo
    echo -e "${BOLD}${GREEN}============================================${RESET}"
    echo
    echo -e "查看日志：${CYAN}tail -f /var/log/xray-error.log${RESET}"
    echo -e "重启服务：${CYAN}rc-service xray restart${RESET}"
    echo -e "停止服务：${CYAN}rc-service xray stop${RESET}"
    echo -e "查看状态：${CYAN}rc-service xray status${RESET}"
    echo
}

# ==============================================================
#  菜单
# ==============================================================

show_menu() {
    echo
    echo -e "${BOLD}======================================${RESET}"
    echo -e "${BOLD}   Xray VLESS+Reality 分步安装器     ${RESET}"
    echo -e "${BOLD}   Alpine Linux 版本                 ${RESET}"
    echo -e "${BOLD}======================================${RESET}"
    echo
    echo -e "  ${CYAN}1${RESET}  安装系统依赖"
    echo -e "  ${CYAN}2${RESET}  下载并安装 Xray 二进制"
    echo -e "  ${CYAN}3${RESET}  生成 UUID / 密钥对 / ShortId"
    echo -e "  ${CYAN}4${RESET}  写入 Xray 配置文件"
    echo -e "  ${CYAN}5${RESET}  验证配置文件"
    echo -e "  ${CYAN}6${RESET}  创建并启动 OpenRC 服务"
    echo -e "  ${CYAN}7${RESET}  输出客户端配置 & 分享链接"
    echo -e "  ${CYAN}all${RESET} 一次性执行全部步骤"
    echo -e "  ${CYAN}q${RESET}  退出"
    echo
    echo -e "提示：执行步骤 3 时可通过环境变量指定端口，例如："
    echo -e "  ${YELLOW}PORT=25443 bash $0 3${RESET}"
    echo
}

run_step() {
    case "$1" in
        1)   step1_install_deps   ;;
        2)   step2_download_xray  ;;
        3)   step3_gen_params     ;;
        4)   step4_write_config   ;;
        5)   step5_verify_config  ;;
        6)   step6_setup_service  ;;
        7)   step7_show_info      ;;
        all)
            step1_install_deps
            step2_download_xray
            step3_gen_params
            step4_write_config
            step5_verify_config
            step6_setup_service
            step7_show_info
            ;;
        *)
            echo -e "${RED}无效选项：$1${RESET}"
            ;;
    esac
}

# ==============================================================
#  入口
# ==============================================================

check_root

# 支持通过环境变量传入端口（用于步骤 3）
CMD_PORT="${PORT:-}"

if [ -n "$1" ]; then
    # 命令行直接指定步骤
    run_step "$1"
else
    # 交互菜单
    show_menu
    while true; do
        read -rp "$(echo -e "${BOLD}请输入步骤编号（1-7 / all / q）：${RESET}")" CHOICE
        case "$CHOICE" in
            q|Q|quit|exit) echo "退出。"; exit 0 ;;
            "") show_menu ;;
            *) run_step "$CHOICE" ;;
        esac
        echo
        read -rp "$(echo -e "${CYAN}按 Enter 返回菜单，或输入下一个步骤号：${RESET}")" NEXT
        if [ -n "$NEXT" ]; then
            run_step "$NEXT"
        fi
    done
fi
