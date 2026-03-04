#!/bin/bash
# =============================================================================
# firewall.sh — UFW 防火墙配置函数库
# 项目: manus-deploy
# =============================================================================

# ── 安装并配置 UFW 防火墙 ────────────────────────────────────────────────────
setup_firewall() {
    log_step "配置 UFW 防火墙..."

    # 安装 UFW
    if ! command_exists ufw; then
        $PKG_INSTALL ufw
    fi

    # 重置为默认规则
    ufw --force reset

    # 默认策略：拒绝入站，允许出站
    ufw default deny incoming
    ufw default allow outgoing

    # ── 必要端口 ──────────────────────────────────────────────────────────────
    ufw allow 22/tcp    comment 'SSH'
    ufw allow 80/tcp    comment 'HTTP'
    ufw allow 443/tcp   comment 'HTTPS'
    ufw allow 81/tcp    comment 'Nginx Proxy Manager UI'
    ufw allow 9000/tcp  comment 'Portainer UI'
    ufw allow 9443/tcp  comment 'Portainer HTTPS UI'

    # ── MySQL 仅允许本机访问（不对外暴露）────────────────────────────────────
    # MySQL 3306 已在 docker-compose 中绑定到 127.0.0.1，无需额外规则

    # 启用 UFW
    ufw --force enable

    log_success "防火墙配置完成"
    ufw status numbered
}

# ── 为站点开放自定义端口（内部端口，通过 NPM 反代，通常不需要）────────────────
open_port() {
    local port="$1"
    local proto="${2:-tcp}"
    local comment="${3:-custom}"
    ufw allow "${port}/${proto}" comment "$comment"
    log_info "已开放端口: ${port}/${proto}"
}

# ── 关闭端口 ─────────────────────────────────────────────────────────────────
close_port() {
    local port="$1"
    local proto="${2:-tcp}"
    ufw delete allow "${port}/${proto}" 2>/dev/null
    log_info "已关闭端口: ${port}/${proto}"
}

# ── 配置 SSH 防暴力破解（限制连接频率）──────────────────────────────────────
harden_ssh() {
    log_step "加固 SSH 安全..."

    # UFW 限速（每 30 秒最多 6 次连接）
    ufw limit 22/tcp comment 'SSH rate limit'

    # 禁用 root 密码登录（保留密钥登录）
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
        sed -i 's/^#\?PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
        # 不强制禁用密码登录，仅提示
        log_warn "建议手动禁用 SSH 密码登录（PasswordAuthentication no），使用密钥认证"
    fi

    log_success "SSH 安全加固完成"
}

# ── 配置系统安全参数 ─────────────────────────────────────────────────────────
configure_sysctl() {
    log_step "优化系统内核参数..."

    cat > /etc/sysctl.d/99-manus.conf << 'EOF'
# 网络性能优化
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# 文件描述符
fs.file-max = 1000000

# 防止 SYN Flood 攻击
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2

# 禁止 IP 欺骗
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# 禁止 ICMP 重定向
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
EOF

    sysctl -p /etc/sysctl.d/99-manus.conf &>/dev/null
    log_success "系统内核参数优化完成"
}

# ── 配置系统文件描述符限制 ───────────────────────────────────────────────────
configure_limits() {
    cat > /etc/security/limits.d/99-manus.conf << 'EOF'
* soft nofile 1000000
* hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
EOF
    log_info "文件描述符限制已配置"
}
