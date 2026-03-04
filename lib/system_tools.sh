#!/bin/bash
# =============================================================================
# system_tools.sh — 系统工具函数库
# 对标 kejilion.sh：系统更新、清理、时区设置、一键自我更新、私有仓库支持
# =============================================================================

# ── 系统更新 ──────────────────────────────────────────────────────────────────
system_update() {
    clear
    log_step "开始系统更新..."
    echo ""

    # 更新软件包列表
    log_step "更新软件包列表..."
    apt-get update -y 2>&1 | tail -3

    # 升级已安装软件包
    log_step "升级软件包..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y 2>&1 | tail -5

    # 升级发行版（可选）
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y 2>&1 | tail -3

    log_success "系统更新完成"

    # 检查是否需要重启
    if [ -f /var/run/reboot-required ]; then
        log_warn "系统更新后需要重启才能完全生效"
        read -rp "是否现在重启？(y/N): " reboot_choice
        if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
            log_info "10 秒后重启..."
            sleep 10
            reboot
        fi
    fi
}

# ── 系统清理 ──────────────────────────────────────────────────────────────────
system_clean() {
    clear
    log_step "开始系统清理..."
    echo ""

    # 清理 apt 缓存
    log_step "清理 apt 缓存..."
    apt-get autoremove -y 2>/dev/null | tail -2
    apt-get autoclean -y 2>/dev/null | tail -2
    apt-get clean 2>/dev/null

    # 清理日志（保留最近 7 天）
    log_step "清理旧日志文件..."
    journalctl --vacuum-time=7d 2>/dev/null | tail -2
    find /var/log -name "*.gz" -mtime +7 -delete 2>/dev/null
    find /var/log -name "*.1" -mtime +7 -delete 2>/dev/null

    # 清理临时文件
    log_step "清理临时文件..."
    rm -rf /tmp/* 2>/dev/null
    rm -rf /var/tmp/* 2>/dev/null

    # 清理 Docker 无用资源
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        log_step "清理 Docker 无用资源..."
        docker system prune -f 2>/dev/null | tail -2
    fi

    # 显示清理后磁盘状态
    echo ""
    log_success "系统清理完成"
    echo ""
    echo -e "  清理后磁盘状态:"
    df -h / | sed 's/^/  /'
}

# ── 时区设置 ──────────────────────────────────────────────────────────────────
set_timezone() {
    clear
    echo -e "${CYAN}时区设置${NC}"
    echo ""
    echo "  当前时区: $(timedatectl 2>/dev/null | awk '/Time zone/{print $3}' || date +%Z)"
    echo ""
    echo "  常用时区:"
    echo "  1. Asia/Shanghai    (北京/上海，UTC+8)"
    echo "  2. Asia/Hong_Kong   (香港，UTC+8)"
    echo "  3. Asia/Tokyo       (东京，UTC+9)"
    echo "  4. Asia/Singapore   (新加坡，UTC+8)"
    echo "  5. America/New_York (纽约，UTC-5/-4)"
    echo "  6. America/Los_Angeles (洛杉矶，UTC-8/-7)"
    echo "  7. Europe/London    (伦敦，UTC+0/+1)"
    echo "  8. UTC              (协调世界时)"
    echo "  9. 手动输入时区"
    echo "  0. 取消"
    echo ""
    read -rp "请输入选择: " choice

    local tz=""
    case "$choice" in
        1) tz="Asia/Shanghai" ;;
        2) tz="Asia/Hong_Kong" ;;
        3) tz="Asia/Tokyo" ;;
        4) tz="Asia/Singapore" ;;
        5) tz="America/New_York" ;;
        6) tz="America/Los_Angeles" ;;
        7) tz="Europe/London" ;;
        8) tz="UTC" ;;
        9)
            read -rp "输入时区 (如 Asia/Shanghai): " tz
            ;;
        0) return ;;
        *) log_warn "无效输入"; return ;;
    esac

    if timedatectl set-timezone "$tz" 2>/dev/null; then
        log_success "时区已设置为: ${tz}"
        echo "  当前时间: $(date)"
    else
        log_error "时区设置失败，请检查时区名称是否正确"
    fi
}

# ── manus 脚本自我更新 ────────────────────────────────────────────────────────
self_update() {
    clear
    echo -e "${CYAN}manus 脚本自我更新${NC}"
    echo ""

    local install_dir="/opt/manus"
    local github_repo="Alexlyu365/manus"
    local branch="main"

    # 检查 git 是否安装
    if ! command -v git &>/dev/null; then
        log_step "安装 git..."
        apt-get install -y git 2>/dev/null
    fi

    # 检查是否已有 git 仓库
    if [ -d "${install_dir}/.git" ]; then
        log_step "从 GitHub 拉取最新版本..."
        cd "$install_dir" || return 1

        # 保存本地配置（sites.conf、npm credentials 等）
        local config_backup="/tmp/manus_config_backup_$(date +%s)"
        mkdir -p "$config_backup"
        [ -f "${install_dir}/sites.conf" ] && cp "${install_dir}/sites.conf" "$config_backup/"
        [ -f "${install_dir}/.npm_credentials" ] && cp "${install_dir}/.npm_credentials" "$config_backup/"

        # 拉取更新
        git fetch origin "$branch" 2>&1 | tail -3
        local current_hash new_hash
        current_hash=$(git rev-parse HEAD)
        new_hash=$(git rev-parse "origin/${branch}")

        if [ "$current_hash" = "$new_hash" ]; then
            log_success "已是最新版本 ($(git log -1 --format='%h %s'))"
        else
            git reset --hard "origin/${branch}" 2>&1 | tail -2
            chmod +x "${install_dir}/manage.sh" 2>/dev/null
            chmod +x "${install_dir}/server-init.sh" 2>/dev/null
            find "${install_dir}/lib" -name "*.sh" -exec chmod +x {} \; 2>/dev/null

            # 恢复本地配置
            [ -f "${config_backup}/sites.conf" ] && cp "${config_backup}/sites.conf" "${install_dir}/"
            [ -f "${config_backup}/.npm_credentials" ] && cp "${config_backup}/.npm_credentials" "${install_dir}/"

            log_success "更新完成！"
            echo ""
            echo "  更新日志:"
            git log --oneline "${current_hash}..HEAD" | head -10 | sed 's/^/  /'
        fi
        rm -rf "$config_backup"
    else
        # 首次安装（从 GitHub 克隆）
        log_step "首次从 GitHub 克隆脚本..."
        local temp_dir="/tmp/manus_update_$(date +%s)"

        # 支持私有仓库（通过 GitHub Token）
        local clone_url
        if [ -f "${install_dir}/.github_token" ]; then
            local token
            token=$(cat "${install_dir}/.github_token")
            clone_url="https://${token}@github.com/${github_repo}.git"
        else
            clone_url="https://github.com/${github_repo}.git"
        fi

        git clone --depth=1 --branch "$branch" "$clone_url" "$temp_dir" 2>&1 | tail -3

        if [ -d "$temp_dir" ]; then
            # 保留现有配置
            [ -f "${install_dir}/sites.conf" ] && cp "${install_dir}/sites.conf" "/tmp/sites.conf.bak"

            rsync -a --exclude='.git' "$temp_dir/" "${install_dir}/" 2>/dev/null || \
                cp -r "$temp_dir/." "${install_dir}/"

            # 恢复配置
            [ -f "/tmp/sites.conf.bak" ] && cp "/tmp/sites.conf.bak" "${install_dir}/sites.conf"

            chmod +x "${install_dir}/manage.sh" 2>/dev/null
            find "${install_dir}/lib" -name "*.sh" -exec chmod +x {} \; 2>/dev/null
            rm -rf "$temp_dir"
            log_success "脚本安装完成"
        else
            log_error "克隆失败，请检查网络连接或 GitHub Token"
        fi
    fi
}

# ── 私有仓库 GitHub Token 管理 ────────────────────────────────────────────────
manage_github_token() {
    clear
    echo -e "${CYAN}GitHub 私有仓库访问配置${NC}"
    echo ""
    echo "  配置 GitHub Personal Access Token 后，可以部署私有仓库中的网站。"
    echo ""
    echo "  获取 Token 步骤："
    echo "  1. 访问 https://github.com/settings/tokens"
    echo "  2. 点击 'Generate new token (classic)'"
    echo "  3. 勾选 'repo' 权限"
    echo "  4. 复制生成的 Token"
    echo ""

    local token_file="/opt/manus/.github_token"

    if [ -f "$token_file" ]; then
        local current_token
        current_token=$(cat "$token_file")
        echo -e "  当前 Token: ${WHITE}${current_token:0:8}...${NC}（已配置）"
        echo ""
        echo "  1. 更新 Token"
        echo "  2. 删除 Token（恢复公开仓库模式）"
        echo "  0. 取消"
        echo ""
        read -rp "请输入选择: " choice
        case "$choice" in
            1) _save_github_token "$token_file" ;;
            2)
                rm -f "$token_file"
                log_success "GitHub Token 已删除"
                ;;
            0) return ;;
        esac
    else
        echo "  当前未配置 GitHub Token（只能部署公开仓库）"
        echo ""
        read -rp "是否现在配置 Token？(y/N): " choice
        [[ "$choice" =~ ^[Yy]$ ]] && _save_github_token "$token_file"
    fi
}

_save_github_token() {
    local token_file="$1"
    read -rsp "  请粘贴 GitHub Token (输入不显示): " token
    echo ""

    if [ -z "$token" ]; then
        log_warn "Token 不能为空"
        return
    fi

    # 验证 Token 格式（ghp_ 或 github_pat_ 开头）
    if [[ ! "$token" =~ ^(ghp_|github_pat_) ]]; then
        log_warn "Token 格式可能不正确，但仍将保存"
    fi

    mkdir -p "$(dirname "$token_file")"
    echo "$token" > "$token_file"
    chmod 600 "$token_file"

    # 配置 git credential helper
    git config --global credential.helper store 2>/dev/null
    echo "https://$(cat "$token_file")@github.com" > ~/.git-credentials 2>/dev/null
    chmod 600 ~/.git-credentials 2>/dev/null

    log_success "GitHub Token 已保存"
}

# ── SSL 证书到期检查 ──────────────────────────────────────────────────────────
check_ssl_expiry() {
    clear
    echo -e "${CYAN}SSL 证书到期检查${NC}"
    echo ""

    local sites_conf="/opt/manus/sites.conf"

    if [ ! -f "$sites_conf" ] || [ ! -s "$sites_conf" ]; then
        log_warn "没有托管的站点"
        return
    fi

    printf "  %-35s %-15s %s\n" "域名" "到期状态" "到期日期"
    echo "  ──────────────────────────────────────────────────────────"

    while IFS='|' read -r domain _rest; do
        [ -z "$domain" ] && continue

        # 查询 SSL 证书到期时间
        local expiry_date days_left status
        expiry_date=$(echo | timeout 5 openssl s_client -servername "$domain" \
            -connect "${domain}:443" 2>/dev/null | \
            openssl x509 -noout -enddate 2>/dev/null | \
            cut -d= -f2)

        if [ -z "$expiry_date" ]; then
            printf "  %-35s ${RED}%-15s${NC} %s\n" "$domain" "无法连接" "N/A"
            continue
        fi

        # 计算剩余天数
        local expiry_epoch now_epoch
        expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || \
                       date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null)
        now_epoch=$(date +%s)
        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        if [ "$days_left" -lt 0 ]; then
            status="${RED}已过期${NC}"
        elif [ "$days_left" -lt 14 ]; then
            status="${RED}${days_left}天后到期${NC}"
        elif [ "$days_left" -lt 30 ]; then
            status="${YELLOW}${days_left}天后到期${NC}"
        else
            status="${GREEN}${days_left}天后到期${NC}"
        fi

        local expiry_formatted
        expiry_formatted=$(date -d "$expiry_date" "+%Y-%m-%d" 2>/dev/null || echo "$expiry_date")
        printf "  %-35s " "$domain"
        echo -ne "$(echo -e "${status}")"
        printf "  %s\n" "$expiry_formatted"

    done < "$sites_conf"
    echo ""
    echo "  提示: SSL 证书由 Nginx Proxy Manager 自动续期，通常无需手动操作"
}

# ── 日志管理 ──────────────────────────────────────────────────────────────────
log_management() {
    while true; do
        clear
        echo -e "${CYAN}日志管理${NC}"
        echo ""

        # 显示日志占用
        local log_size
        log_size=$(du -sh /var/log 2>/dev/null | cut -f1)
        local journal_size
        journal_size=$(journalctl --disk-usage 2>/dev/null | awk '{print $7}')
        echo -e "  /var/log 占用: ${WHITE}${log_size}${NC}"
        echo -e "  systemd 日志: ${WHITE}${journal_size}${NC}"
        echo ""

        echo "  1. 查看系统日志 (最近50行)"
        echo "  2. 查看 Docker 日志"
        echo "  3. 查看 Nginx 日志"
        echo "  4. 清理旧日志 (保留7天)"
        echo "  5. 清理 systemd 日志 (保留3天)"
        echo "  6. 设置日志自动轮转"
        echo "────────────────────────────────────────────────────"
        echo "  0. 返回上一级"
        echo "────────────────────────────────────────────────────"
        read -rp "请输入选择: " choice
        case "$choice" in
            1)
                journalctl -n 50 --no-pager 2>/dev/null | less
                ;;
            2)
                read -rp "容器名称 (留空查看所有): " cname
                if [ -z "$cname" ]; then
                    docker ps --format "{{.Names}}" 2>/dev/null | while read -r c; do
                        echo "=== $c ==="
                        docker logs --tail 20 "$c" 2>/dev/null
                    done | less
                else
                    docker logs --tail 100 -f "$cname" 2>/dev/null
                fi
                ;;
            3)
                local npm_container
                npm_container=$(docker ps --filter "name=nginx-proxy-manager" --format "{{.Names}}" 2>/dev/null | head -1)
                if [ -n "$npm_container" ]; then
                    docker logs --tail 100 "$npm_container" 2>/dev/null | less
                else
                    log_warn "Nginx Proxy Manager 容器未运行"
                fi
                ;;
            4)
                find /var/log -name "*.gz" -mtime +7 -delete 2>/dev/null
                find /var/log -name "*.1" -mtime +7 -delete 2>/dev/null
                log_success "已清理 7 天前的旧日志"
                ;;
            5)
                journalctl --vacuum-time=3d 2>/dev/null
                log_success "systemd 日志已清理（保留3天）"
                ;;
            6)
                cat > /etc/logrotate.d/manus << 'EOF'
/opt/manus/logs/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF
                log_success "日志自动轮转已配置（每日轮转，保留7天）"
                ;;
            0) break ;;
            *) log_warn "无效输入" ;;
        esac
        read -rp "按回车键继续..."
    done
}

# ── 系统工具主菜单 ────────────────────────────────────────────────────────────
system_tools_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║                  系统工具中心                        ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "  1. 系统更新"
        echo "  2. 系统清理"
        echo "  3. 时区设置"
        echo "  4. SSL 证书到期检查"
        echo "  5. 日志管理"
        echo "  6. GitHub 私有仓库配置"
        echo "  7. 更新 manus 脚本自身"
        echo "────────────────────────────────────────────────────"
        echo "  0. 返回主菜单"
        echo "────────────────────────────────────────────────────"
        read -rp "请输入选择: " choice
        case "$choice" in
            1) system_update; read -rp "按回车键继续..." ;;
            2) system_clean; read -rp "按回车键继续..." ;;
            3) set_timezone; read -rp "按回车键继续..." ;;
            4) check_ssl_expiry; read -rp "按回车键继续..." ;;
            5) log_management ;;
            6) manage_github_token; read -rp "按回车键继续..." ;;
            7) self_update; read -rp "按回车键继续..." ;;
            0) break ;;
            *) log_warn "无效输入" ;;
        esac
    done
}
