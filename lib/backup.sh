#!/bin/bash
# =============================================================================
# backup.sh — 备份与恢复函数库
# 项目: manus-deploy
# =============================================================================

BACKUP_DIR="/opt/manus/backups"
BACKUP_KEEP_DAYS=7   # 保留最近 7 天的备份

# ── 创建备份目录 ─────────────────────────────────────────────────────────────
init_backup_dir() {
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
}

# ── 备份单个站点 ─────────────────────────────────────────────────────────────
backup_site() {
    local domain="$1"
    local site_dir="/opt/sites/${domain}"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="${BACKUP_DIR}/${domain}_${timestamp}.tar.gz"

    if [ ! -d "$site_dir" ]; then
        log_error "站点目录不存在: $site_dir"
        return 1
    fi

    log_step "备份站点: ${domain}..."

    # 备份站点文件
    tar -czf "$backup_file" -C /opt/sites "$domain" 2>/dev/null

    # 备份数据库（如果存在）
    if [ -f "${site_dir}/.db_info" ]; then
        source "${site_dir}/.db_info"
        local root_pass
        root_pass=$(cat /opt/manus/.mysql_root_pass 2>/dev/null)
        if [ -n "$root_pass" ]; then
            local db_backup="${BACKUP_DIR}/${domain}_db_${timestamp}.sql.gz"
            docker exec manus-mysql mysqldump \
                -u root -p"${root_pass}" \
                --single-transaction \
                --routines \
                --triggers \
                "$DB_NAME" 2>/dev/null | gzip > "$db_backup"
            log_info "数据库备份: $db_backup"
        fi
    fi

    log_success "站点 ${domain} 备份完成: $backup_file"
    echo "$backup_file"
}

# ── 备份所有站点 ─────────────────────────────────────────────────────────────
backup_all_sites() {
    log_step "备份所有站点..."
    init_backup_dir

    if [ ! -f "$SITES_REGISTRY" ] || [ ! -s "$SITES_REGISTRY" ]; then
        log_warn "没有已注册的站点"
        return
    fi

    local count=0
    while IFS='|' read -r domain _rest; do
        backup_site "$domain" && count=$((count + 1))
    done < "$SITES_REGISTRY"

    # 备份 NPM 配置
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    tar -czf "${BACKUP_DIR}/npm_config_${timestamp}.tar.gz" \
        -C /opt/manus/nginx-proxy-manager data 2>/dev/null
    log_info "Nginx Proxy Manager 配置已备份"

    log_success "所有站点备份完成，共 ${count} 个站点"

    # 清理旧备份
    cleanup_old_backups
}

# ── 清理旧备份 ───────────────────────────────────────────────────────────────
cleanup_old_backups() {
    log_info "清理 ${BACKUP_KEEP_DAYS} 天前的旧备份..."
    find "$BACKUP_DIR" -name "*.tar.gz" -mtime "+${BACKUP_KEEP_DAYS}" -delete 2>/dev/null
    find "$BACKUP_DIR" -name "*.sql.gz" -mtime "+${BACKUP_KEEP_DAYS}" -delete 2>/dev/null
    log_info "旧备份清理完成"
}

# ── 列出备份文件 ─────────────────────────────────────────────────────────────
list_backups() {
    local domain="${1:-}"

    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        echo "（暂无备份文件）"
        return
    fi

    echo ""
    printf "%-60s %-12s %-20s\n" "文件名" "大小" "时间"
    print_line

    if [ -n "$domain" ]; then
        ls -lt "${BACKUP_DIR}/${domain}"*.tar.gz "${BACKUP_DIR}/${domain}"*.sql.gz 2>/dev/null \
            | awk '{printf "%-60s %-12s %-20s\n", $9, $5, $6" "$7" "$8}'
    else
        ls -lt "${BACKUP_DIR}"/*.tar.gz "${BACKUP_DIR}"/*.sql.gz 2>/dev/null \
            | awk '{printf "%-60s %-12s %-20s\n", $9, $5, $6" "$7" "$8}'
    fi
}

# ── 恢复站点 ─────────────────────────────────────────────────────────────────
restore_site() {
    local backup_file="$1"

    if [ ! -f "$backup_file" ]; then
        log_error "备份文件不存在: $backup_file"
        return 1
    fi

    log_step "从备份恢复: $backup_file"

    # 解压到 /opt/sites
    tar -xzf "$backup_file" -C /opt/sites 2>/dev/null

    log_success "站点文件恢复完成"
    log_warn "请手动在 Nginx Proxy Manager 中重新配置代理规则"
}

# ── 设置自动备份定时任务 ─────────────────────────────────────────────────────
setup_auto_backup() {
    log_step "配置自动备份定时任务（每天凌晨 3:00）..."

    # 写入 cron 任务
    local cron_cmd="0 3 * * * /opt/manus/scripts/backup-all.sh >> /var/log/manus-backup.log 2>&1"

    # 创建备份执行脚本
    mkdir -p /opt/manus/scripts
    cat > /opt/manus/scripts/backup-all.sh << 'SCRIPT'
#!/bin/bash
source /opt/manus/lib/common.sh
source /opt/manus/lib/docker.sh
source /opt/manus/lib/backup.sh
detect_os
backup_all_sites
SCRIPT
    chmod +x /opt/manus/scripts/backup-all.sh

    # 添加到 crontab（避免重复）
    (crontab -l 2>/dev/null | grep -v "backup-all.sh"; echo "$cron_cmd") | crontab -

    log_success "自动备份已配置，每天凌晨 3:00 执行"
}
