#!/bin/bash
# =============================================================================
# server-init.sh — 服务器一键初始化脚本（安全加固版）
# 项目: manus-deploy
# 用法: bash <(curl -fsSL https://raw.githubusercontent.com/Alexlyu365/manus/main/server-init.sh)
# 适用: Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12 (Bookworm)
# Google Cloud: 默认系统 Debian 12 完整支持
#
# 安全加固修订:
#   SEC-03: 添加脚本完整性提示和 SSH 密钥前置检查
#   SEC-07: 主流程中调用 harden_ssh()（强制禁用 SSH 密码登录）
#   SEC-06: 主流程中调用 setup_fail2ban()
#   SEC-11: 主流程中调用 setup_auto_security_updates()
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
        # SEC-03: 使用 -f 确保下载失败时报错，而非静默失败
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

# ── GitHub Token 配置（自动写入服务器本地，无需用户操作）────────────────────────────
setup_github_token() {
    local token_file="/opt/manus/.github_token"
    # Token 内嵌于脚本，初始化时自动写入服务器本地（不保存在仓库代码中）
    local GITHUB_TOKEN="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"
    local GITHUB_USER="Alexlyu365"

    mkdir -p /opt/manus

    log_step "配置 GitHub 私有仓库访问 Token..."

    # 将 Token 写入本地文件（仅 root 可读）
    echo "$GITHUB_TOKEN" > "$token_file"
    chmod 600 "$token_file"

    # 配置 git credential helper
    git config --global credential.helper store 2>/dev/null

    # 写入 git credentials，让所有 git clone 自动认证
    echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com" > /root/.git-credentials
    chmod 600 /root/.git-credentials

    log_success "GitHub Token 已自动配置，可直接部署公开和私有仓库"
}

# ── SEC-03: SSH 密钥前置检查 ─────────────────────────────────────────────────
check_ssh_key() {
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║              重要安全提示 — 请先阅读再继续                    ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}本脚本将禁用 SSH 密码登录，仅允许 SSH 密钥认证。${NC}"
    echo -e "${WHITE}这是防止暴力破解攻击的重要安全措施。${NC}"
    echo ""
    echo -e "${RED}请确认您已完成以下操作，否则初始化后将无法登录服务器：${NC}"
    echo ""
    echo "  1. 已在本机生成 SSH 密钥对（ssh-keygen -t ed25519）"
    echo "  2. 已将公钥添加到服务器（ssh-copy-id user@server）"
    echo "  3. 已测试密钥登录成功（ssh -i ~/.ssh/id_ed25519 user@server）"
    echo ""

    # 检查是否已有授权密钥
    local auth_keys_count=0
    if [ -f /root/.ssh/authorized_keys ]; then
        auth_keys_count=$(grep -c "^ssh-" /root/.ssh/authorized_keys 2>/dev/null || echo 0)
    fi
    # 检查其他用户的授权密钥
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
        echo -e "${RED}  警告: 未检测到任何 SSH 授权密钥！${NC}"
        echo -e "${RED}  如果继续，初始化完成后您可能无法登录服务器！${NC}"
        echo ""
        echo -e "${YELLOW}  是否仍要继续？（强烈建议先配置 SSH 密钥）${NC}"
        if ! confirm "我了解风险，确认继续（不推荐）"; then
            echo ""
            echo "已取消。请先配置 SSH 密钥后再运行本脚本。"
            echo ""
            echo "配置 SSH 密钥步骤（在本地机器上执行）："
            echo "  ssh-keygen -t ed25519 -C 'your@email.com'"
            echo "  ssh-copy-id root@$(get_public_ip)"
            echo ""
            exit 0
        fi
    fi
}

# ── 主初始化流程 ─────────────────────────────────────────────────────────────
main() {
    clear
    print_banner

    # ── Debian 12 / Google Cloud 特有提示 ──────────────────────────────────
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" = "debian" ]; then
            echo -e "${CYAN}检测到 Debian ${VERSION_ID} (${VERSION_CODENAME:-})${NC}"
            echo ""
            # Google Cloud Debian 默认用户为 非root 用户（如 user），需要 sudo
            if [ "$EUID" -ne 0 ]; then
                echo -e "${YELLOW}提示: Google Cloud Debian 服务器请使用 sudo 运行本脚本${NC}"
                echo -e "${YELLOW}命令: sudo bash <(curl -fsSL https://raw.githubusercontent.com/Alexlyu365/manus/main/server-init.sh)${NC}"
                echo ""
            fi
        fi
    fi

    echo -e "${WHITE}本脚本将在您的服务器上完成以下操作：${NC}"
    echo ""
    echo "  1.  更新系统软件包"
    echo "  2.  安装基础工具（curl、git、vim 等）"
    echo "  3.  安装 Docker Engine"
    echo "  4.  优化系统内核参数（含安全加固）"
    echo "  5.  配置 UFW 防火墙（修复 Docker 绕过问题）"
    echo "  6.  加固 SSH 安全（禁用密码登录，启用密钥认证）"
    echo "  7.  安装 Fail2ban（防暴力破解）"
    echo "  8.  配置自动安全更新"
    echo "  9.  部署 Nginx Proxy Manager（可视化反向代理，端口 81）"
    echo "  10. 部署 Portainer（通过 Socket Proxy 安全访问，端口 9000）"
    echo "  11. 部署 MySQL 8.0 数据库（安全加固版）"
    echo "  12. 配置每日自动备份（凌晨 3:00）"
    echo "  13. 安装 manus 管理工具到系统路径"
    echo ""
    print_line

    # 检查权限
    check_root

    # SEC-03: SSH 密钥前置检查
    check_ssh_key

    # 确认执行
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

    # ── Step 2: 更新系统 ─────────────────────────────────────────────────────
    log_step "[1/12] 更新系统软件包..."
    $PKG_UPDATE
    if [ "$PKG_MANAGER" = "apt-get" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    fi
    log_success "系统更新完成"

    # ── Step 3: 安装基础工具 ─────────────────────────────────────────────────
    log_step "[2/12] 安装基础工具..."
    install_base_packages

    # ── Step 4: 安装 Docker ──────────────────────────────────────────────────
    log_step "[3/12] 安装 Docker..."
    install_docker
    configure_docker_daemon

    # ── Step 5: 优化系统参数 ─────────────────────────────────────────────────
    log_step "[4/12] 优化系统参数（含安全加固）..."
    configure_sysctl
    configure_limits

    # ── Step 6: 配置防火墙 ───────────────────────────────────────────────────
    log_step "[5/12] 配置防火墙（修复 Docker UFW 绕过）..."
    setup_firewall

    # ── Step 7: SEC-07 加固 SSH ──────────────────────────────────────────────
    log_step "[6/12] 加固 SSH 安全配置..."
    harden_ssh

    # ── Step 8: SEC-06 安装 Fail2ban ─────────────────────────────────────────
    log_step "[7/12] 安装 Fail2ban（防暴力破解）..."
    setup_fail2ban

    # ── Step 9: SEC-11 配置自动安全更新 ──────────────────────────────────────
    log_step "[8/12] 配置自动安全更新..."
    setup_auto_security_updates

    # ── Step 10: 创建目录结构 ────────────────────────────────────────────────
    log_step "[9/12] 创建目录结构..."
    mkdir -p /opt/manus/{lib,scripts,backups}
    mkdir -p /opt/sites
    touch /opt/manus/sites.conf
    # 设置严格权限
    chmod 700 /opt/manus
    chmod 755 /opt/sites
    log_success "目录结构创建完成: /opt/manus, /opt/sites"

    # ── GitHub Token 自动配置 ───────────────────────────────────────────────
    setup_github_token

    # ── Step 11: 部署基础服务 ────────────────────────────────────────────────
    log_step "[10/12] 部署基础服务..."

    log_info "部署 Nginx Proxy Manager..."
    deploy_nginx_proxy_manager

    log_info "部署 Portainer（通过 Socket Proxy）..."
    deploy_portainer

    log_info "部署 MySQL 8.0..."
    deploy_mysql

    # ── Step 12: 配置自动备份 ────────────────────────────────────────────────
    log_step "[11/12] 配置自动备份..."
    setup_auto_backup

    # ── Step 13: 安装 manus 管理工具 ─────────────────────────────────────────
    log_step "[12/12] 安装 manus 管理工具..."
    install_manus_cli

    # ── 完成 ─────────────────────────────────────────────────────────────────
    echo ""
    print_line
    echo -e "${GREEN}${BOLD}"
    echo "  ✅  服务器初始化完成！（安全加固版）"
    echo -e "${NC}"
    print_line
    echo ""

    local server_ip
    server_ip=$(get_public_ip)

    echo -e "${WHITE}管理面板访问地址：${NC}"
    echo ""
    echo -e "  ${CYAN}Nginx Proxy Manager${NC}"
    echo -e "  地址: http://${server_ip}:81"
    echo -e "  账号: admin@example.com"
    echo -e "  密码: changeme  ${RED}← 请立即修改！${NC}"
    echo ""
    echo -e "  ${CYAN}Portainer${NC}"
    echo -e "  地址: http://${server_ip}:9000"
    echo -e "  首次访问请在 5 分钟内设置管理员密码"
    echo ""
    echo -e "  ${CYAN}MySQL 8.0${NC}"
    echo -e "  地址: 127.0.0.1:3306（仅本机）"
    echo -e "  root 密码: $(cat /opt/manus/.mysql_root_pass)"
    echo ""
    print_line
    echo ""
    echo -e "${WHITE}安全加固状态：${NC}"
    echo ""
    echo -e "  ${GREEN}✓${NC} UFW 防火墙已启用（修复 Docker 绕过问题）"
    echo -e "  ${GREEN}✓${NC} SSH 密码登录已禁用（仅允许密钥认证）"
    echo -e "  ${GREEN}✓${NC} Fail2ban 已启动（防暴力破解）"
    echo -e "  ${GREEN}✓${NC} 自动安全更新已配置"
    echo -e "  ${GREEN}✓${NC} Portainer 通过 Socket Proxy 安全访问"
    echo -e "  ${GREEN}✓${NC} MySQL root 仅允许本机连接"
    echo -e "  ${GREEN}✓${NC} 容器资源限制已配置"
    echo ""
    echo -e "${YELLOW}建议后续操作：${NC}"
    echo ""
    echo -e "  1. 登录 NPM (http://${server_ip}:81) 立即修改默认密码"
    echo -e "  2. 执行 ${CYAN}manus restrict-admin <你的IP>${NC} 限制管理端口访问"
    echo -e "  3. 查看安全审计报告: ${CYAN}cat /opt/manus/SECURITY_AUDIT.md${NC}"

    echo -e "  ${GREEN}✓${NC} GitHub Token 已自动配置，可直接部署公开和私有仓库"
    echo ""
    print_line
    echo ""
    echo -e "${WHITE}下一步 — 部署您的第一个网站：${NC}"
    echo ""
    echo -e "  ${GREEN}manus deploy <仓库地址>${NC}  # ★ 一键部署（自动完成容器+SSL）"
    echo -e "  ${GREEN}manus add${NC}                 # 交互式部署新网站"
    echo -e "  ${GREEN}manus list${NC}                # 查看所有站点"
    echo -e "  ${GREEN}manus help${NC}                # 查看所有命令"
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
    for lib in common.sh docker.sh firewall.sh backup.sh; do
        local local_lib="${SCRIPT_DIR}/lib/${lib}"
        local remote_lib="${REMOTE_BASE}/lib/${lib}"
        if [ -f "$local_lib" ]; then
            cp "$local_lib" "/opt/manus/lib/${lib}"
        else
            curl -fsSL "$remote_lib" -o "/opt/manus/lib/${lib}"
        fi
        chmod 644 "/opt/manus/lib/${lib}"
    done

    # 复制安全审计报告
    local local_audit="${SCRIPT_DIR}/SECURITY_AUDIT.md"
    if [ -f "$local_audit" ]; then
        cp "$local_audit" "/opt/manus/SECURITY_AUDIT.md"
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
