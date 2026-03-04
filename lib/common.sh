#!/bin/bash
# =============================================================================
# common.sh — 通用函数库
# 项目: manus-deploy
# 作者: Alexlyu365
# 说明: 提供颜色输出、日志记录、系统检测、工具函数等基础能力
# =============================================================================

# ── 颜色定义 ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── 日志函数 ─────────────────────────────────────────────────────────────────
LOG_FILE="/var/log/manus-deploy.log"

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $*" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*" | tee -a "$LOG_FILE"; }

# ── 打印横幅 ─────────────────────────────────────────────────────────────────
print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          Manus Deploy — 一键服务器部署系统               ║"
    echo "║          GitHub: github.com/Alexlyu365/manus             ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ── 打印分隔线 ───────────────────────────────────────────────────────────────
print_line() {
    echo -e "${BLUE}──────────────────────────────────────────────────────────${NC}"
}

# ── 确认提示 ─────────────────────────────────────────────────────────────────
confirm() {
    local msg="${1:-确认继续？}"
    echo -e "${YELLOW}${msg} [y/N]${NC} \c"
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ── 检测操作系统 ─────────────────────────────────────────────────────────────
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_CODENAME="${VERSION_CODENAME:-}"
    else
        log_error "无法检测操作系统，仅支持 Ubuntu/Debian/CentOS"
        exit 1
    fi

    case "$OS_ID" in
        ubuntu|debian)
            PKG_MANAGER="apt-get"
            PKG_UPDATE="apt-get update -y"
            PKG_INSTALL="apt-get install -y"
            ;;
        centos|rhel|fedora|rocky|almalinux)
            PKG_MANAGER="yum"
            PKG_UPDATE="yum update -y"
            PKG_INSTALL="yum install -y"
            ;;
        *)
            log_warn "未经测试的系统: $OS_ID，尝试使用 apt-get"
            PKG_MANAGER="apt-get"
            PKG_UPDATE="apt-get update -y"
            PKG_INSTALL="apt-get install -y"
            ;;
    esac

    log_info "检测到系统: ${OS_ID} ${OS_VERSION}"
}

# ── 检查 root 权限 ───────────────────────────────────────────────────────────
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 用户或 sudo 运行此脚本"
        exit 1
    fi
}

# ── 检查命令是否存在 ─────────────────────────────────────────────────────────
command_exists() {
    command -v "$1" &>/dev/null
}

# ── 安装基础软件包 ───────────────────────────────────────────────────────────
install_base_packages() {
    log_step "安装基础依赖包..."
    $PKG_UPDATE
    $PKG_INSTALL \
        curl wget git vim nano htop \
        net-tools dnsutils \
        ca-certificates gnupg lsb-release \
        unzip zip tar \
        openssl \
        cron \
        jq \
        2>/dev/null
    log_success "基础依赖包安装完成"
}

# ── 生成随机密码 ─────────────────────────────────────────────────────────────
gen_password() {
    local length="${1:-20}"
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9!@#$%^&*' | head -c "$length"
}

# ── 生成随机端口（避免冲突）──────────────────────────────────────────────────
gen_random_port() {
    local min="${1:-10000}"
    local max="${2:-60000}"
    local port
    while true; do
        port=$(( RANDOM % (max - min + 1) + min ))
        if ! ss -tlnp | grep -q ":${port} "; then
            echo "$port"
            return
        fi
    done
}

# ── 验证域名格式 ─────────────────────────────────────────────────────────────
validate_domain() {
    local domain="$1"
    if [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# ── 等待服务就绪 ─────────────────────────────────────────────────────────────
wait_for_service() {
    local host="$1"
    local port="$2"
    local timeout="${3:-60}"
    local elapsed=0

    log_info "等待服务 ${host}:${port} 就绪..."
    while ! nc -z "$host" "$port" 2>/dev/null; do
        sleep 2
        elapsed=$((elapsed + 2))
        if [ "$elapsed" -ge "$timeout" ]; then
            log_error "服务 ${host}:${port} 在 ${timeout}s 内未就绪"
            return 1
        fi
        echo -n "."
    done
    echo ""
    log_success "服务 ${host}:${port} 已就绪"
}

# ── 获取服务器公网 IP ────────────────────────────────────────────────────────
get_public_ip() {
    curl -s --max-time 10 https://api.ipify.org \
        || curl -s --max-time 10 https://ifconfig.me \
        || curl -s --max-time 10 https://icanhazip.com \
        || echo "未知"
}

# ── 写入配置到站点注册表 ─────────────────────────────────────────────────────
SITES_REGISTRY="/opt/manus/sites.conf"

register_site() {
    local domain="$1"
    local type="$2"
    local port="$3"
    local created_at
    created_at=$(date '+%Y-%m-%d %H:%M:%S')

    mkdir -p /opt/manus
    # 若已存在则更新，否则追加
    if grep -q "^${domain}|" "$SITES_REGISTRY" 2>/dev/null; then
        sed -i "s|^${domain}|.*|${domain}|${type}|${port}|${created_at}|" "$SITES_REGISTRY"
    else
        echo "${domain}|${type}|${port}|${created_at}" >> "$SITES_REGISTRY"
    fi
}

unregister_site() {
    local domain="$1"
    sed -i "/^${domain}|/d" "$SITES_REGISTRY" 2>/dev/null
}

list_sites() {
    if [ ! -f "$SITES_REGISTRY" ] || [ ! -s "$SITES_REGISTRY" ]; then
        echo "（暂无已部署的站点）"
        return
    fi
    printf "%-35s %-12s %-8s %-20s\n" "域名" "类型" "端口" "部署时间"
    print_line
    while IFS='|' read -r domain type port created_at; do
        printf "%-35s %-12s %-8s %-20s\n" "$domain" "$type" "$port" "$created_at"
    done < "$SITES_REGISTRY"
}
