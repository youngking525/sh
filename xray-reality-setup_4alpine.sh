#!/bin/bash
# ==============================================================
#  Xray VLESS+Reality 安装 / 卸载脚本（Alpine Linux，分步版）
#
#  用法：
#    bash xray-reality-steps.sh              # 主菜单（选安装或卸载）
#    bash xray-reality-steps.sh install      # 直接进入安装菜单
#    bash xray-reality-steps.sh install <N>  # 直接执行安装步骤 N
#    bash xray-reality-steps.sh install all  # 一次性完整安装
#    bash xray-reality-steps.sh remove       # 直接进入卸载菜单
#    bash xray-reality-steps.sh remove <N>   # 直接执行卸载步骤 N
#    bash xray-reality-steps.sh remove all   # 一次性完整卸载
#
#  安装步骤：
#    1  安装系统依赖
#    2  下载并安装 Xray 二进制
#    3  生成 UUID / 密钥对 / ShortId（写入状态文件）
#    4  写入 Xray 配置文件（读取状态文件）
#    5  验证配置文件
#    6  创建并启动 OpenRC 服务
#    7  输出客户端配置 & 分享链接
#
#  卸载步骤：
#    1  停止服务并移除开机自启
#    2  删除 OpenRC 服务文件
#    3  删除二进制文件
#    4  删除配置目录（配置文件 / 状态文件）
#    5  删除日志文件
#
#  状态文件：/etc/xray/.install_state
#  如需更换端口，修改后从安装步骤 3 重新执行即可。
# ==============================================================

set -eo pipefail

# ─── 颜色 ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }

# ─── 路径常量 ─────────────────────────────────────────────────
STATE_FILE="/etc/xray/.install_state"
BIN_PATH="/usr/local/bin/xray"

# ─── 保存 / 读取状态 ──────────────────────────────────────────
save_state() {
    mkdir -p /etc/xray
    cat > "$STATE_FILE" << STEOF
PORT="${PORT}"
UUID="${UUID}"
PRIVATE_KEY="${PRIVATE_KEY}"
PUBLIC_KEY="${PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
SNI="${SNI}"
STEOF
    chmod 600 "$STATE_FILE"
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        . "$STATE_FILE" || true
    fi
}

# ─── 必须 root ────────────────────────────────────────────────
check_root() {
    [ "$(id -u)" -eq 0 ] || error "请用 root 用户执行此脚本"
}

# ==============================================================
#  安装步骤
# ==============================================================

step_install_1() {
    echo -e "\n${BOLD}[安装 1/7] 安装系统依赖${RESET}"
    [ -f /etc/alpine-release ] || warn "未检测到 Alpine Linux，继续执行..."
    apk update -q
    apk add -q curl unzip bash openssl
    success "依赖安装完成（curl unzip bash openssl）"
}

step_install_2() {
    echo -e "\n${BOLD}[安装 2/7] 下载并安装 Xray${RESET}"

    info "获取 Xray 最新版本..."
    XRAY_VER=$(curl -fsSL -o /dev/null -w "%{url_effective}" \
        https://github.com/XTLS/Xray-core/releases/latest \
        | sed 's|.*/tag/||')
    [ -n "$XRAY_VER" ] || error "获取 Xray 版本失败，请检查网络"
    info "最新版本：${XRAY_VER}"

    TMPDIR_DL=$(mktemp -d)
    info "下载 Xray-linux-64.zip..."
    curl -fsSL \
        "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip" \
        -o "$TMPDIR_DL/xray.zip" \
        || error "下载失败，请检查网络"

    unzip -q "$TMPDIR_DL/xray.zip" -d "$TMPDIR_DL/xray"
    install -m 755 "$TMPDIR_DL/xray/xray" "$BIN_PATH"
    rm -rf "$TMPDIR_DL"

    success "Xray ${XRAY_VER} 安装完成 → ${BIN_PATH}"
}

step_install_3() {
    echo -e "\n${BOLD}[安装 3/7] 生成 UUID / 密钥对 / ShortId${RESET}"

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

    if [ -z "$SNI" ]; then
        SNI="www.zhihu.com"
    fi
    info "Reality 伪装域名（SNI）：${SNI}"

    command -v xray > /dev/null 2>&1 || error "未找到 xray，请先执行安装步骤 2"

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

step_install_4() {
    echo -e "\n${BOLD}[安装 4/7] 写入 Xray 配置文件${RESET}"

    load_state
    [ -n "$UUID" ]        || error "缺少 UUID，请先执行安装步骤 3"
    [ -n "$PRIVATE_KEY" ] || error "缺少 PrivateKey，请先执行安装步骤 3"
    [ -n "$PORT" ]        || error "缺少 PORT，请先执行安装步骤 3"
    [ -n "$SHORT_ID" ]    || error "缺少 ShortId，请先执行安装步骤 3"
    [ -n "$SNI" ]         || error "缺少 SNI，请先执行安装步骤 3"

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
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": [
            "${SNI}"
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

step_install_5() {
    echo -e "\n${BOLD}[安装 5/7] 验证配置文件${RESET}"

    command -v xray > /dev/null 2>&1 || error "未找到 xray，请先执行安装步骤 2"
    [ -f /etc/xray/config.json ]     || error "配置文件不存在，请先执行安装步骤 4"

    info "运行 xray 配置测试..."
    TEST_OUTPUT=$(xray run -test -config /etc/xray/config.json 2>&1 || true)

    if echo "$TEST_OUTPUT" | grep -q "Configuration OK"; then
        success "配置文件验证通过"
    else
        echo
        echo "========== Xray 原始输出 =========="
        echo "$TEST_OUTPUT"
        echo "===================================="
        error "配置文件验证失败，请检查安装步骤 3/4 的输出"
    fi
}

step_install_6() {
    echo -e "\n${BOLD}[安装 6/7] 创建并启动 OpenRC 服务${RESET}"

    [ -f /etc/xray/config.json ] || error "配置文件不存在，请先执行安装步骤 4"

    info "写入 /etc/init.d/xray..."
    cat > /etc/init.d/xray << INITEOF
#!/sbin/openrc-run

name="xray"
description="Xray Proxy Service"

command="${BIN_PATH}"
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
        || true

    rc-update add xray default > /dev/null 2>&1
    success "Xray 服务已设为开机自启"

    info "当前服务状态："
    rc-service xray status || true

    if ! pgrep -f "xray run" > /dev/null 2>&1; then
        echo
        warn "进程未检测到，最近的错误日志："
        tail -n 20 /var/log/xray-error.log 2>/dev/null || warn "日志文件不存在"
        echo
        error "服务未正常启动，请根据以上日志排查后重新执行本步骤"
    fi
}

step_install_7() {
    echo -e "\n${BOLD}[安装 7/7] 输出客户端配置${RESET}"

    load_state
    [ -n "$UUID" ]       || error "缺少配置参数，请先执行安装步骤 3"
    [ -n "$PUBLIC_KEY" ] || error "缺少 PublicKey，请先执行安装步骤 3"
    [ -n "$PORT" ]       || error "缺少 PORT，请先执行安装步骤 3"
    [ -n "$SHORT_ID" ]   || error "缺少 ShortId，请先执行安装步骤 3"
    [ -n "$SNI" ]        || error "缺少 SNI，请先执行安装步骤 3"

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

    VLESS_PARAMS="encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp"

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
    echo -e "  ${BOLD}SNI${RESET}         : ${SNI}"
    echo -e "  ${BOLD}PublicKey${RESET}   : ${YELLOW}${PUBLIC_KEY}${RESET}"
    echo -e "  ${BOLD}ShortId${RESET}     : ${YELLOW}${SHORT_ID}${RESET}"
    echo -e "  ${BOLD}Fingerprint${RESET} : chrome"

    echo
    echo -e "  ${BOLD}--- Nikki/Clash 节点格式 ---${RESET}"
    if [ -n "$SERVER_IPV4" ]; then
        echo -e "  ${CYAN}- {name: VLESS-Reality-节点, type: vless, server: ${SERVER_IPV4}, port: ${PORT}, uuid: ${UUID}, network: tcp, tls: true, flow: xtls-rprx-vision, servername: ${SNI}, reality-opts: {public-key: ${PUBLIC_KEY}, short-id: \"${SHORT_ID}\"}, client-fingerprint: chrome}${RESET}"
    fi

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
#  卸载步骤
# ==============================================================

step_remove_1() {
    echo -e "\n${BOLD}[卸载 1/5] 停止服务并移除开机自启${RESET}"

    if [ -f /etc/init.d/xray ]; then
        info "停止 Xray 服务..."
        rc-service xray stop > /dev/null 2>&1 || true
        rc-update del xray default > /dev/null 2>&1 || true
        success "服务已停止，开机自启已移除"
    else
        warn "未找到 OpenRC 服务文件，跳过"
    fi
}

step_remove_2() {
    echo -e "\n${BOLD}[卸载 2/5] 删除 OpenRC 服务文件${RESET}"

    if [ -f /etc/init.d/xray ]; then
        rm -f /etc/init.d/xray
        success "已删除 /etc/init.d/xray"
    else
        warn "/etc/init.d/xray 不存在，跳过"
    fi

    rm -f /run/xray.pid
}

step_remove_3() {
    echo -e "\n${BOLD}[卸载 3/5] 删除二进制文件${RESET}"

    if [ -f "$BIN_PATH" ]; then
        rm -f "$BIN_PATH"
        success "已删除 ${BIN_PATH}"
    else
        warn "${BIN_PATH} 不存在，跳过"
    fi
}

step_remove_4() {
    echo -e "\n${BOLD}[卸载 4/5] 删除配置目录（配置文件 / 状态文件）${RESET}"

    if [ -d /etc/xray ]; then
        info "将删除以下内容："
        ls -la /etc/xray/ 2>/dev/null || true
        echo
        read -rp "$(echo -e "${YELLOW}确认删除 /etc/xray 目录？[y/N]：${RESET}")" CONFIRM
        case "$CONFIRM" in
            y|Y|yes|YES)
                rm -rf /etc/xray
                success "已删除 /etc/xray/"
                ;;
            *)
                warn "已跳过，目录保留"
                ;;
        esac
    else
        warn "/etc/xray 目录不存在，跳过"
    fi
}

step_remove_5() {
    echo -e "\n${BOLD}[卸载 5/5] 删除日志文件${RESET}"

    REMOVED=0
    for f in /var/log/xray-stdout.log /var/log/xray-error.log /var/log/xray-access.log; do
        if [ -f "$f" ]; then
            rm -f "$f"
            success "已删除 ${f}"
            REMOVED=$((REMOVED + 1))
        fi
    done

    if [ "$REMOVED" -eq 0 ]; then
        warn "未找到日志文件，跳过"
    fi

    echo
    echo -e "${BOLD}${GREEN}============================================${RESET}"
    echo -e "${BOLD}${GREEN}           Xray 卸载完成                   ${RESET}"
    echo -e "${BOLD}${GREEN}============================================${RESET}"
    echo
}

# ==============================================================
#  菜单
# ==============================================================

show_main_menu() {
    echo
    echo -e "${BOLD}======================================${RESET}"
    echo -e "${BOLD}   Xray VLESS+Reality 管理脚本       ${RESET}"
    echo -e "${BOLD}   Alpine Linux 版本                 ${RESET}"
    echo -e "${BOLD}======================================${RESET}"
    echo
    echo -e "  ${GREEN}i${RESET}  安装 Xray VLESS+Reality"
    echo -e "  ${RED}r${RESET}  卸载 Xray VLESS+Reality"
    echo -e "  ${CYAN}q${RESET}  退出"
    echo
}

show_install_menu() {
    echo
    echo -e "${BOLD}${GREEN}======================================${RESET}"
    echo -e "${BOLD}${GREEN}   Xray 安装步骤                     ${RESET}"
    echo -e "${BOLD}${GREEN}======================================${RESET}"
    echo
    echo -e "  ${CYAN}1${RESET}  安装系统依赖"
    echo -e "  ${CYAN}2${RESET}  下载并安装 Xray 二进制"
    echo -e "  ${CYAN}3${RESET}  生成 UUID / 密钥对 / ShortId"
    echo -e "  ${CYAN}4${RESET}  写入 Xray 配置文件"
    echo -e "  ${CYAN}5${RESET}  验证配置文件"
    echo -e "  ${CYAN}6${RESET}  创建并启动 OpenRC 服务"
    echo -e "  ${CYAN}7${RESET}  输出客户端配置 & 分享链接"
    echo -e "  ${CYAN}all${RESET} 一次性执行全部安装步骤"
    echo -e "  ${CYAN}b${RESET}  返回主菜单"
    echo -e "  ${CYAN}q${RESET}  退出"
    echo
    echo -e "提示：执行步骤 3 时可通过环境变量指定端口，例如："
    echo -e "  ${YELLOW}PORT=25443 bash $0 install 3${RESET}"
    echo
}

show_remove_menu() {
    echo
    echo -e "${BOLD}${RED}======================================${RESET}"
    echo -e "${BOLD}${RED}   Xray 卸载步骤                     ${RESET}"
    echo -e "${BOLD}${RED}======================================${RESET}"
    echo
    echo -e "  ${CYAN}1${RESET}  停止服务并移除开机自启"
    echo -e "  ${CYAN}2${RESET}  删除 OpenRC 服务文件"
    echo -e "  ${CYAN}3${RESET}  删除二进制文件"
    echo -e "  ${CYAN}4${RESET}  删除配置目录（配置文件 / 状态文件）"
    echo -e "  ${CYAN}5${RESET}  删除日志文件"
    echo -e "  ${CYAN}all${RESET} 一次性执行全部卸载步骤"
    echo -e "  ${CYAN}b${RESET}  返回主菜单"
    echo -e "  ${CYAN}q${RESET}  退出"
    echo
}

run_install_step() {
    case "$1" in
        1)   step_install_1 ;;
        2)   step_install_2 ;;
        3)   step_install_3 ;;
        4)   step_install_4 ;;
        5)   step_install_5 ;;
        6)   step_install_6 ;;
        7)   step_install_7 ;;
        all)
            step_install_1
            step_install_2
            step_install_3
            step_install_4
            step_install_5
            step_install_6
            step_install_7
            ;;
        b|B) return 1 ;;
        q|Q|quit|exit) echo "退出。"; exit 0 ;;
        *) echo -e "${RED}无效选项：$1${RESET}" ;;
    esac
    return 0
}

run_remove_step() {
    case "$1" in
        1)   step_remove_1 ;;
        2)   step_remove_2 ;;
        3)   step_remove_3 ;;
        4)   step_remove_4 ;;
        5)   step_remove_5 ;;
        all)
            step_remove_1
            step_remove_2
            step_remove_3
            step_remove_4
            step_remove_5
            ;;
        b|B) return 1 ;;
        q|Q|quit|exit) echo "退出。"; exit 0 ;;
        *) echo -e "${RED}无效选项：$1${RESET}" ;;
    esac
    return 0
}

# ── 安装子菜单循环 ────────────────────────────────────────────
enter_install_mode() {
    show_install_menu
    while true; do
        read -rp "$(echo -e "${BOLD}安装步骤（1-7 / all / b / q）：${RESET}")" CHOICE
        case "$CHOICE" in
            b|B) return ;;
            q|Q|quit|exit) echo "退出。"; exit 0 ;;
            "") show_install_menu; continue ;;
        esac
        run_install_step "$CHOICE" || return
        echo
        read -rp "$(echo -e "${CYAN}按 Enter 返回安装菜单，或输入下一步骤号：${RESET}")" NEXT
        if [ -n "$NEXT" ]; then
            case "$NEXT" in
                b|B) return ;;
                q|Q|quit|exit) echo "退出。"; exit 0 ;;
            esac
            run_install_step "$NEXT" || return
        fi
    done
}

# ── 卸载子菜单循环 ────────────────────────────────────────────
enter_remove_mode() {
    show_remove_menu
    while true; do
        read -rp "$(echo -e "${BOLD}卸载步骤（1-5 / all / b / q）：${RESET}")" CHOICE
        case "$CHOICE" in
            b|B) return ;;
            q|Q|quit|exit) echo "退出。"; exit 0 ;;
            "") show_remove_menu; continue ;;
        esac
        run_remove_step "$CHOICE" || return
        echo
        read -rp "$(echo -e "${CYAN}按 Enter 返回卸载菜单，或输入下一步骤号：${RESET}")" NEXT
        if [ -n "$NEXT" ]; then
            case "$NEXT" in
                b|B) return ;;
                q|Q|quit|exit) echo "退出。"; exit 0 ;;
            esac
            run_remove_step "$NEXT" || return
        fi
    done
}

# ==============================================================
#  入口
# ==============================================================

check_root

# 支持通过环境变量传入端口（用于安装步骤 3）
CMD_PORT="${PORT:-}"

case "$1" in
    install)
        if [ -n "$2" ]; then
            run_install_step "$2"
        else
            enter_install_mode
        fi
        ;;
    remove|uninstall)
        if [ -n "$2" ]; then
            run_remove_step "$2"
        else
            enter_remove_mode
        fi
        ;;
    "")
        show_main_menu
        while true; do
            read -rp "$(echo -e "${BOLD}请选择操作（i 安装 / r 卸载 / q 退出）：${RESET}")" CHOICE
            case "$CHOICE" in
                i|I|install)   enter_install_mode; show_main_menu ;;
                r|R|remove)    enter_remove_mode;  show_main_menu ;;
                q|Q|quit|exit) echo "退出。"; exit 0 ;;
                "") show_main_menu ;;
                *) echo -e "${RED}无效选项，请输入 i / r / q${RESET}" ;;
            esac
        done
        ;;
    *)
        echo -e "${RED}未知参数：$1${RESET}"
        echo "用法：bash $0 [install|remove] [步骤号/all]"
        exit 1
        ;;
esac
