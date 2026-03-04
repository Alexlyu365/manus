#!/bin/bash
# =============================================================================
# server-init.sh — 服务器一键初始化脚本
# 项目: manus-deploy
# 用法: bash <(curl -s https://raw.githubusercontent.com/Alexlyu365/manus/main/server-init.sh)
# 适用: Ubuntu 20.04 / 22.04 / 24.04
# =============================================================================

set -e

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
        tmp_file=$(mktemp)
        curl -fsSL "$remote_url" -o "$tmp_file"
        source "$tmp_file"
        rm -f "$tmp_file"
    fi
}

load_lib "common.sh"
load_lib "docker.sh"
load_lib "firewall.sh"
load_lib "backup.sh"

# ── 主初始化流程 ─────────────────────────────────────────────────────────────
main() {
    clear
    print_banner

    echo -e "${WHITE}本脚本将在您的服务器上完成以下操作：${NC}"
    echo ""
    echo "  1. 更新系统软件包"
    echo "  2. 安装基础工具（curl、git、vim 等）"
    echo "  3. 安装 Docker Engine"
    echo "  4. 优化系统内核参数"
    echo "  5. 配置 UFW 防火墙"
    echo "  6. 部署 Nginx Proxy Manager（可视化反向代理，端口 81）"
    echo "  7. 部署 Portainer（Docker 可视化管理，端口 9000）"
    echo "  8. 部署 MySQL 8.0 数据库"
    echo "  9. 配置每日自动备份（凌晨 3:00）"
    echo " 10. 安装 manus 管理工具到系统路径"
    echo ""
    print_line

    # 检查权限
    check_root

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
    log_step "[1/9] 更新系统软件包..."
    $PKG_UPDATE
    if [ "$PKG_MANAGER" = "apt-get" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    fi
    log_success "系统更新完成"

    # ── Step 3: 安装基础工具 ─────────────────────────────────────────────────
    log_step "[2/9] 安装基础工具..."
    install_base_packages

    # ── Step 4: 安装 Docker ──────────────────────────────────────────────────
    log_step "[3/9] 安装 Docker..."
    install_docker
    configure_docker_daemon

    # ── Step 5: 优化系统参数 ─────────────────────────────────────────────────
    log_step "[4/9] 优化系统参数..."
    configure_sysctl
    configure_limits

    # ── Step 6: 配置防火墙 ───────────────────────────────────────────────────
    log_step "[5/9] 配置防火墙..."
    setup_firewall

    # ── Step 7: 创建目录结构 ─────────────────────────────────────────────────
    log_step "[6/9] 创建目录结构..."
    mkdir -p /opt/manus/{lib,scripts,backups}
    mkdir -p /opt/sites
    touch /opt/manus/sites.conf
    log_success "目录结构创建完成: /opt/manus, /opt/sites"

    # ── Step 8: 部署基础服务 ─────────────────────────────────────────────────
    log_step "[7/9] 部署 Nginx Proxy Manager..."
    deploy_nginx_proxy_manager

    log_step "[7/9] 部署 Portainer..."
    deploy_portainer

    log_step "[7/9] 部署 MySQL 8.0..."
    deploy_mysql

    # ── Step 9: 配置自动备份 ─────────────────────────────────────────────────
    log_step "[8/9] 配置自动备份..."
    setup_auto_backup

    # ── Step 10: 安装 manus 管理工具 ─────────────────────────────────────────
    log_step "[9/9] 安装 manus 管理工具..."
    install_manus_cli

    # ── 完成 ─────────────────────────────────────────────────────────────────
    echo ""
    print_line
    echo -e "${GREEN}${BOLD}"
    echo "  ✅  服务器初始化完成！"
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
    echo -e "${WHITE}下一步 — 部署您的第一个网站：${NC}"
    echo ""
    echo -e "  ${GREEN}manus add${NC}   # 交互式部署新网站"
    echo -e "  ${GREEN}manus list${NC}  # 查看所有站点"
    echo -e "  ${GREEN}manus help${NC}  # 查看所有命令"
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
    done

    # 下载 manage.sh
    if [ -f "$local_manage" ]; then
        cp "$local_manage" "$manage_script"
    else
        curl -fsSL "$remote_manage" -o "$manage_script"
    fi
    chmod +x "$manage_script"

    # 创建全局命令 manus
    cat > /usr/local/bin/manus << 'EOF'
#!/bin/bash
exec bash /opt/manus/manage.sh "$@"
EOF
    chmod +x /usr/local/bin/manus

    log_success "manus 命令已安装，可直接使用 'manus' 命令管理站点"
}

# ── 入口 ─────────────────────────────────────────────────────────────────────
main "$@"
