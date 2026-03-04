#!/bin/bash
# =============================================================================
# docker.sh — Docker 安装与管理函数库（安全加固版）
# 项目: manus-deploy
# 支持系统: Ubuntu 20.04/22.04/24.04, Debian 11/12 (Bookworm)
# 修订: SEC-01 Docker Socket Proxy、SEC-05 MySQL root host、SEC-08 资源限制
#       Debian 12 适配: Docker 官方源 codename 获取方式
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
            # 移除旧版本
            apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

            # 安装 GPG 依赖
            apt-get install -y ca-certificates curl gnupg lsb-release

            # 创建密钥目录
            install -m 0755 -d /etc/apt/keyrings

            # 添加 Docker 官方 GPG 密钥
            curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
                | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg

            # ── Debian 12 关键适配 ────────────────────────────────────────────
            # Debian 12 的 VERSION_CODENAME=bookworm，Docker 官方源支持 bookworm。
            # 但 lsb_release -cs 在 Debian 12 上返回 "bookworm"，与 Ubuntu 返回
            # "jammy" 的方式一致，所以可以统一使用 $(. /etc/os-release && echo "$VERSION_CODENAME")
            # 注意: 不能使用 $(lsb_release -cs)，因为 Debian 最小安装可能没有 lsb-release
            local codename
            codename=$(. /etc/os-release && echo "${VERSION_CODENAME}")
            if [ -z "$codename" ]; then
                # 回退：通过 lsb_release 获取
                codename=$(lsb_release -cs 2>/dev/null || echo "bookworm")
            fi

            log_info "使用 Docker 源 codename: ${codename}"

            # 添加 Docker 软件源
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

    # 启动并设置开机自启
    systemctl enable docker
    systemctl start docker

    # 验证安装
    if command_exists docker; then
        log_success "Docker 安装成功: $(docker --version)"
    else
        log_error "Docker 安装失败，请手动检查"
        exit 1
    fi
}

# ── 配置 Docker 守护进程（日志限制、安全加固）────────────────────────────────
configure_docker_daemon() {
    log_step "配置 Docker 守护进程（安全加固）..."

    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  },
  "storage-driver": "overlay2",
  "live-restore": true,
  "no-new-privileges": true,
  "userland-proxy": false
}
EOF
    # 说明:
    # no-new-privileges: 防止容器内进程通过 setuid/setgid 提升权限
    # userland-proxy: 禁用用户空间代理，使用 iptables 规则替代，减少攻击面
    # live-restore: 重启 Docker 时容器继续运行

    systemctl daemon-reload
    systemctl restart docker
    log_success "Docker 守护进程配置完成（安全加固）"
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

# ── 部署 Nginx Proxy Manager ─────────────────────────────────────────────────
deploy_nginx_proxy_manager() {
    log_step "部署 Nginx Proxy Manager（可视化反向代理）..."

    local NPM_DIR="/opt/manus/nginx-proxy-manager"
    mkdir -p "${NPM_DIR}/data" "${NPM_DIR}/letsencrypt"

    # 创建共享网络（所有站点容器都接入此网络）
    create_docker_network "npm_network"

    cat > "${NPM_DIR}/docker-compose.yml" << 'EOF'
version: '3.8'

services:
  npm:
    image: jc21/nginx-proxy-manager:2.11.3
    container_name: nginx-proxy-manager
    restart: unless-stopped
    ports:
      - "80:80"       # HTTP
      - "443:443"     # HTTPS
      - "81:81"       # NPM 管理界面（建议后续改为 IP 白名单）
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    networks:
      - npm_network
    environment:
      - DISABLE_IPV6=true
    # SEC-08: 资源限制，防止单容器耗尽服务器资源
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: '1.0'
        reservations:
          memory: 128M
    # SEC-04: 健康检查
    healthcheck:
      test: ["CMD", "/bin/check-health"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  npm_network:
    external: true
EOF

    cd "$NPM_DIR"
    docker compose up -d

    log_success "Nginx Proxy Manager 部署完成（版本已锁定 2.11.3）"
    echo ""
    echo -e "${GREEN}  NPM 管理界面: http://$(get_public_ip):81${NC}"
    echo -e "${YELLOW}  默认账号: admin@example.com${NC}"
    echo -e "${YELLOW}  默认密码: changeme${NC}"
    echo -e "${RED}  !! 请登录后立即修改默认密码 !!${NC}"
    echo ""
}

# ── SEC-01 修复: 使用 Docker Socket Proxy 保护 Portainer ─────────────────────
deploy_portainer() {
    log_step "部署 Portainer（通过 Docker Socket Proxy 安全访问）..."

    local PORTAINER_DIR="/opt/manus/portainer"
    mkdir -p "${PORTAINER_DIR}/data"

    cat > "${PORTAINER_DIR}/docker-compose.yml" << 'EOF'
version: '3.8'

services:
  # ── Docker Socket Proxy（安全代理，限制 Docker API 访问权限）────────────────
  socket-proxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: docker-socket-proxy
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      CONTAINERS: 1
      SERVICES: 1
      TASKS: 1
      NETWORKS: 1
      VOLUMES: 1
      INFO: 1
      IMAGES: 1
      NODES: 1
      EVENTS: 1
      PING: 1
      VERSION: 1
      POST: 1
      EXEC: 0
      BUILD: 0
      COMMIT: 0
      CONFIGS: 0
      DISTRIBUTION: 0
      PLUGINS: 0
      SECRETS: 0
      SWARM: 0
    networks:
      - socket_proxy_network
    deploy:
      resources:
        limits:
          memory: 64M
          cpus: '0.25'

  portainer:
    image: portainer/portainer-ce:2.21.5
    container_name: portainer
    restart: unless-stopped
    ports:
      - "9000:9000"
      - "9443:9443"
    volumes:
      - ./data:/data
    environment:
      - DOCKER_HOST=tcp://socket-proxy:2375
    networks:
      - npm_network
      - socket_proxy_network
    depends_on:
      - socket-proxy
    deploy:
      resources:
        limits:
          memory: 256M
          cpus: '0.5'

networks:
  npm_network:
    external: true
  socket_proxy_network:
    driver: bridge
    internal: true
EOF

    cd "$PORTAINER_DIR"
    docker compose up -d

    log_success "Portainer 部署完成（通过 Docker Socket Proxy 安全访问）"
    echo ""
    echo -e "${GREEN}  Portainer 管理界面: http://$(get_public_ip):9000${NC}"
    echo -e "${YELLOW}  首次访问请在 5 分钟内设置管理员密码${NC}"
    echo ""
}

# ── SEC-05 修复: 部署 MySQL（修复 root host 配置）────────────────────────────
deploy_mysql() {
    log_step "部署 MySQL 8.0 数据库（安全加固版）..."

    local MYSQL_DIR="/opt/manus/mysql"
    mkdir -p "${MYSQL_DIR}/data" "${MYSQL_DIR}/conf" "${MYSQL_DIR}/init"

    # 生成 root 密码
    local MYSQL_ROOT_PASS
    if [ -f "/opt/manus/.mysql_root_pass" ]; then
        MYSQL_ROOT_PASS=$(cat /opt/manus/.mysql_root_pass)
        log_info "使用已存在的 MySQL root 密码"
    else
        MYSQL_ROOT_PASS=$(gen_password 32)
        echo "$MYSQL_ROOT_PASS" > /opt/manus/.mysql_root_pass
        chmod 600 /opt/manus/.mysql_root_pass
    fi

    # 创建 MySQL 专用网络
    create_docker_network "mysql_network"

    cat > "${MYSQL_DIR}/conf/my.cnf" << 'EOF'
[mysqld]
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
max_connections = 200
wait_timeout = 600
interactive_timeout = 600
innodb_buffer_pool_size = 256M
innodb_log_file_size = 64M
innodb_flush_log_at_trx_commit = 2
max_allowed_packet = 64M
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2
local_infile = 0
symbolic-links = 0

[client]
default-character-set = utf8mb4
EOF

    cat > "${MYSQL_DIR}/init/01-security-hardening.sql" << 'EOF'
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
FLUSH PRIVILEGES;
EOF
    chmod 644 "${MYSQL_DIR}/init/01-security-hardening.sql"

    cat > "${MYSQL_DIR}/docker-compose.yml" << EOF
version: '3.8'

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
    deploy:
      resources:
        limits:
          memory: 1G
          cpus: '1.0'
        reservations:
          memory: 256M
    networks:
      - mysql_network
    command: >
      --default-authentication-plugin=mysql_native_password
      --character-set-server=utf8mb4
      --collation-server=utf8mb4_unicode_ci
      --local-infile=0
      --symbolic-links=0
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p${MYSQL_ROOT_PASS}"]
      interval: 30s
      timeout: 10s
      retries: 5

networks:
  mysql_network:
    external: true
EOF

    cd "$MYSQL_DIR"
    docker compose up -d

    wait_for_service "127.0.0.1" "3306" 60

    log_success "MySQL 8.0 部署完成（安全加固：root 仅本机，独立网络）"
    echo ""
    echo -e "${GREEN}  MySQL 地址: 127.0.0.1:3306（仅本机访问）${NC}"
    echo -e "${GREEN}  MySQL root 密码已保存至: /opt/manus/.mysql_root_pass${NC}"
    echo ""
}

# ── 为站点创建独立 MySQL 数据库和用户 ────────────────────────────────────────
create_site_database() {
    local domain="$1"
    local db_name
    db_name=$(echo "$domain" | tr '.' '_' | tr '-' '_' | tr '[:upper:]' '[:lower:]')
    db_name="site_${db_name}"

    local db_user="${db_name}_user"
    local db_pass
    db_pass=$(gen_password 24)

    local root_pass
    root_pass=$(cat /opt/manus/.mysql_root_pass 2>/dev/null)

    if [ -z "$root_pass" ]; then
        log_warn "未找到 MySQL root 密码，跳过数据库创建"
        return 1
    fi

    log_step "为站点 ${domain} 创建独立数据库..."

    docker exec manus-mysql mysql -u root -p"${root_pass}" -e "
        CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE USER IF NOT EXISTS '${db_user}'@'%' IDENTIFIED BY '${db_pass}';
        GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER, CREATE TEMPORARY TABLES ON \`${db_name}\`.* TO '${db_user}'@'%';
        FLUSH PRIVILEGES;
    " 2>/dev/null

    local site_dir="/opt/sites/${domain}"
    mkdir -p "$site_dir"
    cat > "${site_dir}/.db_info" << EOF
DB_HOST=manus-mysql
DB_PORT=3306
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASS=${db_pass}
EOF
    chmod 600 "${site_dir}/.db_info"

    log_success "数据库 ${db_name} 创建完成，信息已保存至 ${site_dir}/.db_info"
    echo "$db_pass"
}

# ── 删除站点数据库 ───────────────────────────────────────────────────────────
drop_site_database() {
    local domain="$1"
    local db_name
    db_name=$(echo "$domain" | tr '.' '_' | tr '-' '_' | tr '[:upper:]' '[:lower:]')
    db_name="site_${db_name}"
    local db_user="${db_name}_user"

    local root_pass
    root_pass=$(cat /opt/manus/.mysql_root_pass 2>/dev/null)
    [ -z "$root_pass" ] && return

    docker exec manus-mysql mysql -u root -p"${root_pass}" -e "
        DROP DATABASE IF EXISTS \`${db_name}\`;
        DROP USER IF EXISTS '${db_user}'@'%';
        FLUSH PRIVILEGES;
    " 2>/dev/null

    log_info "已删除站点 ${domain} 的数据库"
}

# ── 将站点容器接入 MySQL 网络 ─────────────────────────────────────────────────
connect_site_to_mysql() {
    local container_name="$1"
    docker network connect mysql_network "$container_name" 2>/dev/null || true
    log_info "站点容器 ${container_name} 已接入 MySQL 网络"
}
