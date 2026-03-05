#!/bin/bash
# =============================================================================
# server-init.sh — 服务器一键初始化脚本（轻量化版 v2）
# 项目: manus-deploy
# 用法: curl -fsSL https://raw.githubusercontent.com/Alexlyu365/manus/main/server-init.sh -o /tmp/init.sh && sudo bash /tmp/init.sh
# 适用: Ubuntu 20.04/22.04/24.04, Debian 11/12 (Bookworm)
# Google Cloud: 默认系统 Debian 12 完整支持（e2-micro 1GB 内存优化）
#
# 轻量化修订 v2:
#   - 移除 MySQL 和 Portainer 默认安装（改为按需部署，节省 ~500MB 内存）
#   - 新增 1GB Swap 配置（防止 OOM 崩溃）
#   - NPM 内存限制降至 150M
#   - 精简步骤从 13 步到 10 步
# =============================================================================

set -euo pipefail

# ── 加载函数库（支持本地和远程两种方式）─────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_BASE="https://raw.githubusercontent.com/Alexlyu365/manus/main"

load_lib() {
    local lib_name="$1"
    local local_path="${SCRIPT_DIR}/lib/${lib_name}"
    local remote_url="${REMOTE_BASE}/lib/${lib_name}"

    if [ -f "$local_path" ]; then
        source "$local_path"
    else
        local tmp_file
        tmp_file=$(mktemp /tmp/manus-lib-XXXXXX.sh)
        if ! curl -fsSL "$remote_url" -o "$tmp_file"; then
            echo "[ERROR] 无法下载函数库: $lib_name" >&2
            rm -f "$tmp_file"
            exit 1
        fi
        source "$tmp_file"
        rm -f "$tmp_file"
    fi
}

load_lib "common.sh"
load_lib "docker.sh"
load_lib "firewall.sh"
load_lib "backup.sh"

# ── GitHub Token 配置（从私有配置文件注入，不写入公开仓库）────────────────────
setup_github_token() {
    local token_file="/opt/manus/.github_token"

    local GITHUB_TOKEN="${MANUS_GITHUB_TOKEN:-}"
    local GITHUB_USER="${MANUS_GITHUB_USER:-Alexlyu365}"

    if [ -z "$GITHUB_TOKEN" ] && [ -f "/root/.manus-private.conf" ]; then
        source /root/.manus-private.conf 2>/dev/null
        GITHUB_TOKEN="${MANUS_GITHUB_TOKEN:-}"
        GITHUB_USER="${MANUS_GITHUB_USER:-Alexlyu365}"
    fi

    if [ -z "$GITHUB_TOKEN" ]; then
        log_info "未配置 GitHub Token，跳过。如需部署私有仓库，运行: manus github-token"
        return 0
    fi

    log_step "配置 GitHub 私有仓库访问 Token..."
    echo "$GITHUB_TOKEN" > "$token_file"
    chmod 600 "$token_file"
    git config --global credential.helper store 2>/dev/null
    echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com" > /root/.git-credentials
    chmod 600 /root/.git-credentials
    log_success "GitHub Token 已自动配置，可直接部署公开和私有仓库"
}

# ── SSH 密钥前置检查 ──────────────────────────────────────────────────────────
check_ssh_key() {
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║              重要安全提示 — 请先阅读再继续                    ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}本脚本将禁用 SSH 密码登录，仅允许 SSH 密钥认证。${NC}"
    echo -e "${CYAN}Google Cloud 用户：浏览器 SSH 不受影响，可直接输入 y 继续。${NC}"
    echo ""

    local auth_keys_count=0
    if [ -f /root/.ssh/authorized_keys ]; then
        auth_keys_count=$(grep -c "^ssh-" /root/.ssh/authorized_keys 2>/dev/null || echo 0)
    fi
    for user_home in /home/*/; do
        if [ -f "${user_home}.ssh/authorized_keys" ]; then
            local count
            count=$(grep -c "^ssh-" "${user_home}.ssh/authorized_keys" 2>/dev/null || echo 0)
            auth_keys_count=$((auth_keys_count + count))
        fi
    done

    if [ "$auth_keys_count" -gt 0 ]; then
        echo -e "${GREEN}  已检测到 ${auth_keys_count} 个 SSH 授权密钥，密钥认证已配置。${NC}"
        echo ""
    else
        echo -e "${YELLOW}  未检测到 SSH 授权密钥。${NC}"
        echo -e "${YELLOW}  Google Cloud 浏览器 SSH 用户可安全继续。${NC}"
        echo ""
        if ! confirm "确认继续？"; then
            echo "已取消。"
            exit 0
        fi
    fi
}

# ── 主初始化流程 ─────────────────────────────────────────────────────────────
main() {
    clear
    print_banner

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" = "debian" ]; then
            echo -e "${CYAN}检测到 Debian ${VERSION_ID} (${VERSION_CODENAME:-})${NC}"
            echo ""
        fi
    fi

    echo -e "${WHITE}本脚本将在您的服务器上完成以下操作：${NC}"
    echo ""
    echo "  1.  配置 1GB Swap 虚拟内存（防止 OOM 崩溃）"
    echo "  2.  更新系统软件包"
    echo "  3.  安装基础工具（curl、git、vim 等）"
    echo "  4.  安装 Docker Engine"
    echo "  5.  优化系统内核参数"
    echo "  6.  配置 UFW 防火墙（修复 Docker 绕过问题）"
    echo "  7.  加固 SSH 安全（禁用密码登录）"
    echo "  8.  安装 Fail2ban（防暴力破解）"
    echo "  9.  部署 Nginx Proxy Manager（端口 81）"
    echo "  10. 安装 manus 管理工具"
    echo ""
    echo -e "${CYAN}  注：MySQL 和 Portainer 为按需安装，不占用初始内存${NC}"
    echo -e "${CYAN}      需要时执行 'manus install-mysql' 或 'manus install-portainer'${NC}"
    echo ""
    print_line

    check_root
    check_ssh_key

    if ! confirm "确认开始初始化服务器？"; then
        echo "已取消"
        exit 0
    fi

    echo ""
    log_info "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "服务器 IP: $(get_public_ip)"
    echo ""

    # ── Step 1: 检测操作系统 ─────────────────────────────────────────────────
    detect_os

    # ── Step 2: 配置 Swap（第一步，防止后续安装 OOM）────────────────────────
    log_step "[1/10] 配置 Swap 虚拟内存..."
    setup_swap "1G"

    # ── Step 3: 更新系统 ─────────────────────────────────────────────────────
    log_step "[2/10] 更新系统软件包..."
    $PKG_UPDATE
    if [ "$PKG_MANAGER" = "apt-get" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    fi
    log_success "系统更新完成"

    # ── Step 4: 安装基础工具 ─────────────────────────────────────────────────
    log_step "[3/10] 安装基础工具..."
    install_base_packages

    # ── Step 5: 安装 Docker ──────────────────────────────────────────────────
    log_step "[4/10] 安装 Docker..."
    install_docker
    configure_docker_daemon

    # ── Step 6: 优化系统参数 ─────────────────────────────────────────────────
    log_step "[5/10] 优化系统参数..."
    configure_sysctl
    configure_limits

    # ── Step 7: 配置防火墙 ───────────────────────────────────────────────────
    log_step "[6/10] 配置防火墙（修复 Docker UFW 绕过）..."
    setup_firewall

    # ── Step 8: 加固 SSH ─────────────────────────────────────────────────────
    log_step "[7/10] 加固 SSH 安全配置..."
    harden_ssh

    # ── Step 9: 安装 Fail2ban ────────────────────────────────────────────────
    log_step "[8/10] 安装 Fail2ban（防暴力破解）..."
    setup_fail2ban

    # ── Step 10: 创建目录结构 ────────────────────────────────────────────────
    log_step "[9/10] 创建目录结构..."
    mkdir -p /opt/manus/{lib,scripts,backups}
    mkdir -p /opt/sites
    touch /opt/manus/sites.conf
    chmod 700 /opt/manus
    chmod 755 /opt/sites
    log_success "目录结构创建完成"

    # GitHub Token 自动配置
    setup_github_token

    # ── Step 11: 部署 NPM ────────────────────────────────────────────────────
    log_step "[10/10] 部署 Nginx Proxy Manager..."
    deploy_nginx_proxy_manager

    # ── Step 12: 安装 manus 管理工具 ─────────────────────────────────────────
    install_manus_cli

    # ── 完成 ─────────────────────────────────────────────────────────────────
    echo ""
    print_line
    echo -e "${GREEN}${BOLD}"
    echo "  ✅  服务器初始化完成！（轻量化版 v2）"
    echo -e "${NC}"
    print_line
    echo ""

    local server_ip
    server_ip=$(get_public_ip)

    echo -e "${WHITE}管理面板：${NC}"
    echo ""
    echo -e "  ${CYAN}Nginx Proxy Manager${NC}  http://${server_ip}:81"
    echo -e "  账号: admin@example.com  密码: changeme  ${RED}← 请立即修改！${NC}"
    echo ""
    print_line
    echo ""
    echo -e "${WHITE}内存使用情况：${NC}"
    free -h | grep -E "Mem|Swap"
    echo ""
    print_line
    echo ""
    echo -e "${WHITE}按需安装（需要时执行）：${NC}"
    echo ""
    echo -e "  ${CYAN}manus install-mysql${NC}      # 安装 MySQL 数据库（需要数据库的网站才安装）"
    echo -e "  ${CYAN}manus install-portainer${NC}  # 安装 Portainer 可视化管理面板"
    echo ""
    print_line
    echo ""
    echo -e "${WHITE}下一步 — 部署您的第一个网站：${NC}"
    echo ""
    echo -e "  ${GREEN}manus npm-login${NC}              # 先设置 NPM 登录凭据（一次性）"
    echo -e "  ${GREEN}manus deploy <仓库地址>${NC}      # 一键部署网站"
    echo -e "  ${GREEN}manus add${NC}                    # 交互式部署新网站"
    echo -e "  ${GREEN}manus help${NC}                   # 查看所有命令"
    echo ""
    print_line
    echo ""
    log_info "完成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
}

# ── 安装 manus CLI 工具到系统路径 ────────────────────────────────────────────
install_manus_cli() {
    local manage_script="/opt/manus/manage.sh"
    local local_manage="${SCRIPT_DIR}/manage.sh"
    local remote_manage="${REMOTE_BASE}/manage.sh"

    # 复制函数库到 /opt/manus/lib
    for lib in common.sh docker.sh firewall.sh backup.sh deploy.sh npm_api.sh \
               sysinfo.sh docker_mgr.sh network.sh system_tools.sh site_mgr.sh; do
        local local_lib="${SCRIPT_DIR}/lib/${lib}"
        local remote_lib="${REMOTE_BASE}/lib/${lib}"
        mkdir -p /opt/manus/lib
        if [ -f "$local_lib" ]; then
            cp "$local_lib" "/opt/manus/lib/${lib}"
        else
            curl -fsSL "$remote_lib" -o "/opt/manus/lib/${lib}" 2>/dev/null || true
        fi
        [ -f "/opt/manus/lib/${lib}" ] && chmod 644 "/opt/manus/lib/${lib}"
    done

    # 复制模板目录
    if [ -d "${SCRIPT_DIR}/templates" ]; then
        cp -r "${SCRIPT_DIR}/templates" /opt/manus/
    else
        # 下载模板（仅关键文件）
        mkdir -p /opt/manus/templates/website
        curl -fsSL "${REMOTE_BASE}/templates/website/manus.config.json" \
            -o "/opt/manus/templates/website/manus.config.json" 2>/dev/null || true
    fi

    # 下载 manage.sh
    if [ -f "$local_manage" ]; then
        cp "$local_manage" "$manage_script"
    else
        curl -fsSL "$remote_manage" -o "$manage_script"
    fi
    chmod 750 "$manage_script"

    # 创建全局命令 manus
    cat > /usr/local/bin/manus << 'EOF'
#!/bin/bash
exec bash /opt/manus/manage.sh "$@"
EOF
    chmod 755 /usr/local/bin/manus

    log_success "manus 命令已安装，可直接使用 'manus' 命令管理站点"
}

# ── 入口 ─────────────────────────────────────────────────────────────────────
main "$@"
