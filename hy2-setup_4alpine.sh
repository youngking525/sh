#!/bin/bash
# ==============================================================
#  Hysteria2 安装 / 卸载脚本（Alpine Linux，分步版）
#
#  用法：
#    bash hysteria2-steps.sh              # 主菜单（选安装或卸载）
#    bash hysteria2-steps.sh install      # 直接进入安装菜单
#    bash hysteria2-steps.sh install <N>  # 直接执行安装步骤 N
#    bash hysteria2-steps.sh install all  # 一次性完整安装
#    bash hysteria2-steps.sh remove       # 直接进入卸载菜单
#    bash hysteria2-steps.sh remove <N>   # 直接执行卸载步骤 N
#    bash hysteria2-steps.sh remove all   # 一次性完整卸载
#
#  安装步骤：
#    1  安装系统依赖
#    2  下载并安装 Hysteria2 二进制
#    3  生成端口 / 密码 / 自签证书（写入状态文件）
#    4  写入 Hysteria2 配置文件（读取状态文件）
#    5  验证配置文件
#    6  创建并启动 OpenRC 服务
#    7  输出客户端配置 & 分享链接
#
#  卸载步骤：
#    1  停止服务并移除开机自启
#    2  删除 OpenRC 服务文件
#    3  删除二进制文件
#    4  删除配置目录（配置文件 / 证书 / 状态文件）
#    5  删除日志文件
#
#  状态文件：/etc/hysteria/.install_state
#  说明：Hysteria2 基于 QUIC（UDP），默认使用自签证书 + 客户端
#        insecure 跳过校验的方式（不依赖真实域名）。
#        如需更换端口/密码，修改后从安装步骤 3 重新执行即可。
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
STATE_FILE="/etc/hysteria/.install_state"
BIN_PATH="/usr/local/bin/hysteria"

# ─── 保存 / 读取状态 ──────────────────────────────────────────
save_state() {
    mkdir -p /etc/hysteria
    cat > "$STATE_FILE" << STEOF
PORT="${PORT}"
PASSWORD="${PASSWORD}"
MASQ_DOMAIN="${MASQ_DOMAIN}"
CERT_PATH="${CERT_PATH}"
KEY_PATH="${KEY_PATH}"
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
    apk add -q curl openssl bash
    success "依赖安装完成（curl openssl bash）"
}

step_install_2() {
    echo -e "\n${BOLD}[安装 2/7] 下载并安装 Hysteria2${RESET}"

    info "获取 Hysteria2 最新版本..."
    HY_VER_TAG=$(curl -fsSL -o /dev/null -w "%{url_effective}" \
        https://github.com/apernet/hysteria/releases/latest \
        | sed 's|.*/tag/||')
    [ -n "$HY_VER_TAG" ] || error "获取 Hysteria2 版本失败，请检查网络"
    info "最新版本：${HY_VER_TAG}"

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  BIN_ARCH="amd64" ;;
        aarch64) BIN_ARCH="arm64" ;;
        armv7l)  BIN_ARCH="arm" ;;
        *) error "不支持的架构：${ARCH}" ;;
    esac

    BIN_NAME="hysteria-linux-${BIN_ARCH}"
    DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/${HY_VER_TAG}/${BIN_NAME}"

    info "下载 ${BIN_NAME}..."
    curl -fsSL "$DOWNLOAD_URL" -o "$BIN_PATH" \
        || error "下载失败，请检查网络"

    chmod +x "$BIN_PATH"
    success "Hysteria2 ${HY_VER_TAG} 安装完成 → ${BIN_PATH}"

    info "版本信息："
    "$BIN_PATH" version || true
}

step_install_3() {
    echo -e "\n${BOLD}[安装 3/7] 生成端口 / 密码 / 自签证书${RESET}"

    load_state

    # ── 端口 ──
    if [ -n "$CMD_PORT" ]; then
        PORT="$CMD_PORT"
    elif [ -z "$PORT" ]; then
        read -rp "请输入监听端口号（默认 28443）: " PORT
        PORT="${PORT:-28443}"
    else
        info "沿用上次保存的端口：${PORT}"
    fi

    if ! echo "$PORT" | grep -qE '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        error "端口号无效：$PORT（需为 1-65535 的整数）"
    fi

    # ── 伪装域名（用于自签证书 CN 及 masquerade，仅占位，不需要真实可达）──
    if [ -z "$MASQ_DOMAIN" ]; then
        MASQ_DOMAIN="www.zhihu.com"
    fi
    info "伪装/证书域名：${MASQ_DOMAIN}（可在安装步骤4前修改状态文件自定义）"

    # ── 密码 ──
    info "生成连接密码..."
    PASSWORD=$(openssl rand -base64 16 | tr -d '=+/' | { head -c 24; cat > /dev/null; })
    [ -n "$PASSWORD" ] || error "密码生成失败"
    success "密码：${PASSWORD}"

    # ── 自签证书 ──
    mkdir -p /etc/hysteria
    CERT_PATH="/etc/hysteria/server.crt"
    KEY_PATH="/etc/hysteria/server.key"

    info "生成自签 TLS 证书（CN=${MASQ_DOMAIN}）..."
    openssl ecparam -genkey -name prime256v1 -out "$KEY_PATH" 2>/dev/null
    openssl req -new -x509 -days 36500 \
        -key "$KEY_PATH" -out "$CERT_PATH" \
        -subj "/CN=${MASQ_DOMAIN}" 2>/dev/null \
        || error "证书生成失败"

    chmod 600 "$KEY_PATH"
    chmod 644 "$CERT_PATH"
    success "证书生成完成 → ${CERT_PATH} / ${KEY_PATH}"

    save_state
    success "参数已保存到 ${STATE_FILE}"
}

step_install_4() {
    echo -e "\n${BOLD}[安装 4/7] 写入 Hysteria2 配置文件${RESET}"

    load_state
    [ -n "$PORT" ]      || error "缺少 PORT，请先执行安装步骤 3"
    [ -n "$PASSWORD" ]  || error "缺少 PASSWORD，请先执行安装步骤 3"
    [ -n "$CERT_PATH" ] || error "缺少证书路径，请先执行安装步骤 3"
    [ -f "$CERT_PATH" ] || error "证书文件不存在，请先执行安装步骤 3"

    mkdir -p /etc/hysteria

    cat > /etc/hysteria/config.yaml << EOF
listen: :${PORT}

tls:
  cert: ${CERT_PATH}
  key: ${KEY_PATH}

auth:
  type: password
  password: ${PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://${MASQ_DOMAIN}
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
EOF

    success "配置文件已写入 /etc/hysteria/config.yaml"
}

step_install_5() {
    echo -e "\n${BOLD}[安装 5/7] 验证配置文件${RESET}"

    command -v hysteria > /dev/null 2>&1 || error "未找到 hysteria，请先执行安装步骤 2"
    [ -f /etc/hysteria/config.yaml ]     || error "配置文件不存在，请先执行安装步骤 4"

    info "检查 YAML 语法与基础字段..."
    hysteria version > /dev/null 2>&1 || error "hysteria 二进制无法执行"

    for field in "listen:" "tls:" "auth:" "password:"; do
        grep -q "$field" /etc/hysteria/config.yaml \
            || error "配置文件缺少必要字段：${field}，请检查安装步骤 4"
    done

    success "配置文件基础检查通过"
    info "（Hysteria2 的完整校验会在启动服务时进行，见安装步骤 6）"
}

step_install_6() {
    echo -e "\n${BOLD}[安装 6/7] 创建并启动 OpenRC 服务${RESET}"

    [ -f /etc/hysteria/config.yaml ] || error "配置文件不存在，请先执行安装步骤 4"

    info "写入 /etc/init.d/hysteria..."
    cat > /etc/init.d/hysteria << INITEOF
#!/sbin/openrc-run

name="hysteria"
description="Hysteria2 Proxy Service"

command="${BIN_PATH}"
command_args="server -c /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/hysteria.pid"

output_log="/var/log/hysteria-stdout.log"
error_log="/var/log/hysteria-error.log"

depend() {
    need net
    after firewall
}
INITEOF

    chmod +x /etc/init.d/hysteria
    success "OpenRC 服务文件写入完成"

    info "启动 Hysteria2 服务..."
    rc-service hysteria restart > /dev/null 2>&1 \
        || rc-service hysteria start > /dev/null 2>&1 \
        || true

    rc-update add hysteria default > /dev/null 2>&1
    success "Hysteria2 已设为开机自启"

    info "等待 2 秒后检查进程状态..."
    sleep 2
    info "当前服务状态："
    rc-service hysteria status || true

    if ! pgrep -f "hysteria server" > /dev/null 2>&1; then
        echo
        warn "进程未检测到，最近的错误日志："
        tail -n 20 /var/log/hysteria-error.log 2>/dev/null || warn "日志文件不存在"
        echo
        error "服务未正常启动，请根据以上日志排查后重新执行本步骤"
    fi
}

step_install_7() {
    echo -e "\n${BOLD}[安装 7/7] 输出客户端配置${RESET}"

    load_state
    [ -n "$PASSWORD" ]    || error "缺少配置参数，请先执行安装步骤 3"
    [ -n "$PORT" ]        || error "缺少 PORT，请先执行安装步骤 3"
    [ -n "$MASQ_DOMAIN" ] || error "缺少伪装域名，请先执行安装步骤 3"

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

    HY_PARAMS="insecure=1&sni=${MASQ_DOMAIN}"

    [ -n "$SERVER_IPV4" ] && HY_LINK_V4="hysteria2://${PASSWORD}@${SERVER_IPV4}:${PORT}/?${HY_PARAMS}#Hysteria2-v4"
    [ -n "$SERVER_IPV6" ] && HY_LINK_V6="hysteria2://${PASSWORD}@[${SERVER_IPV6}]:${PORT}/?${HY_PARAMS}#Hysteria2-v6"

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
    echo -e "  ${BOLD}端口（UDP）${RESET}  : ${YELLOW}${PORT}${RESET}"
    echo -e "  ${BOLD}协议${RESET}        : Hysteria2"
    echo -e "  ${BOLD}密码${RESET}        : ${YELLOW}${PASSWORD}${RESET}"
    echo -e "  ${BOLD}SNI${RESET}         : ${MASQ_DOMAIN}"
    echo -e "  ${BOLD}证书校验${RESET}    : 跳过校验（自签证书，客户端需设置 insecure/skip-cert-verify=true）"

    echo
    echo -e "  ${BOLD}--- Nikki/Clash 节点格式 ---${RESET}"
    if [ -n "$SERVER_IPV4" ]; then
        echo -e "  ${CYAN}- {name: HY2-节点, type: hysteria2, server: ${SERVER_IPV4}, port: ${PORT}, password: ${PASSWORD}, sni: ${MASQ_DOMAIN}, skip-cert-verify: true, alpn: [h3]}${RESET}"
    fi

    if [ -n "$HY_LINK_V4" ] || [ -n "$HY_LINK_V6" ]; then
        echo
        echo -e "  ${BOLD}--- 分享链接（可直接导入客户端）---${RESET}"
        [ -n "$HY_LINK_V4" ] && echo -e "  ${BOLD}IPv4 链接${RESET} :\n  ${CYAN}${HY_LINK_V4}${RESET}"
        [ -n "$HY_LINK_V6" ] && echo -e "  ${BOLD}IPv6 链接${RESET} :\n  ${CYAN}${HY_LINK_V6}${RESET}"
    fi

    echo
    echo -e "${BOLD}${YELLOW}注意：Hysteria2 基于 UDP/QUIC，请确认防火墙/安全组已放行 UDP ${PORT} 端口${RESET}"
    echo
    echo -e "${BOLD}${GREEN}============================================${RESET}"
    echo
    echo -e "查看日志：${CYAN}tail -f /var/log/hysteria-error.log${RESET}"
    echo -e "重启服务：${CYAN}rc-service hysteria restart${RESET}"
    echo -e "停止服务：${CYAN}rc-service hysteria stop${RESET}"
    echo -e "查看状态：${CYAN}rc-service hysteria status${RESET}"
    echo
}

# ==============================================================
#  卸载步骤
# ==============================================================

step_remove_1() {
    echo -e "\n${BOLD}[卸载 1/5] 停止服务并移除开机自启${RESET}"

    if [ -f /etc/init.d/hysteria ]; then
        info "停止 Hysteria2 服务..."
        rc-service hysteria stop > /dev/null 2>&1 || true
        rc-update del hysteria default > /dev/null 2>&1 || true
        success "服务已停止，开机自启已移除"
    else
        warn "未找到 OpenRC 服务文件，跳过"
    fi
}

step_remove_2() {
    echo -e "\n${BOLD}[卸载 2/5] 删除 OpenRC 服务文件${RESET}"

    if [ -f /etc/init.d/hysteria ]; then
        rm -f /etc/init.d/hysteria
        success "已删除 /etc/init.d/hysteria"
    else
        warn "/etc/init.d/hysteria 不存在，跳过"
    fi

    rm -f /run/hysteria.pid
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
    echo -e "\n${BOLD}[卸载 4/5] 删除配置目录（配置文件 / 证书 / 状态文件）${RESET}"

    if [ -d /etc/hysteria ]; then
        info "将删除以下内容："
        ls -la /etc/hysteria/ 2>/dev/null || true
        echo
        read -rp "$(echo -e "${YELLOW}确认删除 /etc/hysteria 目录？[y/N]：${RESET}")" CONFIRM
        case "$CONFIRM" in
            y|Y|yes|YES)
                rm -rf /etc/hysteria
                success "已删除 /etc/hysteria/"
                ;;
            *)
                warn "已跳过，目录保留"
                ;;
        esac
    else
        warn "/etc/hysteria 目录不存在，跳过"
    fi
}

step_remove_5() {
    echo -e "\n${BOLD}[卸载 5/5] 删除日志文件${RESET}"

    REMOVED=0
    for f in /var/log/hysteria-stdout.log /var/log/hysteria-error.log; do
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
    echo -e "${BOLD}${GREEN}           Hysteria2 卸载完成               ${RESET}"
    echo -e "${BOLD}${GREEN}============================================${RESET}"
    echo
}

# ==============================================================
#  菜单
# ==============================================================

show_main_menu() {
    echo
    echo -e "${BOLD}======================================${RESET}"
    echo -e "${BOLD}   Hysteria2 管理脚本                ${RESET}"
    echo -e "${BOLD}   Alpine Linux 版本                 ${RESET}"
    echo -e "${BOLD}======================================${RESET}"
    echo
    echo -e "  ${GREEN}i${RESET}  安装 Hysteria2"
    echo -e "  ${RED}r${RESET}  卸载 Hysteria2"
    echo -e "  ${CYAN}q${RESET}  退出"
    echo
}

show_install_menu() {
    echo
    echo -e "${BOLD}${GREEN}======================================${RESET}"
    echo -e "${BOLD}${GREEN}   Hysteria2 安装步骤                ${RESET}"
    echo -e "${BOLD}${GREEN}======================================${RESET}"
    echo
    echo -e "  ${CYAN}1${RESET}  安装系统依赖"
    echo -e "  ${CYAN}2${RESET}  下载并安装 Hysteria2 二进制"
    echo -e "  ${CYAN}3${RESET}  生成端口 / 密码 / 自签证书"
    echo -e "  ${CYAN}4${RESET}  写入 Hysteria2 配置文件"
    echo -e "  ${CYAN}5${RESET}  验证配置文件"
    echo -e "  ${CYAN}6${RESET}  创建并启动 OpenRC 服务"
    echo -e "  ${CYAN}7${RESET}  输出客户端配置 & 分享链接"
    echo -e "  ${CYAN}all${RESET} 一次性执行全部安装步骤"
    echo -e "  ${CYAN}b${RESET}  返回主菜单"
    echo -e "  ${CYAN}q${RESET}  退出"
    echo
    echo -e "提示：执行步骤 3 时可通过环境变量指定端口，例如："
    echo -e "  ${YELLOW}PORT=28443 bash $0 install 3${RESET}"
    echo
}

show_remove_menu() {
    echo
    echo -e "${BOLD}${RED}======================================${RESET}"
    echo -e "${BOLD}${RED}   Hysteria2 卸载步骤                ${RESET}"
    echo -e "${BOLD}${RED}======================================${RESET}"
    echo
    echo -e "  ${CYAN}1${RESET}  停止服务并移除开机自启"
    echo -e "  ${CYAN}2${RESET}  删除 OpenRC 服务文件"
    echo -e "  ${CYAN}3${RESET}  删除二进制文件"
    echo -e "  ${CYAN}4${RESET}  删除配置目录（配置文件 / 证书 / 状态文件）"
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
