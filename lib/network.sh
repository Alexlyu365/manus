#!/bin/bash
# =============================================================================
# network.sh — 网络工具函数库
# 对标 kejilion.sh：BBR 加速、DNS 优化、虚拟内存、网络诊断、内核参数优化
# =============================================================================

# ── BBR 加速管理 ──────────────────────────────────────────────────────────────
bbr_menu() {
    while true; do
        clear
        echo -e "${CYAN}BBR 网络加速管理${NC}"
        echo ""

        # 显示当前状态
        local current_cc current_qdisc
        current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
        echo -e "  当前拥塞控制: ${WHITE}${current_cc}${NC}"
        echo -e "  当前队列算法: ${WHITE}${current_qdisc}${NC}"
        echo ""

        # 检查内核版本
        local kernel_ver
        kernel_ver=$(uname -r | cut -d. -f1-2)
        local kernel_major kernel_minor
        kernel_major=$(echo "$kernel_ver" | cut -d. -f1)
        kernel_minor=$(echo "$kernel_ver" | cut -d. -f2)

        echo "  1. 开启 BBR（推荐，内核 ≥ 4.9）"
        echo "  2. 开启 BBR + FQ（高性能模式）"
        echo "  3. 关闭 BBR，恢复默认"
        echo "  4. 查看可用拥塞控制算法"
        echo "────────────────────────────────────────────────────"
        echo "  0. 返回上一级"
        echo "────────────────────────────────────────────────────"
        read -rp "请输入选择: " choice
        case "$choice" in
            1)
                _enable_bbr "bbr" "fq_codel"
                ;;
            2)
                _enable_bbr "bbr" "fq"
                ;;
            3)
                _disable_bbr
                ;;
            4)
                echo ""
                echo "  可用的拥塞控制算法:"
                sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | sed 's/^/  /'
                echo ""
                echo "  可用的队列调度算法:"
                tc qdisc help 2>&1 | grep "^Usage:" | head -5 | sed 's/^/  /' || \
                    echo "  fq fq_codel pfifo_fast sfq"
                ;;
            0) break ;;
            *) log_warn "无效输入" ;;
        esac
        read -rp "按回车键继续..."
    done
}

_enable_bbr() {
    local cc="$1"
    local qdisc="$2"

    # 检查内核是否支持 BBR
    if ! modprobe tcp_bbr 2>/dev/null && ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        log_error "当前内核不支持 BBR，需要内核版本 ≥ 4.9"
        log_info "当前内核: $(uname -r)"
        return 1
    fi

    log_step "启用 BBR 加速 (${cc} + ${qdisc})..."

    # 写入 sysctl 配置（持久化）
    local sysctl_conf="/etc/sysctl.d/99-manus-bbr.conf"
    cat > "$sysctl_conf" << EOF
# Manus BBR 加速配置
net.core.default_qdisc=${qdisc}
net.ipv4.tcp_congestion_control=${cc}
EOF

    sysctl -p "$sysctl_conf" 2>/dev/null
    log_success "BBR 已启用: ${cc} + ${qdisc}"

    # 验证
    local actual_cc
    actual_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    echo -e "  验证: 当前拥塞控制 = ${WHITE}${actual_cc}${NC}"
}

_disable_bbr() {
    log_step "关闭 BBR，恢复默认设置..."
    rm -f /etc/sysctl.d/99-manus-bbr.conf
    sysctl -w net.ipv4.tcp_congestion_control=cubic 2>/dev/null
    sysctl -w net.core.default_qdisc=pfifo_fast 2>/dev/null
    log_success "已恢复默认网络算法 (cubic)"
}

# ── DNS 优化 ──────────────────────────────────────────────────────────────────
dns_menu() {
    while true; do
        clear
        echo -e "${CYAN}DNS 优化管理${NC}"
        echo ""
        echo "  当前 DNS 配置:"
        cat /etc/resolv.conf 2>/dev/null | grep nameserver | sed 's/^/  /'
        echo ""
        echo "  1. 国内优化 DNS (阿里 223.5.5.5 + 腾讯 119.29.29.29)"
        echo "  2. 国际优化 DNS (Cloudflare 1.1.1.1 + Google 8.8.8.8)"
        echo "  3. 隐私优先 DNS (Cloudflare 1.1.1.1 + 1.0.0.1)"
        echo "  4. 手动设置 DNS"
        echo "  5. 恢复系统默认"
        echo "────────────────────────────────────────────────────"
        echo "  0. 返回上一级"
        echo "────────────────────────────────────────────────────"
        read -rp "请输入选择: " choice
        case "$choice" in
            1) _set_dns "223.5.5.5" "119.29.29.29" ;;
            2) _set_dns "1.1.1.1" "8.8.8.8" ;;
            3) _set_dns "1.1.1.1" "1.0.0.1" ;;
            4)
                read -rp "主 DNS: " dns1
                read -rp "备 DNS: " dns2
                _set_dns "$dns1" "$dns2"
                ;;
            5)
                # 删除 manus 写入的 DNS 配置，恢复 systemd-resolved
                if systemctl is-active systemd-resolved &>/dev/null; then
                    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
                    log_success "已恢复 systemd-resolved 管理的 DNS"
                else
                    log_warn "请手动编辑 /etc/resolv.conf"
                fi
                ;;
            0) break ;;
            *) log_warn "无效输入" ;;
        esac
        read -rp "按回车键继续..."
    done
}

_set_dns() {
    local dns1="$1"
    local dns2="$2"

    log_step "设置 DNS: ${dns1} / ${dns2}"

    # 防止 systemd-resolved 覆盖（Debian/Ubuntu）
    if [ -L /etc/resolv.conf ]; then
        # 解除软链接，创建真实文件
        cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null
        rm /etc/resolv.conf
    fi

    cat > /etc/resolv.conf << EOF
# 由 manus-deploy 管理
nameserver ${dns1}
nameserver ${dns2}
options edns0 trust-ad
EOF

    # 防止被覆盖
    chattr +i /etc/resolv.conf 2>/dev/null || true

    log_success "DNS 已设置: ${dns1} / ${dns2}"

    # 测试 DNS 解析
    log_step "测试 DNS 解析..."
    if nslookup google.com "$dns1" &>/dev/null; then
        log_success "DNS 解析正常"
    else
        log_warn "DNS 解析测试失败，请检查网络连接"
    fi
}

# ── 虚拟内存（Swap）管理 ──────────────────────────────────────────────────────
swap_menu() {
    while true; do
        clear
        echo -e "${CYAN}虚拟内存 (Swap) 管理${NC}"
        echo ""
        echo "  当前 Swap 状态:"
        free -h | grep -i swap | sed 's/^/  /'
        swapon --show 2>/dev/null | sed 's/^/  /' || echo "  （无 Swap）"
        echo ""
        echo "  1. 创建 1GB Swap"
        echo "  2. 创建 2GB Swap"
        echo "  3. 创建 4GB Swap"
        echo "  4. 自定义大小"
        echo "  5. 删除 Swap"
        echo "────────────────────────────────────────────────────"
        echo "  0. 返回上一级"
        echo "────────────────────────────────────────────────────"
        read -rp "请输入选择: " choice
        case "$choice" in
            1) _create_swap 1024 ;;
            2) _create_swap 2048 ;;
            3) _create_swap 4096 ;;
            4)
                read -rp "Swap 大小 (MB): " size
                [[ "$size" =~ ^[0-9]+$ ]] || { log_error "请输入数字"; continue; }
                _create_swap "$size"
                ;;
            5) _delete_swap ;;
            0) break ;;
            *) log_warn "无效输入" ;;
        esac
        read -rp "按回车键继续..."
    done
}

_create_swap() {
    local size_mb="$1"
    local swap_file="/swapfile"

    # 删除旧的 swap
    if swapon --show | grep -q "$swap_file"; then
        swapoff "$swap_file" 2>/dev/null
    fi

    log_step "创建 ${size_mb}MB Swap 文件..."

    # 使用 fallocate（更快）或 dd（更兼容）
    if command -v fallocate &>/dev/null; then
        fallocate -l "${size_mb}M" "$swap_file" 2>/dev/null || \
            dd if=/dev/zero of="$swap_file" bs=1M count="$size_mb" 2>/dev/null
    else
        dd if=/dev/zero of="$swap_file" bs=1M count="$size_mb" status=progress 2>/dev/null
    fi

    chmod 600 "$swap_file"
    mkswap "$swap_file" 2>/dev/null
    swapon "$swap_file" 2>/dev/null

    # 写入 fstab 实现持久化
    if ! grep -q "$swap_file" /etc/fstab; then
        echo "${swap_file} none swap sw 0 0" >> /etc/fstab
    fi

    # 优化 swappiness（降低 swap 使用倾向，适合服务器）
    sysctl -w vm.swappiness=10 2>/dev/null
    if ! grep -q "vm.swappiness" /etc/sysctl.d/99-manus-bbr.conf 2>/dev/null; then
        echo "vm.swappiness=10" >> /etc/sysctl.d/99-manus-network.conf
    fi

    log_success "Swap 创建完成: ${size_mb}MB"
    free -h | grep -i swap | sed 's/^/  /'
}

_delete_swap() {
    local swap_file="/swapfile"
    if [ -f "$swap_file" ]; then
        swapoff "$swap_file" 2>/dev/null
        rm -f "$swap_file"
        sed -i "/${swap_file//\//\\/}/d" /etc/fstab 2>/dev/null
        log_success "Swap 已删除"
    else
        log_warn "未找到 Swap 文件"
    fi
}

# ── 内核参数优化 ──────────────────────────────────────────────────────────────
kernel_optimize() {
    clear
    echo -e "${CYAN}Linux 内核参数优化${NC}"
    echo ""
    echo "  将优化以下参数（适合 Web 服务器）："
    echo "  - 增大文件描述符限制"
    echo "  - 优化 TCP 连接参数"
    echo "  - 优化内存管理"
    echo "  - 优化网络缓冲区"
    echo ""

    if ! confirm "确认应用内核优化参数？"; then
        return
    fi

    log_step "应用内核优化参数..."

    cat > /etc/sysctl.d/99-manus-network.conf << 'EOF'
# Manus 内核网络优化配置
# ── 文件描述符 ──
fs.file-max = 1000000
fs.nr_open = 1000000

# ── TCP 优化 ──
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1

# ── 网络缓冲区 ──
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 32768

# ── 内存管理 ──
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF

    sysctl -p /etc/sysctl.d/99-manus-network.conf 2>/dev/null

    # 优化文件描述符限制
    cat > /etc/security/limits.d/99-manus.conf << 'EOF'
# Manus 文件描述符限制优化
* soft nofile 1000000
* hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
EOF

    log_success "内核参数优化完成，部分参数需要重启后生效"
}

# ── 网络诊断工具 ──────────────────────────────────────────────────────────────
network_diagnose() {
    while true; do
        clear
        echo -e "${CYAN}网络诊断工具${NC}"
        echo ""
        echo "  1. 测试 DNS 解析"
        echo "  2. 测试端口连通性"
        echo "  3. 查看端口占用"
        echo "  4. 查看网络连接"
        echo "  5. 测试 HTTP 响应"
        echo "  6. 查看路由表"
        echo "────────────────────────────────────────────────────"
        echo "  0. 返回上一级"
        echo "────────────────────────────────────────────────────"
        read -rp "请输入选择: " choice
        case "$choice" in
            1)
                read -rp "域名: " domain
                echo ""
                echo "  nslookup 结果:"
                nslookup "$domain" 2>/dev/null | sed 's/^/  /' || log_warn "nslookup 未安装"
                echo ""
                echo "  dig 结果:"
                dig +short "$domain" 2>/dev/null | sed 's/^/  /' || log_warn "dig 未安装"
                ;;
            2)
                read -rp "主机: " host
                read -rp "端口: " port
                if timeout 5 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
                    log_success "${host}:${port} 可达"
                else
                    log_error "${host}:${port} 不可达"
                fi
                ;;
            3)
                read -rp "端口号 (留空查看所有监听端口): " port
                if [ -z "$port" ]; then
                    ss -tlnp 2>/dev/null | sed 's/^/  /'
                else
                    ss -tlnp | grep ":${port}" | sed 's/^/  /'
                    lsof -i :"$port" 2>/dev/null | sed 's/^/  /'
                fi
                ;;
            4)
                echo ""
                echo "  活跃 TCP 连接 (前20):"
                ss -tnp 2>/dev/null | head -20 | sed 's/^/  /'
                ;;
            5)
                read -rp "URL (如 https://example.com): " url
                echo ""
                curl -o /dev/null -s -w "  HTTP状态码: %{http_code}\n  响应时间: %{time_total}s\n  下载速度: %{speed_download} bytes/s\n" "$url" 2>/dev/null
                ;;
            6)
                echo ""
                ip route show | sed 's/^/  /'
                ;;
            0) break ;;
            *) log_warn "无效输入" ;;
        esac
        read -rp "按回车键继续..."
    done
}

# ── 网络工具主菜单 ────────────────────────────────────────────────────────────
network_main_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║                  网络工具中心                        ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
        echo ""
        local current_cc current_qdisc
        current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
        echo -e "  网络算法: ${WHITE}${current_cc} / ${current_qdisc}${NC}"
        echo ""
        echo "  1. BBR 加速管理"
        echo "  2. DNS 优化"
        echo "  3. 虚拟内存 (Swap) 管理"
        echo "  4. 内核参数优化"
        echo "  5. 网络诊断工具"
        echo "────────────────────────────────────────────────────"
        echo "  0. 返回主菜单"
        echo "────────────────────────────────────────────────────"
        read -rp "请输入选择: " choice
        case "$choice" in
            1) bbr_menu ;;
            2) dns_menu ;;
            3) swap_menu ;;
            4) kernel_optimize; read -rp "按回车键继续..." ;;
            5) network_diagnose ;;
            0) break ;;
            *) log_warn "无效输入" ;;
        esac
    done
}
