#!/bin/bash
# =============================================================================
# sysinfo.sh — 系统信息面板
# 对标 kejilion.sh linux_info 功能：展示 CPU/内存/磁盘/网络/Docker 状态
# =============================================================================

# ── 获取公网 IP（兼容 GCE 元数据服务）────────────────────────────────────────
get_public_ip() {
    # 优先尝试 GCE 元数据服务
    local ip
    ip=$(curl -sf --max-time 2 -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/externalIp" 2>/dev/null)
    if [ -n "$ip" ]; then
        echo "$ip"
        return
    fi
    # 通用方案
    ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || \
         curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || \
         curl -sf --max-time 5 https://ip.sb 2>/dev/null)
    echo "${ip:-未知}"
}

# ── 获取网络流量统计 ──────────────────────────────────────────────────────────
get_network_traffic() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -z "$iface" ]; then
        echo "RX: 未知  TX: 未知"
        return
    fi
    local rx_bytes tx_bytes
    rx_bytes=$(cat /sys/class/net/"${iface}"/statistics/rx_bytes 2>/dev/null || echo 0)
    tx_bytes=$(cat /sys/class/net/"${iface}"/statistics/tx_bytes 2>/dev/null || echo 0)

    # 转换为可读格式
    local rx_human tx_human
    rx_human=$(awk "BEGIN {
        b=${rx_bytes}
        if (b >= 1073741824) printf \"%.2f GB\", b/1073741824
        else if (b >= 1048576) printf \"%.2f MB\", b/1048576
        else if (b >= 1024) printf \"%.2f KB\", b/1024
        else printf \"%d B\", b
    }")
    tx_human=$(awk "BEGIN {
        b=${tx_bytes}
        if (b >= 1073741824) printf \"%.2f GB\", b/1073741824
        else if (b >= 1048576) printf \"%.2f MB\", b/1048576
        else if (b >= 1024) printf \"%.2f KB\", b/1024
        else printf \"%d B\", b
    }")
    echo "RX: ${rx_human}  TX: ${tx_human}"
}

# ── 主系统信息展示函数 ────────────────────────────────────────────────────────
show_sysinfo() {
    clear
    echo -e "${CYAN}正在查询系统信息...${NC}"

    # ── 基础信息 ──
    local hostname os_info kernel cpu_arch
    hostname=$(uname -n)
    os_info=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    kernel=$(uname -r)
    cpu_arch=$(uname -m)

    # ── CPU ──
    local cpu_model cpu_cores cpu_freq cpu_usage
    cpu_model=$(lscpu 2>/dev/null | awk -F': +' '/Model name:/ {print $2; exit}')
    cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
    cpu_freq=$(awk '/MHz/{sum+=$4; count++} END {if(count>0) printf "%.1f GHz", sum/count/1000}' /proc/cpuinfo 2>/dev/null)
    # CPU 使用率（采样 1 秒）
    cpu_usage=$(awk '{u=$2+$4; t=$2+$4+$5;
        if (NR==1){u1=u; t1=t;}
        else printf "%.1f%%", (($2+$4-u1)*100/(t-t1))}' \
        <(grep '^cpu ' /proc/stat) <(sleep 1; grep '^cpu ' /proc/stat) 2>/dev/null || echo "N/A")

    # ── 内存 ──
    local mem_info swap_info
    mem_info=$(free -m 2>/dev/null | awk 'NR==2 {
        used=$3; total=$2;
        if (total>0) pct=used*100/total; else pct=0
        printf "%dM / %dM (%.1f%%)", used, total, pct
    }')
    swap_info=$(free -m 2>/dev/null | awk 'NR==3 {
        used=$3; total=$2;
        if (total==0) {print "未配置"; exit}
        printf "%dM / %dM (%.1f%%)", used, total, used*100/total
    }')

    # ── 磁盘 ──
    local disk_info
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2 {printf "%s / %s (%s)", $3, $2, $5}')

    # ── 网络 ──
    local iface ipv4 ipv6 dns congestion qdisc traffic
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    ipv4=$(get_public_ip)
    ipv6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2; exit}' | cut -d/ -f1)
    dns=$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null | sed 's/ $//')
    congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    traffic=$(get_network_traffic)

    # ── 连接数 ──
    local tcp_count udp_count
    tcp_count=$(ss -t 2>/dev/null | wc -l)
    udp_count=$(ss -u 2>/dev/null | wc -l)

    # ── 时间 ──
    local uptime_str timezone current_time load
    uptime_str=$(awk '{
        d=int($1/86400); h=int(($1%86400)/3600); m=int(($1%3600)/60)
        if(d>0) printf "%d天 ", d
        if(h>0) printf "%d时 ", h
        printf "%d分", m
    }' /proc/uptime 2>/dev/null)
    timezone=$(timedatectl 2>/dev/null | awk '/Time zone/{print $3}' || date +%Z)
    current_time=$(date "+%Y-%m-%d %H:%M:%S")
    load=$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | xargs)

    # ── Docker 状态 ──
    local docker_status docker_containers docker_images
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        docker_status="${GREEN}运行中${NC}"
        docker_containers=$(docker ps -q 2>/dev/null | wc -l)
        docker_images=$(docker images -q 2>/dev/null | wc -l)
    else
        docker_status="${RED}未运行${NC}"
        docker_containers=0
        docker_images=0
    fi

    # ── 站点状态 ──
    local site_count
    site_count=$(grep -c '|' /opt/manus/sites.conf 2>/dev/null || echo 0)

    # ── 输出 ──
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              Manus 服务器信息面板                    ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}── 系统 ─────────────────────────────────────────────${NC}"
    echo -e "  主机名:       ${WHITE}${hostname}${NC}"
    echo -e "  系统版本:     ${WHITE}${os_info}${NC}"
    echo -e "  内核版本:     ${WHITE}${kernel}${NC}"
    echo -e "  CPU 架构:     ${WHITE}${cpu_arch}${NC}"
    echo ""
    echo -e "${CYAN}── CPU ──────────────────────────────────────────────${NC}"
    echo -e "  型号:         ${WHITE}${cpu_model}${NC}"
    echo -e "  核心数:       ${WHITE}${cpu_cores} 核  ${cpu_freq}${NC}"
    echo -e "  当前占用:     ${WHITE}${cpu_usage}${NC}"
    echo -e "  系统负载:     ${WHITE}${load}${NC}"
    echo ""
    echo -e "${CYAN}── 内存与存储 ───────────────────────────────────────${NC}"
    echo -e "  物理内存:     ${WHITE}${mem_info}${NC}"
    echo -e "  虚拟内存:     ${WHITE}${swap_info}${NC}"
    echo -e "  磁盘占用:     ${WHITE}${disk_info}${NC}"
    echo ""
    echo -e "${CYAN}── 网络 ─────────────────────────────────────────────${NC}"
    echo -e "  网卡:         ${WHITE}${iface}${NC}"
    echo -e "  公网 IPv4:    ${WHITE}${ipv4}${NC}"
    [ -n "$ipv6" ] && echo -e "  IPv6:         ${WHITE}${ipv6}${NC}"
    echo -e "  DNS:          ${WHITE}${dns}${NC}"
    echo -e "  网络算法:     ${WHITE}${congestion} / ${qdisc}${NC}"
    echo -e "  流量统计:     ${WHITE}${traffic}${NC}"
    echo -e "  TCP|UDP连接:  ${WHITE}${tcp_count} | ${udp_count}${NC}"
    echo ""
    echo -e "${CYAN}── Docker ───────────────────────────────────────────${NC}"
    echo -e "  Docker 状态:  $(echo -e "${docker_status}")"
    echo -e "  运行容器:     ${WHITE}${docker_containers} 个${NC}"
    echo -e "  本地镜像:     ${WHITE}${docker_images} 个${NC}"
    echo -e "  托管站点:     ${WHITE}${site_count} 个${NC}"
    echo ""
    echo -e "${CYAN}── 时间 ─────────────────────────────────────────────${NC}"
    echo -e "  时区:         ${WHITE}${timezone}${NC}"
    echo -e "  当前时间:     ${WHITE}${current_time}${NC}"
    echo -e "  运行时长:     ${WHITE}${uptime_str}${NC}"
    echo ""
}

# ── 显示所有托管站点状态 ──────────────────────────────────────────────────────
show_sites_status() {
    local sites_conf="/opt/manus/sites.conf"

    if [ ! -f "$sites_conf" ] || [ ! -s "$sites_conf" ]; then
        log_warn "当前没有托管的站点"
        return
    fi

    echo ""
    echo -e "${CYAN}── 站点状态 ─────────────────────────────────────────${NC}"
    printf "  %-30s %-12s %-10s %s\n" "域名" "容器状态" "类型" "部署日期"
    echo "  ────────────────────────────────────────────────────────"

    while IFS='|' read -r domain container type repo date; do
        [ -z "$domain" ] && continue
        local status
        if docker ps --filter "name=${container}" --filter "status=running" | grep -q "$container" 2>/dev/null; then
            status="${GREEN}运行中${NC}"
        else
            status="${RED}已停止${NC}"
        fi
        printf "  %-30s " "$domain"
        echo -ne "$(echo -e "${status}")"
        printf "      %-10s %s\n" "$type" "$date"
    done < "$sites_conf"
    echo ""
}
