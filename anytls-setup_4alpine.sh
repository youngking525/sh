#!/bin/bash
# ==============================================================
#  AnyTLS 分步安装脚本（Alpine Linux）
#  仓库：anytls/anytls-go
#
#  用法：
#    bash anytls-steps.sh          # 显示步骤菜单
#    bash anytls-steps.sh <步骤号>  # 直接执行某步
#    bash anytls-steps.sh all      # 一次性执行全部步骤
#
#  步骤列表：
#    1  安装系统依赖
#    2  下载并安装 AnyTLS 服务端二进制
#    3  生成端口 / 密码 / 自签证书（写入状态文件）
#    4  创建 OpenRC 服务（读取状态文件）
#    5  启动并验证服务
#    6  输出客户端配置 & 分享链接
#
#  注意：AnyTLS 服务端通过命令行参数启动，无独立配置文件。
#        所有参数保存在状态文件 /etc/anytls/.install_state 中。
#        更换端口/密码只需重新执行步骤 3 → 步骤 4 → 步骤 5 即可。
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
STATE_FILE="/etc/anytls/.install_state"
CERT_PATH="/etc/anytls/server.crt"
KEY_PATH="/etc/anytls/server.key"
BIN_PATH="/usr/local/bin/anytls-server"

# ─── 保存 / 读取状态 ──────────────────────────────────────────
save_state() {
    mkdir -p /etc/anytls
    cat > "$STATE_FILE" << STEOF
PORT="${PORT}"
PASSWORD="${PASSWORD}"
SNI="${SNI}"
CERT_PATH="${CERT_PATH}"
KEY_PATH="${KEY_PATH}"
STEOF
    chmod 600 "$STATE_FILE"
}

load_state() {
    [ -f "$STATE_FILE" ] && . "$STATE_FILE"
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
    apk add -q curl unzip openssl bash
    success "依赖安装完成（curl unzip openssl bash）"
}

step2_download_anytls() {
    echo -e "\n${BOLD}[步骤 2] 下载并安装 AnyTLS 服务端${RESET}"

    info "获取 AnyTLS 最新版本..."
    VER_TAG=$(curl -fsSL -o /dev/null -w "%{url_effective}" \
        https://github.com/anytls/anytls-go/releases/latest \
        | sed 's|.*/tag/||')
    [ -n "$VER_TAG" ] || error "获取版本号失败，请检查网络"
    info "最新版本：${VER_TAG}"

    # 去掉 v 前缀，文件名格式为 anytls_X.Y.Z_linux_amd64.zip
    VER_NUM="${VER_TAG#v}"

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  BIN_ARCH="amd64" ;;
        aarch64) BIN_ARCH="arm64" ;;
        *) error "不支持的架构：${ARCH}" ;;
    esac

    FILENAME="anytls_${VER_NUM}_linux_${BIN_ARCH}.zip"
    DOWNLOAD_URL="https://github.com/anytls/anytls-go/releases/download/${VER_TAG}/${FILENAME}"

    info "下载 ${FILENAME}..."
    TMPDIR_DL=$(mktemp -d)
    curl -fsSL "$DOWNLOAD_URL" -o "$TMPDIR_DL/$FILENAME" \
        || error "下载失败，请检查网络\n  URL: ${DOWNLOAD_URL}"

    info "解压..."
    unzip -q "$TMPDIR_DL/$FILENAME" -d "$TMPDIR_DL/extract"

    # zip 内二进制名为 anytls-server
    install -m 755 "$TMPDIR_DL/extract/anytls-server" "$BIN_PATH"
    rm -rf "$TMPDIR_DL"

    success "AnyTLS ${VER_TAG} 安装完成 → ${BIN_PATH}"
    info "版本信息："
    "$BIN_PATH" --version 2>/dev/null || "$BIN_PATH" -v 2>/dev/null || true
}

step3_gen_params() {
    echo -e "\n${BOLD}[步骤 3] 生成端口 / 密码 / 自签证书${RESET}"

    load_state

    # ── 端口 ──
    if [ -n "$CMD_PORT" ]; then
        PORT="$CMD_PORT"
    elif [ -z "$PORT" ]; then
        read -rp "请输入监听端口号（默认 38443）: " PORT
        PORT="${PORT:-38443}"
    else
        info "沿用上次保存的端口：${PORT}"
    fi

    if ! echo "$PORT" | grep -qE '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        error "端口号无效：$PORT（需为 1-65535 的整数）"
    fi

    # ── SNI（证书 CN，仅影响伪装，skip-cert-verify 时客户端不做校验）──
    if [ -z "$SNI" ]; then
        SNI="www.zhihu.com"
    fi
    info "证书 CN / SNI：${SNI}"

    # ── 密码 ──
    info "生成连接密码..."
    PASSWORD=$(openssl rand -base64 18 | tr -d '=+/' | head -c 24)
    [ -n "$PASSWORD" ] || error "密码生成失败"
    success "密码：${PASSWORD}"

    # ── 自签证书（ECC P-256）──
    mkdir -p /etc/anytls
    info "生成自签 TLS 证书（CN=${SNI}）..."
    openssl ecparam -genkey -name prime256v1 -out "$KEY_PATH" 2>/dev/null
    openssl req -new -x509 -days 36500 \
        -key "$KEY_PATH" -out "$CERT_PATH" \
        -subj "/CN=${SNI}" 2>/dev/null \
        || error "证书生成失败"

    chmod 600 "$KEY_PATH"
    chmod 644 "$CERT_PATH"
    success "证书生成完成"
    success "  → ${CERT_PATH}"
    success "  → ${KEY_PATH}"

    save_state
    success "参数已保存到 ${STATE_FILE}"
}

step4_setup_service() {
    echo -e "\n${BOLD}[步骤 4] 创建 OpenRC 服务${RESET}"

    load_state
    [ -n "$PORT" ]     || error "缺少 PORT，请先执行步骤 3"
    [ -n "$PASSWORD" ] || error "缺少 PASSWORD，请先执行步骤 3"
    [ -f "$CERT_PATH" ] || error "证书文件不存在，请先执行步骤 3"
    [ -f "$BIN_PATH" ]  || error "二进制不存在，请先执行步骤 2"

    info "写入 /etc/init.d/anytls..."

    # OpenRC 服务文件中直接展开变量，command_args 静态写死当前参数
    cat > /etc/init.d/anytls << INITEOF
#!/sbin/openrc-run

name="anytls"
description="AnyTLS Proxy Service"

command="${BIN_PATH}"
command_args="-l :${PORT} -p ${PASSWORD} --cert ${CERT_PATH} --key ${KEY_PATH}"
command_background=true
pidfile="/run/anytls.pid"

output_log="/var/log/anytls-stdout.log"
error_log="/var/log/anytls-error.log"

depend() {
    need net
    after firewall
}
INITEOF

    chmod +x /etc/init.d/anytls
    success "OpenRC 服务文件写入完成"
    info "启动参数：-l :${PORT} -p ${PASSWORD} --cert ${CERT_PATH} --key ${KEY_PATH}"
}

step5_start_service() {
    echo -e "\n${BOLD}[步骤 5] 启动并验证服务${RESET}"

    [ -f /etc/init.d/anytls ] || error "服务文件不存在，请先执行步骤 4"

    info "启动 AnyTLS 服务..."
    rc-service anytls restart > /dev/null 2>&1 \
        || rc-service anytls start > /dev/null 2>&1 \
        || error "AnyTLS 启动失败，查看日志：tail -f /var/log/anytls-error.log"

    rc-update add anytls default > /dev/null 2>&1
    success "AnyTLS 已设为开机自启"

    info "等待 2 秒后检查进程..."
    sleep 2

    info "当前服务状态："
    rc-service anytls status || true

    load_state
    if ss -tlnp 2>/dev/null | grep -q ":${PORT}"; then
        success "TCP ${PORT} 端口已在监听，服务启动成功"
    else
        warn "未检测到 ${PORT} 端口监听，请查看日志排查："
        warn "  tail -f /var/log/anytls-error.log"
    fi
}

step6_show_info() {
    echo -e "\n${BOLD}[步骤 6] 输出客户端配置${RESET}"

    load_state
    [ -n "$PASSWORD" ] || error "缺少配置参数，请先执行步骤 3"
    [ -n "$PORT" ]     || error "缺少 PORT，请先执行步骤 3"
    [ -n "$SNI" ]      || error "缺少 SNI，请先执行步骤 3"

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

    # 分享链接格式：anytls://password@host:port?allowInsecure=1&sni=xxx
    HY_PARAMS="allowInsecure=1&sni=${SNI}"

    [ -n "$SERVER_IPV4" ] && \
        LINK_V4="anytls://${PASSWORD}@${SERVER_IPV4}:${PORT}?${HY_PARAMS}#AnyTLS-v4"
    [ -n "$SERVER_IPV6" ] && \
        LINK_V6="anytls://${PASSWORD}@[${SERVER_IPV6}]:${PORT}?${HY_PARAMS}#AnyTLS-v6"

    echo
    echo -e "${BOLD}${GREEN}============================================${RESET}"
    echo -e "${BOLD}${GREEN}        安装完成！客户端配置如下           ${RESET}"
    echo -e "${BOLD}${GREEN}============================================${RESET}"
    echo
    echo -e "  ${BOLD}--- 基本信息 ---${RESET}"
    if [ -n "$SERVER_IPV4" ]; then
        echo -e "  ${BOLD}IPv4 地址${RESET}    : ${YELLOW}${SERVER_IPV4}${RESET}"
    else
        echo -e "  ${BOLD}IPv4 地址${RESET}    : ${RED}未检测到${RESET}"
    fi
    if [ -n "$SERVER_IPV6" ]; then
        echo -e "  ${BOLD}IPv6 地址${RESET}    : ${YELLOW}${SERVER_IPV6}${RESET}"
    else
        echo -e "  ${BOLD}IPv6 地址${RESET}    : ${RED}未检测到${RESET}"
    fi
    echo -e "  ${BOLD}端口（TCP）${RESET}  : ${YELLOW}${PORT}${RESET}"
    echo -e "  ${BOLD}协议${RESET}         : AnyTLS"
    echo -e "  ${BOLD}密码${RESET}         : ${YELLOW}${PASSWORD}${RESET}"
    echo -e "  ${BOLD}SNI${RESET}          : ${SNI}"
    echo -e "  ${BOLD}证书校验${RESET}     : 跳过（自签证书，客户端需开启 allowInsecure/skip-cert-verify）"

    echo
    echo -e "  ${BOLD}--- Nikki/Clash 节点格式 ---${RESET}"
    if [ -n "$SERVER_IPV4" ]; then
        echo -e "  ${CYAN}- {name: AnyTLS-节点, type: anytls, server: ${SERVER_IPV4}, port: ${PORT}, password: ${PASSWORD}, sni: ${SNI}, skip-cert-verify: true}${RESET}"
    fi

    if [ -n "$LINK_V4" ] || [ -n "$LINK_V6" ]; then
        echo
        echo -e "  ${BOLD}--- 分享链接（可直接导入客户端）---${RESET}"
        [ -n "$LINK_V4" ] && echo -e "  ${BOLD}IPv4 链接${RESET} :\n  ${CYAN}${LINK_V4}${RESET}"
        [ -n "$LINK_V6" ] && echo -e "  ${BOLD}IPv6 链接${RESET} :\n  ${CYAN}${LINK_V6}${RESET}"
    fi

    echo
    echo -e "${BOLD}${YELLOW}注意：AnyTLS 基于 TCP，请确认防火墙/安全组已放行 TCP ${PORT} 端口${RESET}"
    echo
    echo -e "${BOLD}${GREEN}============================================${RESET}"
    echo
    echo -e "查看日志：${CYAN}tail -f /var/log/anytls-error.log${RESET}"
    echo -e "重启服务：${CYAN}rc-service anytls restart${RESET}"
    echo -e "停止服务：${CYAN}rc-service anytls stop${RESET}"
    echo -e "查看状态：${CYAN}rc-service anytls status${RESET}"
    echo
}

# ==============================================================
#  菜单
# ==============================================================

show_menu() {
    echo
    echo -e "${BOLD}======================================${RESET}"
    echo -e "${BOLD}   AnyTLS 分步安装器                 ${RESET}"
    echo -e "${BOLD}   Alpine Linux 版本                 ${RESET}"
    echo -e "${BOLD}======================================${RESET}"
    echo
    echo -e "  ${CYAN}1${RESET}  安装系统依赖"
    echo -e "  ${CYAN}2${RESET}  下载并安装 AnyTLS 服务端二进制"
    echo -e "  ${CYAN}3${RESET}  生成端口 / 密码 / 自签证书"
    echo -e "  ${CYAN}4${RESET}  创建 OpenRC 服务"
    echo -e "  ${CYAN}5${RESET}  启动并验证服务"
    echo -e "  ${CYAN}6${RESET}  输出客户端配置 & 分享链接"
    echo -e "  ${CYAN}all${RESET} 一次性执行全部步骤"
    echo -e "  ${CYAN}q${RESET}  退出"
    echo
    echo -e "提示：执行步骤 3 时可通过环境变量指定端口，例如："
    echo -e "  ${YELLOW}PORT=38443 bash $0 3${RESET}"
    echo
}

run_step() {
    case "$1" in
        1)   step1_install_deps    ;;
        2)   step2_download_anytls ;;
        3)   step3_gen_params      ;;
        4)   step4_setup_service   ;;
        5)   step5_start_service   ;;
        6)   step6_show_info       ;;
        all)
            step1_install_deps
            step2_download_anytls
            step3_gen_params
            step4_setup_service
            step5_start_service
            step6_show_info
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
    run_step "$1"
else
    show_menu
    while true; do
        read -rp "$(echo -e "${BOLD}请输入步骤编号（1-6 / all / q）：${RESET}")" CHOICE
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
