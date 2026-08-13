#!/bin/bash
# ==============================================================
#  AnyTLS 安装 / 卸载脚本（Alpine Linux，分步版）
#  仓库：anytls/anytls-go
#
#  重要说明：
#    官方 anytls-server 参考实现内置自签证书逻辑，命令行仅支持
#    以下参数（已通过实测 anytls-server -h 确认）：
#      -l  监听地址:端口（默认 0.0.0.0:8443）
#      -p  密码
#      -padding-scheme  填充策略（可选，一般不用改）
#    不支持 --cert/--key 外部证书参数，因此客户端必须开启
#    skip-cert-verify（跳过证书校验），这是协议本身的设计，
#    不是配置缺陷。
#
#  用法：
#    bash anytls-steps.sh              # 主菜单（选安装或卸载）
#    bash anytls-steps.sh install      # 直接进入安装菜单
#    bash anytls-steps.sh install <N>  # 直接执行安装步骤 N
#    bash anytls-steps.sh install all  # 一次性完整安装
#    bash anytls-steps.sh remove       # 直接进入卸载菜单
#    bash anytls-steps.sh remove <N>   # 直接执行卸载步骤 N
#    bash anytls-steps.sh remove all   # 一次性完整卸载
#
#  安装步骤：
#    1  安装系统依赖
#    2  下载并安装 AnyTLS 服务端二进制
#    3  生成端口 / 密码（写入状态文件）
#    4  创建 OpenRC 服务（读取状态文件）
#    5  启动并验证服务
#    6  输出客户端配置 & 分享链接
#
#  卸载步骤：
#    1  停止服务并移除开机自启
#    2  删除 OpenRC 服务文件
#    3  删除二进制文件
#    4  删除配置目录（状态文件）
#    5  删除日志文件
#
#  状态文件：/etc/anytls/.install_state
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
BIN_PATH="/usr/local/bin/anytls-server"

# ─── 保存 / 读取状态 ──────────────────────────────────────────
save_state() {
    mkdir -p /etc/anytls
    cat > "$STATE_FILE" << STEOF
PORT="${PORT}"
PASSWORD="${PASSWORD}"
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
    echo -e "\n${BOLD}[安装 1/6] 安装系统依赖${RESET}"
    [ -f /etc/alpine-release ] || warn "未检测到 Alpine Linux，继续执行..."
    apk update -q
    apk add -q curl unzip openssl bash
    success "依赖安装完成（curl unzip openssl bash）"
}

step_install_2() {
    echo -e "\n${BOLD}[安装 2/6] 下载并安装 AnyTLS 服务端${RESET}"

    info "获取 AnyTLS 最新版本..."
    VER_TAG=$(curl -fsSL -o /dev/null -w "%{url_effective}" \
        https://github.com/anytls/anytls-go/releases/latest \
        | sed 's|.*/tag/||')
    [ -n "$VER_TAG" ] || error "获取版本号失败，请检查网络"
    info "最新版本：${VER_TAG}"

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
    install -m 755 "$TMPDIR_DL/extract/anytls-server" "$BIN_PATH"
    rm -rf "$TMPDIR_DL"

    success "AnyTLS ${VER_TAG} 安装完成 → ${BIN_PATH}"
    info "参数列表（供参考）："
    "$BIN_PATH" -h 2>&1 | sed 's/^/    /' || true
}

step_install_3() {
    echo -e "\n${BOLD}[安装 3/6] 生成端口 / 密码${RESET}"

    load_state

    # ── 端口 ──
    if [ -n "$CMD_PORT" ]; then
        PORT="$CMD_PORT"
    elif [ -z "$PORT" ]; then
        read -rp "请输入监听端口号（默认 52443）: " PORT
        PORT="${PORT:-52443}"
    else
        info "沿用上次保存的端口：${PORT}"
    fi

    if ! echo "$PORT" | grep -qE '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        error "端口号无效：$PORT（需为 1-65535 的整数）"
    fi

    # ── 密码 ──
    info "生成连接密码..."
    PASSWORD=$(openssl rand -base64 18 | tr -d '=+/' | { head -c 24; cat > /dev/null; })
    [ -n "$PASSWORD" ] || error "密码生成失败"
    success "密码：${PASSWORD}"

    save_state
    success "参数已保存到 ${STATE_FILE}"
}

step_install_4() {
    echo -e "\n${BOLD}[安装 4/6] 创建 OpenRC 服务${RESET}"

    load_state
    [ -n "$PORT" ]     || error "缺少 PORT，请先执行安装步骤 3"
    [ -n "$PASSWORD" ] || error "缺少 PASSWORD，请先执行安装步骤 3"
    [ -f "$BIN_PATH" ] || error "二进制不存在，请先执行安装步骤 2"

    info "写入 /etc/init.d/anytls..."

    # 官方 anytls-server 只支持 -l / -p / -padding-scheme
    # 不支持外部证书参数，内部自动使用自签证书
    cat > /etc/init.d/anytls << INITEOF
#!/sbin/openrc-run

name="anytls"
description="AnyTLS Proxy Service"

command="${BIN_PATH}"
command_args="-l :${PORT} -p ${PASSWORD}"
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
    info "启动参数：-l :${PORT} -p ${PASSWORD}"
}

step_install_5() {
    echo -e "\n${BOLD}[安装 5/6] 启动并验证服务${RESET}"

    [ -f /etc/init.d/anytls ] || error "服务文件不存在，请先执行安装步骤 4"

    info "启动 AnyTLS 服务..."
    rc-service anytls restart > /dev/null 2>&1 \
        || rc-service anytls start > /dev/null 2>&1 \
        || true

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
        warn "未检测到 ${PORT} 端口监听，最近的错误日志："
        echo
        tail -n 20 /var/log/anytls-error.log 2>/dev/null || warn "日志文件不存在"
        echo
        error "服务未正常启动，请根据以上日志排查后重新执行本步骤"
    fi
}

step_install_6() {
    echo -e "\n${BOLD}[安装 6/6] 输出客户端配置${RESET}"

    load_state
    [ -n "$PASSWORD" ] || error "缺少配置参数，请先执行安装步骤 3"
    [ -n "$PORT" ]     || error "缺少 PORT，请先执行安装步骤 3"

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

    HY_PARAMS="allowInsecure=1"
    [ -n "$SERVER_IPV4" ] && LINK_V4="anytls://${PASSWORD}@${SERVER_IPV4}:${PORT}?${HY_PARAMS}#AnyTLS-v4"
    [ -n "$SERVER_IPV6" ] && LINK_V6="anytls://${PASSWORD}@[${SERVER_IPV6}]:${PORT}?${HY_PARAMS}#AnyTLS-v6"

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
    echo -e "  ${BOLD}证书${RESET}         : 服务端内置自签证书（无需手动配置）"
    echo -e "  ${BOLD}证书校验${RESET}     : 客户端必须开启 skip-cert-verify"
    echo
    echo -e "  ${BOLD}--- Nikki/Clash 节点格式 ---${RESET}"
    if [ -n "$SERVER_IPV4" ]; then
        echo -e "  ${CYAN}- {name: AnyTLS-节点, type: anytls, server: ${SERVER_IPV4}, port: ${PORT}, password: ${PASSWORD}, skip-cert-verify: true, client-fingerprint: chrome, udp: true}${RESET}"
    fi
    if [ -n "$LINK_V4" ] || [ -n "$LINK_V6" ]; then
        echo
        echo -e "  ${BOLD}--- 分享链接（可直接导入客户端）---${RESET}"
        [ -n "$LINK_V4" ] && echo -e "  ${BOLD}IPv4 链接${RESET} :\n  ${CYAN}${LINK_V4}${RESET}"
        [ -n "$LINK_V6" ] && echo -e "  ${BOLD}IPv6 链接${RESET} :\n  ${CYAN}${LINK_V6}${RESET}"
    fi
    echo
    echo -e "${BOLD}${YELLOW}注意：AnyTLS 基于 TCP，请确认防火墙/安全组已放行 TCP ${PORT} 端口${RESET}"
    echo -e "${BOLD}${YELLOW}注意：由于官方服务端不支持自定义证书，sni 字段可不填，${RESET}"
    echo -e "${BOLD}${YELLOW}      客户端只要开启 skip-cert-verify 即可正常连接${RESET}"
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
#  卸载步骤
# ==============================================================

step_remove_1() {
    echo -e "\n${BOLD}[卸载 1/5] 停止服务并移除开机自启${RESET}"

    if [ -f /etc/init.d/anytls ]; then
        info "停止 AnyTLS 服务..."
        rc-service anytls stop > /dev/null 2>&1 || true
        rc-update del anytls default > /dev/null 2>&1 || true
        success "服务已停止，开机自启已移除"
    else
        warn "未找到 OpenRC 服务文件，跳过"
    fi
}

step_remove_2() {
    echo -e "\n${BOLD}[卸载 2/5] 删除 OpenRC 服务文件${RESET}"

    if [ -f /etc/init.d/anytls ]; then
        rm -f /etc/init.d/anytls
        success "已删除 /etc/init.d/anytls"
    else
        warn "/etc/init.d/anytls 不存在，跳过"
    fi

    rm -f /run/anytls.pid
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
    echo -e "\n${BOLD}[卸载 4/5] 删除配置目录（状态文件）${RESET}"

    if [ -d /etc/anytls ]; then
        info "将删除以下内容："
        ls -la /etc/anytls/ 2>/dev/null || true
        echo
        read -rp "$(echo -e "${YELLOW}确认删除 /etc/anytls 目录？[y/N]：${RESET}")" CONFIRM
        case "$CONFIRM" in
            y|Y|yes|YES)
                rm -rf /etc/anytls
                success "已删除 /etc/anytls/"
                ;;
            *)
                warn "已跳过，目录保留"
                ;;
        esac
    else
        warn "/etc/anytls 目录不存在，跳过"
    fi
}

step_remove_5() {
    echo -e "\n${BOLD}[卸载 5/5] 删除日志文件${RESET}"

    REMOVED=0
    for f in /var/log/anytls-stdout.log /var/log/anytls-error.log; do
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
    echo -e "${BOLD}${GREEN}           AnyTLS 卸载完成                 ${RESET}"
    echo -e "${BOLD}${GREEN}============================================${RESET}"
    echo
}

# ==============================================================
#  菜单
# ==============================================================

show_main_menu() {
    echo
    echo -e "${BOLD}======================================${RESET}"
    echo -e "${BOLD}   AnyTLS 管理脚本                   ${RESET}"
    echo -e "${BOLD}   Alpine Linux 版本                 ${RESET}"
    echo -e "${BOLD}======================================${RESET}"
    echo
    echo -e "  ${GREEN}i${RESET}  安装 AnyTLS"
    echo -e "  ${RED}r${RESET}  卸载 AnyTLS"
    echo -e "  ${CYAN}q${RESET}  退出"
    echo
}

show_install_menu() {
    echo
    echo -e "${BOLD}${GREEN}======================================${RESET}"
    echo -e "${BOLD}${GREEN}   AnyTLS 安装步骤                   ${RESET}"
    echo -e "${BOLD}${GREEN}======================================${RESET}"
    echo
    echo -e "  ${CYAN}1${RESET}  安装系统依赖"
    echo -e "  ${CYAN}2${RESET}  下载并安装 AnyTLS 服务端二进制"
    echo -e "  ${CYAN}3${RESET}  生成端口 / 密码"
    echo -e "  ${CYAN}4${RESET}  创建 OpenRC 服务"
    echo -e "  ${CYAN}5${RESET}  启动并验证服务"
    echo -e "  ${CYAN}6${RESET}  输出客户端配置 & 分享链接"
    echo -e "  ${CYAN}all${RESET} 一次性执行全部安装步骤"
    echo -e "  ${CYAN}b${RESET}  返回主菜单"
    echo -e "  ${CYAN}q${RESET}  退出"
    echo
    echo -e "提示：执行步骤 3 时可通过环境变量指定端口，例如："
    echo -e "  ${YELLOW}PORT=52443 bash $0 install 3${RESET}"
    echo
}

show_remove_menu() {
    echo
    echo -e "${BOLD}${RED}======================================${RESET}"
    echo -e "${BOLD}${RED}   AnyTLS 卸载步骤                   ${RESET}"
    echo -e "${BOLD}${RED}======================================${RESET}"
    echo
    echo -e "  ${CYAN}1${RESET}  停止服务并移除开机自启"
    echo -e "  ${CYAN}2${RESET}  删除 OpenRC 服务文件"
    echo -e "  ${CYAN}3${RESET}  删除二进制文件"
    echo -e "  ${CYAN}4${RESET}  删除配置目录（状态文件）"
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
        all)
            step_install_1
            step_install_2
            step_install_3
            step_install_4
            step_install_5
            step_install_6
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
        read -rp "$(echo -e "${BOLD}安装步骤（1-6 / all / b / q）：${RESET}")" CHOICE
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
