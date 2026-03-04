#!/bin/bash
# =============================================================================
# firewall.sh — UFW 防火墙配置函数库（安全加固版）
# 项目: manus-deploy
# 修订: SEC-02 修复 Docker 绕过 UFW、SEC-06 添加 Fail2ban、SEC-07 强制 SSH 密钥认证
# =============================================================================

# ── 安装并配置 UFW 防火墙 ────────────────────────────────────────────────────
setup_firewall() {
    log_step "配置 UFW 防火墙..."

    # 安装 UFW
    if ! command_exists ufw; then
        $PKG_INSTALL ufw
    fi

    # ── 关键修复 SEC-02: 防止 Docker 绕过 UFW ────────────────────────────────
    # Docker 默认会直接操作 iptables，绕过 UFW 规则。
    # 通过在 /etc/ufw/after.rules 末尾添加 DOCKER-USER 链规则来修复。
    _fix_docker_ufw_bypass

    # 重置为默认规则
    ufw --force reset

    # 默认策略：拒绝入站，允许出站
    ufw default deny incoming
    ufw default allow outgoing

    # ── 必要端口 ──────────────────────────────────────────────────────────────
    # SSH: 使用 limit 限速（每 30 秒最多 6 次连接）
    ufw limit 22/tcp    comment 'SSH rate limit'
    ufw allow 80/tcp    comment 'HTTP'
    ufw allow 443/tcp   comment 'HTTPS'

    # 管理界面端口：默认开放，建议后续改为 IP 白名单
    ufw allow 81/tcp    comment 'Nginx Proxy Manager UI - 建议改为 IP 白名单'
    ufw allow 9000/tcp  comment 'Portainer UI - 建议改为 IP 白名单'
    ufw allow 9443/tcp  comment 'Portainer HTTPS UI'

    # ── MySQL 仅允许本机访问（不对外暴露）────────────────────────────────────
    # MySQL 3306 已在 docker-compose 中绑定到 127.0.0.1，无需额外规则

    # 启用 UFW
    ufw --force enable

    log_success "防火墙配置完成"
    ufw status numbered
}

# ── SEC-02 修复: 防止 Docker 绕过 UFW ────────────────────────────────────────
# Docker 在 iptables 中创建 DOCKER 链，直接绕过 UFW 规则。
# 解决方案: 在 DOCKER-USER 链中添加规则，阻止外部直接访问容器端口。
# 站点容器通过 NPM 内部网络通信，不需要直接暴露端口到宿主机。
_fix_docker_ufw_bypass() {
    log_step "修复 Docker 绕过 UFW 的安全问题..."

    # 方案1: 在 after.rules 中添加 DOCKER-USER 链规则
    # 允许已建立的连接和本机回环，拒绝其他外部直接访问容器
    local UFW_AFTER_RULES="/etc/ufw/after.rules"

    if ! grep -q "DOCKER-USER" "$UFW_AFTER_RULES" 2>/dev/null; then
        cat >> "$UFW_AFTER_RULES" << 'EOF'

# ── manus-deploy: 防止 Docker 绕过 UFW ──────────────────────────────────────
# 允许已建立的连接通过
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -i eth0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A DOCKER-USER -i eth0 -m conntrack --ctstate INVALID -j DROP
# 允许本机回环
-A DOCKER-USER -i lo -j ACCEPT
# 允许 HTTP/HTTPS（由 NPM 处理）
-A DOCKER-USER -i eth0 -p tcp --dport 80 -j ACCEPT
-A DOCKER-USER -i eth0 -p tcp --dport 443 -j ACCEPT
# 允许 NPM 管理界面
-A DOCKER-USER -i eth0 -p tcp --dport 81 -j ACCEPT
# 允许 Portainer
-A DOCKER-USER -i eth0 -p tcp --dport 9000 -j ACCEPT
-A DOCKER-USER -i eth0 -p tcp --dport 9443 -j ACCEPT
# 拒绝其他外部直接访问容器端口（防止 Docker 绕过 UFW）
-A DOCKER-USER -i eth0 -j DROP
COMMIT
EOF
        log_success "已添加 DOCKER-USER 链规则，防止 Docker 绕过 UFW"
    else
        log_info "DOCKER-USER 链规则已存在，跳过"
    fi
}

# ── 限制管理面板访问 IP（可选，推荐执行）────────────────────────────────────
restrict_admin_ports() {
    local allowed_ip="$1"

    if [ -z "$allowed_ip" ]; then
        log_warn "未指定允许的 IP，跳过管理端口限制"
        log_warn "建议手动执行: manus restrict-admin <你的IP>"
        return
    fi

    log_step "限制管理面板访问 IP 为: ${allowed_ip}..."

    # 删除原有的全开规则
    ufw delete allow 81/tcp 2>/dev/null || true
    ufw delete allow 9000/tcp 2>/dev/null || true
    ufw delete allow 9443/tcp 2>/dev/null || true

    # 添加 IP 白名单规则
    ufw allow from "$allowed_ip" to any port 81 proto tcp comment "NPM UI - IP whitelist"
    ufw allow from "$allowed_ip" to any port 9000 proto tcp comment "Portainer UI - IP whitelist"
    ufw allow from "$allowed_ip" to any port 9443 proto tcp comment "Portainer HTTPS - IP whitelist"

    ufw reload
    log_success "管理面板端口已限制为仅允许 ${allowed_ip} 访问"
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

# ── SEC-07 修复: 强制 SSH 安全加固 ───────────────────────────────────────────
# 原版本中 harden_ssh() 未被主流程调用，且密码登录禁用仅为"建议"。
# 本版本强制执行，并在主流程中调用。
harden_ssh() {
    log_step "加固 SSH 安全配置..."

    if [ ! -f /etc/ssh/sshd_config ]; then
        log_warn "未找到 sshd_config，跳过 SSH 加固"
        return
    fi

    # 备份原始配置
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d)

    # 禁止 root 使用密码登录（允许密钥登录）
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

    # 强制禁用密码认证，要求使用密钥
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

    # 禁用空密码
    sed -i 's/^#\?PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config

    # 禁用 X11 转发（减少攻击面）
    sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config

    # 设置最大认证尝试次数
    if ! grep -q "^MaxAuthTries" /etc/ssh/sshd_config; then
        echo "MaxAuthTries 3" >> /etc/ssh/sshd_config
    else
        sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
    fi

    # 设置登录超时
    if ! grep -q "^LoginGraceTime" /etc/ssh/sshd_config; then
        echo "LoginGraceTime 30" >> /etc/ssh/sshd_config
    fi

    # 重启 SSH 服务
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true

    log_success "SSH 安全加固完成（密码登录已禁用，仅允许密钥认证）"
    log_warn "请确保您已配置 SSH 密钥，否则将无法登录服务器！"
}

# ── SEC-06: 安装并配置 Fail2ban ───────────────────────────────────────────────
setup_fail2ban() {
    log_step "安装并配置 Fail2ban（防暴力破解）..."

    # 安装 Fail2ban
    if ! command_exists fail2ban-server; then
        $PKG_INSTALL fail2ban
    fi

    # 创建本地配置（覆盖默认配置，避免升级时被覆盖）
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
# 封禁时间: 1小时
bantime  = 3600
# 检测时间窗口: 10分钟
findtime = 600
# 最大失败次数: 5次
maxretry = 5
# 忽略本机 IP
ignoreip = 127.0.0.1/8 ::1
# 使用 systemd 后端
backend = systemd

# ── SSH 防暴力破解 ────────────────────────────────────────────────────────────
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 7200

# ── Nginx 防暴力破解（覆盖 NPM 的 Nginx 日志）────────────────────────────────
[nginx-http-auth]
enabled  = true
filter   = nginx-http-auth
port     = http,https
logpath  = /opt/manus/nginx-proxy-manager/data/logs/*/error.log
maxretry = 5

# ── 防止 HTTP 请求洪水 ────────────────────────────────────────────────────────
[nginx-req-limit]
enabled  = true
filter   = nginx-req-limit
port     = http,https
logpath  = /opt/manus/nginx-proxy-manager/data/logs/*/error.log
maxretry = 10
findtime = 60
bantime  = 600
EOF

    # 创建 nginx-req-limit 过滤器（如果不存在）
    if [ ! -f /etc/fail2ban/filter.d/nginx-req-limit.conf ]; then
        cat > /etc/fail2ban/filter.d/nginx-req-limit.conf << 'EOF'
[Definition]
failregex = limiting requests, excess:.* by zone.*client: <HOST>
ignoreregex =
EOF
    fi

    # 启动并设置开机自启
    systemctl enable fail2ban
    systemctl restart fail2ban

    log_success "Fail2ban 配置完成"
    echo ""
    echo -e "${GREEN}  Fail2ban 规则:${NC}"
    echo "  - SSH: 3次失败后封禁 2 小时"
    echo "  - Nginx HTTP Auth: 5次失败后封禁 1 小时"
    echo "  - HTTP 请求洪水: 60秒内超过 10 次封禁 10 分钟"
    echo ""
    echo -e "${CYAN}  查看封禁状态: fail2ban-client status${NC}"
    echo -e "${CYAN}  解封 IP: fail2ban-client set sshd unbanip <IP>${NC}"
    echo ""
}

# ── 配置系统安全参数 ─────────────────────────────────────────────────────────
configure_sysctl() {
    log_step "优化系统内核参数（含安全加固）..."

    cat > /etc/sysctl.d/99-manus.conf << 'EOF'
# ── 网络性能优化 ──────────────────────────────────────────────────────────────
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# ── 文件描述符 ────────────────────────────────────────────────────────────────
fs.file-max = 1000000

# ── 防止 SYN Flood 攻击 ───────────────────────────────────────────────────────
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2

# ── 禁止 IP 欺骗 ──────────────────────────────────────────────────────────────
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# ── 禁止 ICMP 重定向（防止路由欺骗）─────────────────────────────────────────
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# ── 禁止接受源路由包 ──────────────────────────────────────────────────────────
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# ── 记录伪造的 IP 包（辅助入侵检测）─────────────────────────────────────────
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# ── 防止 TIME_WAIT 攻击 ───────────────────────────────────────────────────────
net.ipv4.tcp_rfc1337 = 1

# ── 禁用 IPv6（如不使用）─────────────────────────────────────────────────────
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
EOF

    sysctl -p /etc/sysctl.d/99-manus.conf &>/dev/null
    log_success "系统内核参数优化完成（含安全加固）"
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

# ── SEC-11: 配置自动安全更新 ─────────────────────────────────────────────────
setup_auto_security_updates() {
    log_step "配置自动安全更新..."

    if [ "$PKG_MANAGER" = "apt-get" ]; then
        $PKG_INSTALL unattended-upgrades apt-listchanges

        # 配置仅自动安装安全更新
        cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

// 自动删除不再需要的依赖
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// 需要重启时自动重启（仅在凌晨 2-5 点）
Unattended-Upgrade::Automatic-Reboot "false";

// 发送邮件通知（可选）
// Unattended-Upgrade::Mail "your@email.com";
EOF

        cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

        systemctl enable unattended-upgrades
        systemctl start unattended-upgrades

        log_success "自动安全更新已配置（每日自动安装安全补丁）"
    else
        log_warn "非 Debian/Ubuntu 系统，请手动配置自动安全更新"
    fi
}
