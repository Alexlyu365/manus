#!/bin/bash
# =============================================================================
# site_mgr.sh — 网站高级管理函数库
# 补充功能：私有仓库部署、网站克隆/迁移、批量操作、网站状态监控
# =============================================================================

# ── 私有仓库部署（带 Token 支持）────────────────────────────────────────────
deploy_private_repo() {
    local repo_url="$1"
    local token_file="/opt/manus/.github_token"

    # 如果是私有仓库且有 Token，注入认证信息
    if [ -f "$token_file" ] && [[ "$repo_url" =~ github\.com ]]; then
        local token
        token=$(cat "$token_file")
        # 将 https://github.com/... 转换为 https://TOKEN@github.com/...
        repo_url=$(echo "$repo_url" | sed "s|https://github.com|https://${token}@github.com|")
    fi

    echo "$repo_url"
}

# ── 网站克隆（同服务器复制一个站点到新域名）────────────────────────────────
clone_site() {
    clear
    echo -e "${CYAN}网站克隆${NC}"
    echo ""
    echo "  此功能将复制一个现有站点的所有文件和配置到新域名。"
    echo ""

    local sites_conf="/opt/manus/sites.conf"
    if [ ! -f "$sites_conf" ] || [ ! -s "$sites_conf" ]; then
        log_warn "没有可克隆的站点"
        return
    fi

    # 显示现有站点
    echo "  现有站点:"
    local i=1
    while IFS='|' read -r domain _rest; do
        [ -z "$domain" ] && continue
        echo "  ${i}. ${domain}"
        ((i++))
    done < "$sites_conf"
    echo ""

    read -rp "  输入源域名: " src_domain
    read -rp "  输入新域名: " new_domain

    [ -z "$src_domain" ] || [ -z "$new_domain" ] && { log_error "域名不能为空"; return; }

    local src_dir="/opt/manus/sites/${src_domain}"
    local new_dir="/opt/manus/sites/${new_domain}"

    if [ ! -d "$src_dir" ]; then
        log_error "源站点目录不存在: ${src_dir}"
        return
    fi

    if [ -d "$new_dir" ]; then
        log_error "目标目录已存在: ${new_dir}"
        return
    fi

    log_step "克隆站点 ${src_domain} → ${new_domain}..."

    # 复制站点目录
    cp -r "$src_dir" "$new_dir"

    # 替换配置文件中的域名
    find "$new_dir" -type f \( -name "*.yml" -o -name "*.conf" -o -name "*.env" -o -name "*.json" \) | \
    while read -r file; do
        sed -i "s/${src_domain}/${new_domain}/g" "$file" 2>/dev/null
    done

    # 修改 docker-compose.yml 中的容器名和端口（避免冲突）
    local new_safe
    new_safe=$(echo "$new_domain" | tr '.' '_' | tr '-' '_')
    local src_safe
    src_safe=$(echo "$src_domain" | tr '.' '_' | tr '-' '_')

    if [ -f "${new_dir}/docker-compose.yml" ]; then
        sed -i "s/container_name: ${src_safe}/container_name: ${new_safe}/g" "${new_dir}/docker-compose.yml"
        sed -i "s/name: manus_${src_safe}/name: manus_${new_safe}/g" "${new_dir}/docker-compose.yml"
    fi

    # 启动新站点
    log_step "启动新站点..."
    cd "$new_dir" && docker compose up -d 2>/dev/null

    # 注册到 sites.conf
    local src_type src_repo src_date
    src_type=$(grep "^${src_domain}|" "$sites_conf" | cut -d'|' -f3)
    src_repo=$(grep "^${src_domain}|" "$sites_conf" | cut -d'|' -f4)
    echo "${new_domain}|${new_safe}|${src_type:-static}|${src_repo}|$(date +%Y-%m-%d)" >> "$sites_conf"

    log_success "站点克隆完成！"
    echo ""
    echo "  请在 Nginx Proxy Manager (http://服务器IP:81) 中为 ${new_domain} 添加代理规则"
}

# ── 网站迁移（从另一台服务器迁移站点）──────────────────────────────────────
migrate_site() {
    clear
    echo -e "${CYAN}网站迁移（从其他服务器导入）${NC}"
    echo ""
    echo "  此功能将从另一台服务器迁移站点文件和数据库。"
    echo ""
    echo "  1. 导出当前站点（打包备份）"
    echo "  2. 导入站点（从备份包恢复）"
    echo "  0. 返回"
    echo ""
    read -rp "请输入选择: " choice

    case "$choice" in
        1)
            _export_site
            ;;
        2)
            _import_site
            ;;
        0) return ;;
    esac
}

_export_site() {
    local sites_conf="/opt/manus/sites.conf"
    if [ ! -f "$sites_conf" ] || [ ! -s "$sites_conf" ]; then
        log_warn "没有可导出的站点"
        return
    fi

    echo ""
    echo "  现有站点:"
    cat -n "$sites_conf" | awk -F'|' '{print "  "$1". "$2}' | head -20
    echo ""
    read -rp "  输入要导出的域名: " domain
    [ -z "$domain" ] && return

    local site_dir="/opt/manus/sites/${domain}"
    if [ ! -d "$site_dir" ]; then
        log_error "站点目录不存在"
        return
    fi

    local export_file="/opt/manus/backups/${domain}_export_$(date +%Y%m%d_%H%M%S).tar.gz"
    mkdir -p /opt/manus/backups

    log_step "打包站点文件..."

    # 停止容器（确保数据一致性）
    cd "$site_dir" && docker compose stop 2>/dev/null

    # 导出数据库（如果有）
    local db_name
    db_name=$(grep "^${domain}|" "$sites_conf" | cut -d'|' -f2 | tr '.' '_' | tr '-' '_')
    local db_file="${site_dir}/db_export.sql"
    if docker ps | grep -q "manus_mysql" 2>/dev/null; then
        log_step "导出数据库 ${db_name}..."
        docker exec manus_mysql mysqldump -u root \
            -p"$(cat /opt/manus/.mysql_root_password 2>/dev/null)" \
            "$db_name" > "$db_file" 2>/dev/null && \
            log_success "数据库导出完成" || log_warn "数据库导出失败（可能无数据库）"
    fi

    # 打包
    tar -czf "$export_file" -C /opt/manus/sites "$domain" 2>/dev/null
    # 附加 sites.conf 中该站点的记录
    grep "^${domain}|" "$sites_conf" > "${site_dir}/.manus_site_meta" 2>/dev/null
    tar -rf "$export_file" -C /opt/manus/sites "${domain}/.manus_site_meta" 2>/dev/null

    # 重启容器
    cd "$site_dir" && docker compose start 2>/dev/null

    # 清理临时文件
    rm -f "$db_file" "${site_dir}/.manus_site_meta"

    log_success "站点已导出: ${export_file}"
    echo ""
    echo "  文件大小: $(du -sh "$export_file" | cut -f1)"
    echo "  将此文件传输到新服务器后，使用 'manus migrate' → '导入站点' 恢复"
}

_import_site() {
    read -rp "  备份文件路径: " backup_file
    [ -f "$backup_file" ] || { log_error "文件不存在: ${backup_file}"; return; }

    log_step "解压站点备份..."
    local temp_dir="/tmp/manus_import_$(date +%s)"
    mkdir -p "$temp_dir"
    tar -xzf "$backup_file" -C "$temp_dir" 2>/dev/null

    # 检测域名
    local domain
    domain=$(ls "$temp_dir" | head -1)
    if [ -z "$domain" ]; then
        log_error "备份文件格式不正确"
        rm -rf "$temp_dir"
        return
    fi

    log_info "检测到站点: ${domain}"
    read -rp "  使用此域名？(Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        read -rp "  输入新域名: " domain
    fi

    local site_dir="/opt/manus/sites/${domain}"
    if [ -d "$site_dir" ]; then
        log_warn "目标目录已存在，将覆盖"
        if ! confirm "确认覆盖？"; then
            rm -rf "$temp_dir"
            return
        fi
        cd "$site_dir" && docker compose down 2>/dev/null
    fi

    # 复制文件
    mkdir -p /opt/manus/sites
    cp -r "${temp_dir}/$(ls "$temp_dir" | head -1)" "$site_dir"

    # 导入数据库
    local db_file="${site_dir}/db_export.sql"
    if [ -f "$db_file" ] && docker ps | grep -q "manus_mysql" 2>/dev/null; then
        local db_name
        db_name=$(echo "$domain" | tr '.' '_' | tr '-' '_')
        log_step "导入数据库 ${db_name}..."
        docker exec -i manus_mysql mysql -u root \
            -p"$(cat /opt/manus/.mysql_root_password 2>/dev/null)" \
            -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\`;" 2>/dev/null
        docker exec -i manus_mysql mysql -u root \
            -p"$(cat /opt/manus/.mysql_root_password 2>/dev/null)" \
            "$db_name" < "$db_file" 2>/dev/null && \
            log_success "数据库导入完成" || log_warn "数据库导入失败"
        rm -f "$db_file"
    fi

    # 启动容器
    log_step "启动站点容器..."
    cd "$site_dir" && docker compose up -d 2>/dev/null

    # 注册到 sites.conf
    local meta_file="${site_dir}/.manus_site_meta"
    if [ -f "$meta_file" ]; then
        cat "$meta_file" >> /opt/manus/sites.conf
        rm -f "$meta_file"
    else
        local safe_name
        safe_name=$(echo "$domain" | tr '.' '_' | tr '-' '_')
        echo "${domain}|${safe_name}|static||$(date +%Y-%m-%d)" >> /opt/manus/sites.conf
    fi

    rm -rf "$temp_dir"
    log_success "站点导入完成！"
    echo ""
    echo "  请在 Nginx Proxy Manager (http://服务器IP:81) 中为 ${domain} 添加代理规则"
}

# ── 批量操作 ──────────────────────────────────────────────────────────────────
batch_sites_operation() {
    clear
    echo -e "${CYAN}批量站点操作${NC}"
    echo ""
    echo "  1. 启动所有站点"
    echo "  2. 停止所有站点"
    echo "  3. 重启所有站点"
    echo "  4. 更新所有站点（重新拉取 GitHub 代码）"
    echo "  5. 备份所有站点"
    echo "  0. 返回"
    echo ""
    read -rp "请输入选择: " choice

    local sites_conf="/opt/manus/sites.conf"
    [ -f "$sites_conf" ] || { log_warn "没有托管的站点"; return; }

    case "$choice" in
        1|2|3)
            local action
            case "$choice" in
                1) action="up -d" ;;
                2) action="down" ;;
                3) action="restart" ;;
            esac
            while IFS='|' read -r domain _rest; do
                [ -z "$domain" ] && continue
                local site_dir="/opt/manus/sites/${domain}"
                if [ -d "$site_dir" ]; then
                    log_step "${domain}..."
                    cd "$site_dir" && docker compose $action 2>/dev/null && \
                        log_success "${domain} 操作完成" || log_warn "${domain} 操作失败"
                fi
            done < "$sites_conf"
            ;;
        4)
            while IFS='|' read -r domain _container _type repo _date; do
                [ -z "$domain" ] || [ -z "$repo" ] && continue
                local site_dir="/opt/manus/sites/${domain}"
                if [ -d "${site_dir}/.git" ]; then
                    log_step "更新 ${domain}..."
                    cd "$site_dir" && git pull origin main 2>/dev/null && \
                        docker compose up -d --build 2>/dev/null && \
                        log_success "${domain} 更新完成" || log_warn "${domain} 更新失败"
                fi
            done < "$sites_conf"
            ;;
        5)
            if declare -f backup_all_sites &>/dev/null; then
                backup_all_sites
            else
                log_warn "备份功能未加载"
            fi
            ;;
        0) return ;;
    esac
    read -rp "按回车键继续..."
}

# ── 网站健康监控 ──────────────────────────────────────────────────────────────
monitor_sites() {
    clear
    echo -e "${CYAN}网站健康监控${NC}"
    echo ""

    local sites_conf="/opt/manus/sites.conf"
    if [ ! -f "$sites_conf" ] || [ ! -s "$sites_conf" ]; then
        log_warn "没有托管的站点"
        return
    fi

    printf "  %-35s %-12s %-12s %s\n" "域名" "HTTP状态" "响应时间" "容器状态"
    echo "  ──────────────────────────────────────────────────────────────"

    while IFS='|' read -r domain container _rest; do
        [ -z "$domain" ] && continue

        # 检查 HTTP 状态
        local http_status response_time
        http_status=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "https://${domain}" 2>/dev/null || \
                      curl -o /dev/null -s -w "%{http_code}" --max-time 5 "http://${domain}" 2>/dev/null || \
                      echo "000")
        response_time=$(curl -o /dev/null -s -w "%{time_total}" --max-time 5 "https://${domain}" 2>/dev/null || echo "N/A")

        # 检查容器状态
        local container_status
        if docker ps --filter "name=${container}" --filter "status=running" | grep -q "$container" 2>/dev/null; then
            container_status="${GREEN}运行中${NC}"
        else
            container_status="${RED}已停止${NC}"
        fi

        # HTTP 状态颜色
        local http_colored
        if [[ "$http_status" =~ ^2 ]]; then
            http_colored="${GREEN}${http_status}${NC}"
        elif [[ "$http_status" =~ ^3 ]]; then
            http_colored="${YELLOW}${http_status}${NC}"
        elif [ "$http_status" = "000" ]; then
            http_colored="${RED}无法连接${NC}"
        else
            http_colored="${RED}${http_status}${NC}"
        fi

        printf "  %-35s " "$domain"
        echo -ne "$(echo -e "${http_colored}")"
        printf "       %-12s " "${response_time}s"
        echo -e "$(echo -e "${container_status}")"

    done < "$sites_conf"
    echo ""
}
