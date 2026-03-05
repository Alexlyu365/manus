#!/bin/bash
# =============================================================================
# manage.sh — manus 站点管理主脚本
# 项目: manus-deploy
# 用法: manus [命令] [参数]
#       或直接运行进入交互式菜单
# =============================================================================

set -e

# ── 加载函数库 ────────────────────────────────────────────────────────────────
LIB_DIR="/opt/manus/lib"
REMOTE_BASE="https://raw.githubusercontent.com/Alexlyu365/manus/main"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

load_lib() {
    local lib_name="$1"
    local paths=(
        "${LIB_DIR}/${lib_name}"
        "${SCRIPT_DIR}/lib/${lib_name}"
    )
    for p in "${paths[@]}"; do
        if [ -f "$p" ]; then
            source "$p"
            return
        fi
    done
    # 从远程加载
    local tmp
    tmp=$(mktemp)
    curl -fsSL "${REMOTE_BASE}/lib/${lib_name}" -o "$tmp"
    source "$tmp"
    rm -f "$tmp"
}

load_lib "common.sh"
load_lib "docker.sh"
load_lib "firewall.sh"
load_lib "backup.sh"
load_lib "npm_api.sh"
load_lib "deploy.sh"
load_lib "sysinfo.sh"
load_lib "docker_mgr.sh"
load_lib "network.sh"
load_lib "system_tools.sh"
load_lib "site_mgr.sh"

# ── 检测操作系统 ─────────────────────────────────────────────────────────────
detect_os

# =============================================================================
# 站点部署核心函数
# =============================================================================

# ── 部署新站点（交互式）──────────────────────────────────────────────────────
cmd_add() {
    check_root
    clear
    print_banner
    echo -e "${WHITE}── 部署新网站 ──────────────────────────────────────────${NC}"
    echo ""

    # ── 输入域名 ──────────────────────────────────────────────────────────────
    while true; do
        echo -e "${YELLOW}请输入网站域名（例如: example.com 或 shop.example.com）:${NC} \c"
        read -r DOMAIN
        DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/^https\?:\/\///' | sed 's/\/$//')
        if validate_domain "$DOMAIN"; then
            break
        else
            log_error "域名格式不正确，请重新输入"
        fi
    done

    # ── 选择网站类型 ──────────────────────────────────────────────────────────
    echo ""
    echo -e "${WHITE}请选择网站类型：${NC}"
    echo "  1) 静态网站（HTML/CSS/JS，产品展示、图片展示）"
    echo "  2) Node.js 应用（Next.js / Express / Nuxt 等）"
    echo "  3) PHP 应用（Laravel / WordPress / 原生 PHP）"
    echo ""
    echo -e "${YELLOW}请输入选项 [1-3]:${NC} \c"
    read -r SITE_TYPE_NUM

    case "$SITE_TYPE_NUM" in
        1) SITE_TYPE="static" ;;
        2) SITE_TYPE="nodejs" ;;
        3) SITE_TYPE="php" ;;
        *) log_error "无效选项"; exit 1 ;;
    esac

    # ── 是否需要数据库 ────────────────────────────────────────────────────────
    NEED_DB=false
    if [ "$SITE_TYPE" != "static" ]; then
        echo ""
        if confirm "是否为此站点创建独立 MySQL 数据库？"; then
            NEED_DB=true
        fi
    fi

    # ── 确认信息 ──────────────────────────────────────────────────────────────
    echo ""
    print_line
    echo -e "${WHITE}部署信息确认：${NC}"
    echo "  域名:     $DOMAIN"
    echo "  类型:     $SITE_TYPE"
    echo "  数据库:   $([ "$NEED_DB" = true ] && echo '是（独立 MySQL 数据库）' || echo '否')"
    print_line
    echo ""

    if ! confirm "确认开始部署？"; then
        echo "已取消"
        return
    fi

    # ── 开始部署 ──────────────────────────────────────────────────────────────
    deploy_site "$DOMAIN" "$SITE_TYPE" "$NEED_DB"
}

# ── 执行站点部署 ─────────────────────────────────────────────────────────────
deploy_site() {
    local domain="$1"
    local site_type="$2"
    local need_db="${3:-false}"

    local site_name
    site_name=$(echo "$domain" | tr '.' '_' | tr '-' '_')
    local site_dir="/opt/sites/${domain}"
    local app_port
    app_port=$(gen_random_port 10000 59999)

    log_step "开始部署站点: ${domain}..."

    # ── 创建站点目录 ──────────────────────────────────────────────────────────
    mkdir -p "${site_dir}"/{html,logs,uploads}
    chmod 755 "${site_dir}"

    # ── 复制模板文件 ──────────────────────────────────────────────────────────
    local template_base="${SCRIPT_DIR}/templates"
    local remote_template="${REMOTE_BASE}/templates"

    copy_template() {
        local tpl_file="$1"
        local dest="$2"
        local local_path="${template_base}/${tpl_file}"
        if [ -f "$local_path" ]; then
            cp "$local_path" "$dest"
        else
            curl -fsSL "${remote_template}/${tpl_file}" -o "$dest"
        fi
    }

    case "$site_type" in
        static)
            copy_template "static/docker-compose.yml" "${site_dir}/docker-compose.yml"
            copy_template "static/nginx.conf" "${site_dir}/nginx.conf"
            # 创建默认首页
            create_default_index "$domain" "$site_dir"
            ;;
        nodejs)
            copy_template "nodejs/docker-compose.yml" "${site_dir}/docker-compose.yml"
            copy_template "nodejs/Dockerfile" "${site_dir}/Dockerfile"
            ;;
        php)
            copy_template "php/docker-compose.yml" "${site_dir}/docker-compose.yml"
            copy_template "php/nginx.conf" "${site_dir}/nginx.conf"
            copy_template "php/php.ini" "${site_dir}/php.ini"
            mkdir -p "${site_dir}/logs/nginx" "${site_dir}/logs/php"
            ;;
    esac

    # ── 处理数据库 ────────────────────────────────────────────────────────────
    local db_pass=""
    if [ "$need_db" = true ]; then
        db_pass=$(create_site_database "$domain")
    fi

    # ── 生成 .env 文件 ────────────────────────────────────────────────────────
    local db_name
    db_name=$(echo "$domain" | tr '.' '_' | tr '-' '_' | tr '[:upper:]' '[:lower:]')
    db_name="site_${db_name}"

    cat > "${site_dir}/.env" << EOF
# 站点: ${domain}
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

DOMAIN=${domain}
SITE_NAME=${site_name}
APP_PORT=${app_port}

DB_HOST=manus-mysql
DB_PORT=3306
DB_NAME=${db_name}
DB_USER=${db_name}_user
DB_PASS=${db_pass}

TZ=Asia/Shanghai
NODE_ENV=production
EOF
    chmod 600 "${site_dir}/.env"

    # ── 替换 docker-compose.yml 中的变量 ─────────────────────────────────────
    sed -i \
        -e "s/\${DOMAIN}/${domain}/g" \
        -e "s/\${SITE_NAME}/${site_name}/g" \
        -e "s/\${APP_PORT:-3000}/${app_port}/g" \
        -e "s/\${APP_PORT}/${app_port}/g" \
        "${site_dir}/docker-compose.yml"

    # ── 启动容器 ──────────────────────────────────────────────────────────────
    log_step "启动站点容器..."
    cd "$site_dir"
    docker compose up -d --build

    # ── 注册站点 ──────────────────────────────────────────────────────────────
    register_site "$domain" "$site_type" "$app_port"

    # ── 完成提示 ──────────────────────────────────────────────────────────────
    echo ""
    print_line
    echo -e "${GREEN}${BOLD}  ✅  站点 ${domain} 部署完成！${NC}"
    print_line
    echo ""
    echo -e "${WHITE}下一步 — 在 Nginx Proxy Manager 中配置代理：${NC}"
    echo ""
    echo -e "  1. 打开 NPM 管理界面: http://$(get_public_ip):81"
    echo -e "  2. 点击 [Proxy Hosts] → [Add Proxy Host]"
    echo -e "  3. Domain Names: ${CYAN}${domain}${NC}"

    if [ "$site_type" = "static" ]; then
        echo -e "  4. Forward Hostname/IP: ${CYAN}site_${site_name}${NC}"
        echo -e "     Forward Port: ${CYAN}80${NC}"
    else
        echo -e "  4. Forward Hostname/IP: ${CYAN}site_${site_name}${NC}"
        echo -e "     Forward Port: ${CYAN}${app_port}${NC}"
    fi

    echo -e "  5. 勾选 [SSL] → [Request a new SSL Certificate] → 勾选 [Force SSL]"
    echo ""
    echo -e "${WHITE}站点文件目录: ${CYAN}${site_dir}${NC}"
    echo -e "${WHITE}网站文件放置: ${CYAN}${site_dir}/html/${NC}"
    if [ "$need_db" = true ]; then
        echo ""
        echo -e "${WHITE}数据库信息:${NC}"
        echo -e "  数据库名: ${CYAN}${db_name}${NC}"
        echo -e "  用户名:   ${CYAN}${db_name}_user${NC}"
        echo -e "  密码:     ${CYAN}${db_pass}${NC}"
        echo -e "  （已保存至 ${site_dir}/.env）"
    fi
    echo ""
}

# ── 创建默认首页 ─────────────────────────────────────────────────────────────
create_default_index() {
    local domain="$1"
    local site_dir="$2"

    cat > "${site_dir}/html/index.html" << EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${domain} — 网站部署成功</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: white;
        }
        .card {
            text-align: center;
            padding: 60px 40px;
            background: rgba(255,255,255,0.15);
            backdrop-filter: blur(10px);
            border-radius: 20px;
            border: 1px solid rgba(255,255,255,0.2);
            max-width: 500px;
        }
        h1 { font-size: 2.5rem; margin-bottom: 16px; }
        p { font-size: 1.1rem; opacity: 0.85; line-height: 1.6; }
        .domain { font-size: 1.3rem; font-weight: bold; margin: 20px 0;
                  background: rgba(255,255,255,0.2); padding: 10px 20px;
                  border-radius: 8px; display: inline-block; }
        .hint { font-size: 0.9rem; opacity: 0.7; margin-top: 20px; }
    </style>
</head>
<body>
    <div class="card">
        <h1>🚀 部署成功</h1>
        <div class="domain">${domain}</div>
        <p>您的网站已成功部署！<br>请将您的网站文件上传到此目录替换此页面。</p>
        <p class="hint">网站目录: /opt/sites/${domain}/html/</p>
    </div>
</body>
</html>
EOF
}

# ── 列出所有站点 ─────────────────────────────────────────────────────────────
cmd_list() {
    clear
    print_banner
    echo -e "${WHITE}── 已部署的站点 ────────────────────────────────────────${NC}"
    echo ""
    list_sites
    echo ""

    # 显示容器状态
    echo -e "${WHITE}── 容器运行状态 ────────────────────────────────────────${NC}"
    echo ""
    docker ps --filter "label=manus.site" \
        --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null \
        || echo "（无运行中的站点容器）"
    echo ""
}

# ── 停止站点 ─────────────────────────────────────────────────────────────────
cmd_stop() {
    local domain="${1:-}"
    check_root

    if [ -z "$domain" ]; then
        echo -e "${YELLOW}请输入要停止的站点域名:${NC} \c"
        read -r domain
    fi

    local site_dir="/opt/sites/${domain}"
    if [ ! -d "$site_dir" ]; then
        log_error "站点不存在: $domain"
        return 1
    fi

    cd "$site_dir"
    docker compose stop
    log_success "站点 ${domain} 已停止"
}

# ── 启动站点 ─────────────────────────────────────────────────────────────────
cmd_start() {
    local domain="${1:-}"
    check_root

    if [ -z "$domain" ]; then
        echo -e "${YELLOW}请输入要启动的站点域名:${NC} \c"
        read -r domain
    fi

    local site_dir="/opt/sites/${domain}"
    if [ ! -d "$site_dir" ]; then
        log_error "站点不存在: $domain"
        return 1
    fi

    cd "$site_dir"
    docker compose up -d
    log_success "站点 ${domain} 已启动"
}

# ── 重启站点 ─────────────────────────────────────────────────────────────────
cmd_restart() {
    local domain="${1:-}"
    check_root

    if [ -z "$domain" ]; then
        echo -e "${YELLOW}请输入要重启的站点域名:${NC} \c"
        read -r domain
    fi

    local site_dir="/opt/sites/${domain}"
    if [ ! -d "$site_dir" ]; then
        log_error "站点不存在: $domain"
        return 1
    fi

    cd "$site_dir"
    docker compose restart
    log_success "站点 ${domain} 已重启"
}

# ── 更新站点（拉取最新代码并重建）──────────────────────────────────────────
cmd_update() {
    local domain="${1:-}"
    check_root

    if [ -z "$domain" ]; then
        echo -e "${YELLOW}请输入要更新的站点域名:${NC} \c"
        read -r domain
    fi

    local site_dir="/opt/sites/${domain}"
    if [ ! -d "$site_dir" ]; then
        log_error "站点不存在: $domain"
        return 1
    fi

    log_step "更新站点: ${domain}..."

    # 如果是 Git 仓库，先拉取最新代码
    if [ -d "${site_dir}/.git" ]; then
        log_info "拉取最新代码..."
        cd "$site_dir"
        git pull origin main 2>/dev/null || git pull origin master 2>/dev/null || true
    fi

    # 重建并重启容器
    cd "$site_dir"
    docker compose up -d --build --force-recreate

    log_success "站点 ${domain} 更新完成"
}

# ── 删除站点 ─────────────────────────────────────────────────────────────────
cmd_remove() {
    local domain="${1:-}"
    check_root

    if [ -z "$domain" ]; then
        echo -e "${YELLOW}请输入要删除的站点域名:${NC} \c"
        read -r domain
    fi

    local site_dir="/opt/sites/${domain}"
    if [ ! -d "$site_dir" ]; then
        log_error "站点不存在: $domain"
        return 1
    fi

    echo ""
    echo -e "${RED}警告: 此操作将删除站点 ${domain} 的所有文件和数据库！${NC}"
    echo ""

    if ! confirm "确认删除站点 ${domain}？（此操作不可恢复）"; then
        echo "已取消"
        return
    fi

    # 先备份
    if confirm "是否在删除前创建备份？（推荐）"; then
        backup_site "$domain"
    fi

    # 停止并删除容器
    log_step "停止并删除容器..."
    cd "$site_dir"
    docker compose down --volumes --remove-orphans 2>/dev/null || true

    # 删除 Docker 镜像
    local site_name
    site_name=$(echo "$domain" | tr '.' '_' | tr '-' '_')
    docker rmi "site_${site_name}:latest" 2>/dev/null || true

    # 删除数据库
    drop_site_database "$domain"

    # 删除站点目录
    rm -rf "$site_dir"

    # 从注册表移除
    unregister_site "$domain"

    log_success "站点 ${domain} 已完全删除"
    log_warn "请手动在 Nginx Proxy Manager 中删除对应的代理规则"
}

# ── 查看站点日志 ─────────────────────────────────────────────────────────────
cmd_logs() {
    local domain="${1:-}"

    if [ -z "$domain" ]; then
        echo -e "${YELLOW}请输入要查看日志的站点域名:${NC} \c"
        read -r domain
    fi

    local site_dir="/opt/sites/${domain}"
    if [ ! -d "$site_dir" ]; then
        log_error "站点不存在: $domain"
        return 1
    fi

    echo ""
    echo -e "${WHITE}查看站点 ${domain} 的实时日志（Ctrl+C 退出）：${NC}"
    echo ""
    cd "$site_dir"
    docker compose logs -f --tail=100
}

# ── 备份操作 ─────────────────────────────────────────────────────────────────
cmd_backup() {
    local domain="${1:-}"
    check_root

    if [ -n "$domain" ]; then
        backup_site "$domain"
    else
        echo ""
        echo -e "${WHITE}备份选项：${NC}"
        echo "  1) 备份指定站点"
        echo "  2) 备份所有站点"
        echo "  3) 查看备份列表"
        echo ""
        echo -e "${YELLOW}请选择 [1-3]:${NC} \c"
        read -r choice

        case "$choice" in
            1)
                echo -e "${YELLOW}请输入站点域名:${NC} \c"
                read -r d
                backup_site "$d"
                ;;
            2) backup_all_sites ;;
            3) list_backups ;;
            *) log_error "无效选项" ;;
        esac
    fi
}

# ── 系统状态总览 ─────────────────────────────────────────────────────────────
cmd_status() {
    clear
    print_banner
    echo -e "${WHITE}── 系统状态总览 ────────────────────────────────────────${NC}"
    echo ""

    # 服务器基本信息
    echo -e "${CYAN}服务器信息：${NC}"
    echo "  公网 IP:  $(get_public_ip)"
    echo "  系统:     $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo "  内核:     $(uname -r)"
    echo "  运行时间: $(uptime -p)"
    echo ""

    # 资源使用
    echo -e "${CYAN}资源使用：${NC}"
    echo "  CPU:  $(top -bn1 | grep 'Cpu(s)' | awk '{print $2}')% 使用"
    echo "  内存: $(free -h | awk '/^Mem:/{print $3 " / " $2}')"
    echo "  磁盘: $(df -h / | awk 'NR==2{print $3 " / " $2 " (" $5 " 使用)"}')"
    echo ""

    # Docker 状态
    echo -e "${CYAN}Docker 容器状态：${NC}"
    docker ps --format "  {{.Names}}\t{{.Status}}" 2>/dev/null || echo "  Docker 未运行"
    echo ""

    # 站点列表
    echo -e "${CYAN}已部署站点：${NC}"
    if [ -f "$SITES_REGISTRY" ] && [ -s "$SITES_REGISTRY" ]; then
        while IFS='|' read -r domain type port created_at; do
            local status="🔴 停止"
            if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "site_$(echo "$domain" | tr '.' '_' | tr '-' '_')"; then
                status="🟢 运行"
            fi
            printf "  %-35s %-10s %s\n" "$domain" "$type" "$status"
        done < "$SITES_REGISTRY"
    else
        echo "  （暂无已部署的站点）"
    fi
    echo ""

    # 磁盘使用（备份）
    if [ -d "/opt/manus/backups" ]; then
        local backup_size
        backup_size=$(du -sh /opt/manus/backups 2>/dev/null | cut -f1)
        echo -e "${CYAN}备份占用空间: ${backup_size}${NC}"
        echo ""
    fi
}

# ── 更新 manus 工具自身 ──────────────────────────────────────────────────────
cmd_self_update() {
    check_root
    log_step "更新 manus 工具..."

    for lib in common.sh docker.sh firewall.sh backup.sh; do
        curl -fsSL "${REMOTE_BASE}/lib/${lib}" -o "${LIB_DIR}/${lib}"
        log_info "已更新: ${lib}"
    done

    curl -fsSL "${REMOTE_BASE}/manage.sh" -o /opt/manus/manage.sh
    chmod +x /opt/manus/manage.sh
    log_success "manus 工具更新完成"
}

# ── 从# ── 一键部署：从包含 manus.config.json 的 Git 仓库自动完成全流程 ─────────
cmd_deploy() {
    check_root
    local repo_url="${1:-}"
    local custom_domain="${2:-}"

    clear
    print_banner
    echo -e "${WHITE}── 一键部署网站 ──────────────────────────────────────${NC}"
    echo ""

    # 如果未提供仓库地址，交互式输入
    if [ -z "$repo_url" ]; then
        echo -e "${YELLOW}请输入网站 GitHub 仓库地址:${NC}"
        echo -e "${WHITE}（例如: https://github.com/Alexlyu365/my-website.git）${NC}"
        echo -n "  > "
        read -r repo_url
    fi

    if [ -z "$repo_url" ]; then
        log_error "仓库地址不能为空"
        return 1
    fi

    echo ""
    log_info "开始一键部署: $repo_url"
    echo ""

    # 调用 deploy.sh 中的主部署函数
    deploy_site_from_repo "$repo_url" "$custom_domain"
}

# ── 设置 NPM 登录凭据（一键部署的前提） ─────────────────────────────
cmd_npm_login() {
    check_root
    npm_setup_credentials
}

# ── 从 Git 仓库部署站点（旧版兼容，保留交互式流程） ────────────────
cmd_deploy_from_git() {
    check_root
    echo ""
    echo -e "${CYAN}提示: 如果仓库包含 manus.config.json，建议使用 ${GREEN}manus deploy${CYAN} 命令实现全自动化部署${NC}"
    echo ""
    echo -e "${YELLOW}请输入 Git 仓库地址（例如: https://github.com/user/repo.git）:${NC} \c"
    read -r GIT_URL

    echo -e "${YELLOW}请输入网站域名:${NC} \c"
    read -r DOMAIN
    DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/^https\?:\/\///' | sed 's/\/$//')

    if ! validate_domain "$DOMAIN"; then
        log_error "域名格式不正确"
        return 1
    fi

    echo -e "${WHITE}请选择网站类型：${NC}"
    echo "  1) 静态网站"
    echo "  2) Node.js 应用"
    echo "  3) PHP 应用"
    echo -e "${YELLOW}请输入选项 [1-3]:${NC} \c"
    read -r SITE_TYPE_NUM

    case "$SITE_TYPE_NUM" in
        1) SITE_TYPE="static" ;;
        2) SITE_TYPE="nodejs" ;;
        3) SITE_TYPE="php" ;;
        *) log_error "无效选项"; return 1 ;;
    esac

    local site_dir="/opt/sites/${DOMAIN}"

    log_step "克隆代码仓库..."
    if [ -d "$site_dir" ]; then
        log_warn "目录已存在，将更新代码"
        cd "$site_dir"
        git pull 2>/dev/null || true
    else
        git clone "$GIT_URL" "$site_dir"
    fi

    if [ -f "${site_dir}/docker-compose.yml" ]; then
        log_info "检测到仓库中的 docker-compose.yml，直接使用"
        cd "$site_dir"
        docker compose up -d --build
    else
        NEED_DB=false
        if [ "$SITE_TYPE" != "static" ]; then
            if confirm "是否创建独立数据库？"; then
                NEED_DB=true
            fi
        fi
        deploy_site "$DOMAIN" "$SITE_TYPE" "$NEED_DB"
    fi

    register_site "$DOMAIN" "$SITE_TYPE" "auto"
    log_success "从 Git 仓库部署完成: $DOMAIN"
}

# ── 按需安装 MySQL ───────────────────────────────────────────────────────────
cmd_install_mysql() {
    check_root
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q 'manus-mysql'; then
        log_info "MySQL 已安装，当前状态:"
        docker ps --filter name=manus-mysql --format "  {{.Names}}\t{{.Status}}"
        return 0
    fi
    log_info "正在安装 MySQL 8.0（首次初始化约需 60-90 秒）..."
    deploy_mysql
}

# ── 按需安装 Portainer ───────────────────────────────────────────────────────
cmd_install_portainer() {
    check_root
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q 'portainer'; then
        log_info "Portainer 已安装，当前状态:"
        docker ps --filter name=portainer --format "  {{.Names}}\t{{.Status}}"
        return 0
    fi
    log_info "正在安装 Portainer..."
    deploy_portainer
}

# =============================================================================
# 交互式主菜单
# =============================================================================
show_main_menu() {
    while true; do
        clear
        print_banner
        # 显示简要系统状态
        local mem_used mem_total disk_used disk_pct
        mem_used=$(free -m | awk 'NR==2{print $3}')
        mem_total=$(free -m | awk 'NR==2{print $2}')
        disk_used=$(df -h / | awk 'NR==2{print $3}')
        disk_pct=$(df -h / | awk 'NR==2{print $5}')
        local site_count
        site_count=$(grep -c '|' /opt/manus/sites.conf 2>/dev/null || echo 0)
        echo -e "  ${CYAN}内存: ${WHITE}${mem_used}M/${mem_total}M${NC}  ${CYAN}磁盘: ${WHITE}${disk_used} (${disk_pct})${NC}  ${CYAN}站点: ${WHITE}${site_count} 个${NC}"
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║               网站管理                               ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
        echo -e "  ${GREEN}1${NC}  ★ 一键部署网站     — 从 GitHub 仓库全自动完成"
        echo -e "  ${GREEN}2${NC}  手动部署网站       — 交互式逐步配置"
        echo -e "  ${GREEN}3${NC}  查看所有站点"
        echo -e "  ${GREEN}4${NC}  网站健康监控"
        echo -e "  ${CYAN}5${NC}  启动/停止/重启站点"
        echo -e "  ${CYAN}6${NC}  更新站点（重新构建）"
        echo -e "  ${CYAN}7${NC}  查看站点日志"
        echo -e "  ${CYAN}8${NC}  备份管理"
        echo -e "  ${CYAN}9${NC}  删除站点"
        echo -e "  ${CYAN}10${NC} 克隆/迁移站点"
        echo -e "  ${CYAN}11${NC} 批量操作"
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║               服务器管理                             ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
        echo -e "  ${YELLOW}21${NC} 系统信息面板"
        echo -e "  ${YELLOW}22${NC} Docker 管理中心"
        echo -e "  ${YELLOW}23${NC} 网络工具 (BBR/DNS/Swap)"
        echo -e "  ${YELLOW}24${NC} 系统工具 (更新/清理/时区)"
        echo -e "  ${YELLOW}25${NC} SSL 证书到期检查"
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║               工具                                   ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
        echo -e "  ${BLUE}31${NC} 设置 NPM 登录凭据"
        echo -e "  ${BLUE}32${NC} GitHub 私有仓库配置"
        echo -e "  ${BLUE}33${NC} 限制管理面板访问 IP"
        echo -e "  ${BLUE}34${NC} 更新 manus 脚本自身"
        echo -e "  ${BLUE}35${NC} 安装 MySQL（按需）"
        echo -e "  ${BLUE}36${NC} 安装 Portainer（按需）"
        echo -e "  ${RED}0${NC}  退出"
        echo ""
        echo -e "${YELLOW}请输入选项:${NC} \c"
        read -r choice

        case "$choice" in
            1)  cmd_deploy ;;
            2)  cmd_add ;;
            3)  cmd_list ;;
            4)  monitor_sites; read -rp "按回车键继续..." ;;
            5)  _site_control_menu ;;
            6)  cmd_update ;;
            7)  cmd_logs ;;
            8)  cmd_backup ;;
            9)  cmd_remove ;;
            10) _clone_migrate_menu ;;
            11) batch_sites_operation ;;
            21) show_sysinfo; show_sites_status; read -rp "按回车键继续..." ;;
            22) docker_main_menu ;;
            23) network_main_menu ;;
            24) system_tools_menu ;;
            25) check_ssl_expiry; read -rp "按回车键继续..." ;;
            31) cmd_npm_login ;;
            32) manage_github_token; read -rp "按回车键继续..." ;;
            33) restrict_admin_ports "${2:-}"; read -rp "按回车键继续..." ;;
            34) self_update; read -rp "按回车键继续..." ;;
            35) cmd_install_mysql; read -rp "按回车键继续..." ;;
            36) cmd_install_portainer; read -rp "按回车键继续..." ;;
            0)  echo "再见！"; exit 0 ;;
            *)  log_warn "无效选项，请重新输入" ;;
        esac
    done
}

# ── 站点控制子菜单 ────────────────────────────────────────────────────────────
_site_control_menu() {
    clear
    echo -e "${CYAN}站点控制${NC}"
    echo ""
    echo "  1. 启动站点"
    echo "  2. 停止站点"
    echo "  3. 重启站点"
    echo "  0. 返回"
    echo ""
    read -rp "请输入选择: " choice
    case "$choice" in
        1) cmd_start ;;
        2) cmd_stop ;;
        3) cmd_restart ;;
        0) return ;;
    esac
}

# ── 克隆/迁移子菜单 ──────────────────────────────────────────────────────────
_clone_migrate_menu() {
    clear
    echo -e "${CYAN}克隆 / 迁移站点${NC}"
    echo ""
    echo "  1. 克隆站点（同服务器复制到新域名）"
    echo "  2. 迁移站点（跨服务器导出/导入）"
    echo "  0. 返回"
    echo ""
    read -rp "请输入选择: " choice
    case "$choice" in
        1) clone_site ;;
        2) migrate_site ;;
        0) return ;;
    esac
    read -rp "按回车键继续..."
}

# =============================================================================
# 命令行参数解析
# =============================================================================
show_help() {
    print_banner
    echo -e "${WHITE}用法: manus [命令] [参数]${NC}"
    echo ""
    echo -e "${WHITE}命令列表：${NC}"
    echo -e "${CYAN}── 核心命令 ───────────────────────────────────────────────${NC}"
    printf "  ${GREEN}%-22s${NC} %s\n" "deploy <仓库地址>" "★ 一键部署：自动完成容器+NPM代理+SSL"
    printf "  ${GREEN}%-22s${NC} %s\n" "npm-login"          "设置 NPM 凭据（一键部署前需要运行一次）"
    printf "  %-22s %s\n" "add"               "手动部署新网站（交互式）"
    printf "  %-22s %s\n" "git"               "从 Git 仓库部署（旧版交互式）"
    echo ""
    echo -e "${CYAN}── 站点管理 ───────────────────────────────────────────────${NC}"
    printf "  %-22s %s\n" "list"              "查看所有已部署站点"
    printf "  %-22s %s\n" "status"            "系统状态总览"
    printf "  %-22s %s\n" "start <域名>"     "启动指定站点"
    printf "  %-22s %s\n" "stop <域名>"      "停止指定站点"
    printf "  %-22s %s\n" "restart <域名>"   "重启指定站点"
    printf "  %-22s %s\n" "update <域名>"    "更新指定站点（重新构建）"
    printf "  %-22s %s\n" "logs <域名>"      "查看站点实时日志"
    printf "  %-22s %s\n" "backup [域名]"    "备份站点（不指定则备份全部）"
    printf "  %-22s %s\n" "remove <域名>"    "删除站点"
    printf "  %-22s %s\n" "restrict-admin <IP>" "限制管理面板访问 IP"
    printf "  %-22s %s\n" "self-update"        "更新 manus 工具自身"
    printf "  %-22s %s\n" "help"               "显示此帮助信息"
    echo ""
    echo -e "${WHITE}直接运行 ${GREEN}manus${WHITE} 进入交互式菜单${NC}"
    echo ""
}

# ── 入口 ─────────────────────────────────────────────────────────────────────
case "${1:-}" in
    deploy)      cmd_deploy "${2:-}" "${3:-}" ;;
    npm-login)   cmd_npm_login ;;
    add)         cmd_add ;;
    git)         cmd_deploy_from_git ;;
    list)        cmd_list ;;
    status)      cmd_status ;;
    start)       cmd_start "${2:-}" ;;
    stop)        cmd_stop "${2:-}" ;;
    restart)     cmd_restart "${2:-}" ;;
    update)      cmd_update "${2:-}" ;;
    logs)        cmd_logs "${2:-}" ;;
    backup)      cmd_backup "${2:-}" ;;
    remove|rm|delete) cmd_remove "${2:-}" ;;
    restrict-admin)   restrict_admin_ports "${2:-}" ;;
    self-update|update-self) self_update ;;
    sysinfo|info)    show_sysinfo; show_sites_status ;;
    docker)          docker_main_menu ;;
    network|net)     network_main_menu ;;
    system|sys)      system_tools_menu ;;
    ssl-check)       check_ssl_expiry ;;
    github-token)    manage_github_token ;;
    clone)           clone_site ;;
    migrate)         migrate_site ;;
    monitor)         monitor_sites ;;
    batch)           batch_sites_operation ;;
    install-mysql)   cmd_install_mysql ;;
    install-portainer) cmd_install_portainer ;;
    help|--help|-h)  show_help ;;
    "")              show_main_menu ;;
    *)
        log_error "未知命令: $1"
        show_help
        exit 1
        ;;
esac
