#!/bin/bash
# =============================================================================
# docker.sh — Docker 安装与管理函数库（轻量化版 v2）
# 项目: manus-deploy
# 适用: Ubuntu 20.04/22.04/24.04, Debian 11/12 (Bookworm)
# 轻量化修订:
#   - 移除 MySQL 和 Portainer 默认安装（改为按需部署）
#   - NPM 内存限制从 512M 降至 150M
#   - 新增 setup_swap 函数（1GB Swap，防止 OOM）
#   - Docker daemon 日志限制从 50M 降至 10M
# =============================================================================

# ── 安装 Docker ──────────────────────────────────────────────────────────────
install_docker() {
    if command_exists docker; then
        local ver
        ver=$(docker --version 2>/dev/null)
        log_info "Docker 已安装: ${ver}"
        return 0
    fi

    log_step "安装 Docker Engine..."

    case "$OS_ID" in
        ubuntu|debian)
            apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
            apt-get install -y ca-certificates curl gnupg lsb-release
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
                | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg

            local codename
            codename=$(. /etc/os-release && echo "${VERSION_CODENAME}")
            if [ -z "$codename" ]; then
                codename=$(lsb_release -cs 2>/dev/null || echo "bookworm")
            fi
            log_info "使用 Docker 源 codename: ${codename}"

            echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
                https://download.docker.com/linux/${OS_ID} \
                ${codename} stable" \
                | tee /etc/apt/sources.list.d/docker.list > /dev/null

            apt-get update -y
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;

        centos|rhel|rocky|almalinux)
            yum install -y yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;

        fedora)
            dnf install -y dnf-plugins-core
            dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;

        *)
            log_warn "尝试使用通用安装脚本安装 Docker..."
            curl -fsSL https://get.docker.com | sh
            ;;
    esac

    systemctl enable docker
    systemctl start docker

    if command_exists docker; then
        log_success "Docker 安装成功: $(docker --version)"
    else
        log_error "Docker 安装失败，请手动检查"
        exit 1
    fi
}

# ── 配置 Docker 守护进程（轻量化 + 安全加固）────────────────────────────────
configure_docker_daemon() {
    log_step "配置 Docker 守护进程（轻量化 + 安全加固）..."

    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "live-restore": true,
  "no-new-privileges": true,
  "userland-proxy": false
}
EOF
    # 日志限制从 50M×5 降至 10M×3，节省磁盘空间
    # no-new-privileges: 防止容器内进程提权
    # userland-proxy: 禁用，减少内存占用

    systemctl daemon-reload
    systemctl restart docker
    log_success "Docker 守护进程配置完成"
}

# ── 配置 Swap 虚拟内存（防止 OOM，低配服务器必须）────────────────────────────
setup_swap() {
    local swap_size="${1:-1G}"

    # 检查是否已有 Swap
    if swapon --show | grep -q "/swapfile"; then
        log_info "Swap 已存在，跳过"
        return 0
    fi

    log_step "配置 ${swap_size} Swap 虚拟内存（防止 OOM）..."

    # 创建 Swap 文件
    fallocate -l "$swap_size" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    # 开机自动挂载
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    # 降低 swappiness（减少不必要的 swap 使用）
    sysctl -w vm.swappiness=10 > /dev/null
    if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
        echo "vm.swappiness=10" >> /etc/sysctl.conf
    fi

    log_success "Swap 配置完成: $(free -h | grep Swap)"
}

# ── 创建 Docker 网络 ─────────────────────────────────────────────────────────
create_docker_network() {
    local network_name="$1"
    local subnet="${2:-}"
    if ! docker network ls | grep -q "$network_name"; then
        if [ -n "$subnet" ]; then
            docker network create --subnet="$subnet" "$network_name"
        else
            docker network create "$network_name"
        fi
        log_info "已创建 Docker 网络: $network_name"
    fi
}

# ── 部署 Nginx Proxy Manager（轻量化版，内存限制 150M）───────────────────────
deploy_nginx_proxy_manager() {
    log_step "部署 Nginx Proxy Manager（可视化反向代理）..."

    local NPM_DIR="/opt/manus/nginx-proxy-manager"
    mkdir -p "${NPM_DIR}/data" "${NPM_DIR}/letsencrypt"

    # 创建共享网络（所有站点容器都接入此网络）
    create_docker_network "npm_network"

    cat > "${NPM_DIR}/docker-compose.yml" << 'EOF'
services:
  npm:
    image: jc21/nginx-proxy-manager:2.11.3
    container_name: nginx-proxy-manager
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    networks:
      - npm_network
    environment:
      - DISABLE_IPV6=true
    mem_limit: 150m
    memswap_limit: 150m
    cpus: '0.5'

networks:
  npm_network:
    external: true
EOF

    cd "$NPM_DIR"
    docker compose up -d

    # 等待 NPM 启动（最多 60 秒）
    local i=0
    while [ $i -lt 12 ]; do
        if docker ps | grep -q "nginx-proxy-manager" && \
           docker inspect nginx-proxy-manager --format='{{.State.Health.Status}}' 2>/dev/null | grep -qE "healthy|starting" || \
           docker ps | grep "nginx-proxy-manager" | grep -q "Up"; then
            break
        fi
        sleep 5
        i=$((i+1))
    done

    log_success "Nginx Proxy Manager 部署完成（版本已锁定 2.11.3）"
    echo ""
    echo -e "${GREEN}  NPM 管理界面: http://$(get_public_ip):81${NC}"
    echo -e "${YELLOW}  默认账号: admin@example.com${NC}"
    echo -e "${YELLOW}  默认密码: changeme${NC}"
    echo -e "${RED}  !! 请登录后立即修改默认密码 !!${NC}"
    echo ""
}

# ── 按需部署 Portainer（不在初始化时安装，需要时手动执行）────────────────────
deploy_portainer() {
    log_step "部署 Portainer（通过 Docker Socket Proxy 安全访问）..."

    local PORTAINER_DIR="/opt/manus/portainer"
    mkdir -p "${PORTAINER_DIR}/data"

    cat > "${PORTAINER_DIR}/docker-compose.yml" << 'EOF'
services:
  socket-proxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: docker-socket-proxy
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      CONTAINERS: 1
      SERVICES: 1
      NETWORKS: 1
      VOLUMES: 1
      INFO: 1
      IMAGES: 1
      EVENTS: 1
      PING: 1
      VERSION: 1
      POST: 1
      EXEC: 0
      BUILD: 0
      COMMIT: 0
      SECRETS: 0
    networks:
      - socket_proxy_network
    mem_limit: 32m

  portainer:
    image: portainer/portainer-ce:2.21.5
    container_name: portainer
    restart: unless-stopped
    ports:
      - "9000:9000"
    volumes:
      - ./data:/data
    environment:
      - DOCKER_HOST=tcp://socket-proxy:2375
    networks:
      - npm_network
      - socket_proxy_network
    depends_on:
      - socket-proxy
    mem_limit: 128m

networks:
  npm_network:
    external: true
  socket_proxy_network:
    driver: bridge
    internal: true
EOF

    cd "$PORTAINER_DIR"
    docker compose up -d

    log_success "Portainer 部署完成"
    echo ""
    echo -e "${GREEN}  Portainer 管理界面: http://$(get_public_ip):9000${NC}"
    echo -e "${YELLOW}  首次访问请在 5 分钟内设置管理员密码${NC}"
    echo ""
}

# ── 按需部署 MySQL（不在初始化时安装，仅在网站需要数据库时执行）──────────────
deploy_mysql() {
    log_step "部署 MySQL 8.0 数据库..."

    local MYSQL_DIR="/opt/manus/mysql"
    mkdir -p "${MYSQL_DIR}/data" "${MYSQL_DIR}/conf" "${MYSQL_DIR}/init"

    local MYSQL_ROOT_PASS
    if [ -f "/opt/manus/.mysql_root_pass" ]; then
        MYSQL_ROOT_PASS=$(cat /opt/manus/.mysql_root_pass)
        log_info "使用已存在的 MySQL root 密码"
    else
        MYSQL_ROOT_PASS=$(gen_password 32)
        echo "$MYSQL_ROOT_PASS" > /opt/manus/.mysql_root_pass
        chmod 600 /opt/manus/.mysql_root_pass
    fi

    create_docker_network "mysql_network"

    # 轻量化 MySQL 配置（针对 1GB 内存优化）
    cat > "${MYSQL_DIR}/conf/my.cnf" << 'EOF'
[mysqld]
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
# 轻量化配置：针对 1GB 内存服务器
innodb_buffer_pool_size = 128M
innodb_log_file_size = 32M
innodb_flush_log_at_trx_commit = 2
max_connections = 50
table_open_cache = 200
max_allowed_packet = 32M
slow_query_log = 0
local_infile = 0
symbolic-links = 0
performance_schema = OFF

[client]
default-character-set = utf8mb4
EOF

    cat > "${MYSQL_DIR}/init/01-security.sql" << 'EOF'
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
FLUSH PRIVILEGES;
EOF

    cat > "${MYSQL_DIR}/docker-compose.yml" << EOF
services:
  mysql:
    image: mysql:8.0
    container_name: manus-mysql
    restart: unless-stopped
    ports:
      - "127.0.0.1:3306:3306"
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASS}
      MYSQL_ROOT_HOST: 'localhost'
      TZ: Asia/Shanghai
    volumes:
      - ./data:/var/lib/mysql
      - ./conf/my.cnf:/etc/mysql/conf.d/custom.cnf:ro
      - ./init:/docker-entrypoint-initdb.d:ro
    mem_limit: 384m
    memswap_limit: 512m
    cpus: '0.5'
    networks:
      - mysql_network
    command: >
      --default-authentication-plugin=mysql_native_password
      --skip-name-resolve
      --performance-schema=OFF

networks:
  mysql_network:
    external: true
EOF

    cd "$MYSQL_DIR"
    docker compose up -d

    # 等待 MySQL 就绪（最多 120 秒，首次初始化较慢）
    log_info "等待 MySQL 初始化完成（首次启动约需 60-90 秒）..."
    local i=0
    while [ $i -lt 24 ]; do
        if docker exec manus-mysql mysqladmin ping -h 127.0.0.1 -u root -p"${MYSQL_ROOT_PASS}" --silent 2>/dev/null; then
            break
        fi
        sleep 5
        i=$((i+1))
        printf "."
    done
    echo ""

    if [ $i -ge 24 ]; then
        log_warn "MySQL 初始化超时，可能仍在后台运行。稍后执行 'docker ps' 确认状态。"
    else
        log_success "MySQL 8.0 部署完成"
        echo -e "${GREEN}  MySQL root 密码: ${MYSQL_ROOT_PASS}${NC}"
        echo -e "${YELLOW}  密码已保存至: /opt/manus/.mysql_root_pass${NC}"
    fi
    echo ""
}
