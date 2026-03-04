#!/bin/bash
# =============================================================================
# docker.sh — Docker 安装与管理函数库
# 项目: manus-deploy
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

            # 添加 Docker 官方 GPG 密钥
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/${OS_ID}/gpg \
                | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg

            # 添加 Docker 软件源
            echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
                https://download.docker.com/linux/${OS_ID} \
                $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
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

# ── 配置 Docker 守护进程（日志限制、镜像加速）────────────────────────────────
configure_docker_daemon() {
    log_step "配置 Docker 守护进程..."

    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  },
  "storage-driver": "overlay2",
  "live-restore": true
}
EOF

    systemctl daemon-reload
    systemctl restart docker
    log_success "Docker 守护进程配置完成"
}

# ── 创建 Docker 网络 ─────────────────────────────────────────────────────────
create_docker_network() {
    local network_name="$1"
    if ! docker network ls | grep -q "$network_name"; then
        docker network create "$network_name"
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
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager
    restart: unless-stopped
    ports:
      - "80:80"       # HTTP
      - "443:443"     # HTTPS
      - "81:81"       # NPM 管理界面
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    networks:
      - npm_network
    environment:
      - DISABLE_IPV6=true

networks:
  npm_network:
    external: true
EOF

    cd "$NPM_DIR"
    docker compose up -d

    log_success "Nginx Proxy Manager 部署完成"
    echo ""
    echo -e "${GREEN}  NPM 管理界面: http://$(get_public_ip):81${NC}"
    echo -e "${YELLOW}  默认账号: admin@example.com${NC}"
    echo -e "${YELLOW}  默认密码: changeme${NC}"
    echo -e "${YELLOW}  !! 请登录后立即修改默认密码 !!${NC}"
    echo ""
}

# ── 部署 Portainer（Docker 可视化管理面板）──────────────────────────────────
deploy_portainer() {
    log_step "部署 Portainer（Docker 可视化管理面板）..."

    local PORTAINER_DIR="/opt/manus/portainer"
    mkdir -p "${PORTAINER_DIR}/data"

    cat > "${PORTAINER_DIR}/docker-compose.yml" << 'EOF'
version: '3.8'

services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports:
      - "9000:9000"
      - "9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
    networks:
      - npm_network

networks:
  npm_network:
    external: true
EOF

    cd "$PORTAINER_DIR"
    docker compose up -d

    log_success "Portainer 部署完成"
    echo ""
    echo -e "${GREEN}  Portainer 管理界面: http://$(get_public_ip):9000${NC}"
    echo -e "${YELLOW}  首次访问请在 5 分钟内设置管理员密码${NC}"
    echo ""
}

# ── 部署 MySQL（全局共享实例，每站独立数据库）────────────────────────────────
deploy_mysql() {
    log_step "部署 MySQL 8.0 数据库..."

    local MYSQL_DIR="/opt/manus/mysql"
    mkdir -p "${MYSQL_DIR}/data" "${MYSQL_DIR}/conf" "${MYSQL_DIR}/init"

    # 生成 root 密码
    local MYSQL_ROOT_PASS
    if [ -f "/opt/manus/.mysql_root_pass" ]; then
        MYSQL_ROOT_PASS=$(cat /opt/manus/.mysql_root_pass)
        log_info "使用已存在的 MySQL root 密码"
    else
        MYSQL_ROOT_PASS=$(gen_password 24)
        echo "$MYSQL_ROOT_PASS" > /opt/manus/.mysql_root_pass
        chmod 600 /opt/manus/.mysql_root_pass
    fi

    # MySQL 优化配置（针对产品展示类网站）
    cat > "${MYSQL_DIR}/conf/my.cnf" << 'EOF'
[mysqld]
# 字符集
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

# 连接
max_connections = 200
wait_timeout = 600
interactive_timeout = 600

# 缓存（根据服务器内存调整）
innodb_buffer_pool_size = 256M
innodb_log_file_size = 64M
innodb_flush_log_at_trx_commit = 2

# 大文件支持（媒体元数据）
max_allowed_packet = 64M

# 慢查询日志
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2

[client]
default-character-set = utf8mb4
EOF

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
      MYSQL_ROOT_HOST: '%'
      TZ: Asia/Shanghai
    volumes:
      - ./data:/var/lib/mysql
      - ./conf/my.cnf:/etc/mysql/conf.d/custom.cnf:ro
      - ./init:/docker-entrypoint-initdb.d
    networks:
      - npm_network
    command: >
      --default-authentication-plugin=mysql_native_password
      --character-set-server=utf8mb4
      --collation-server=utf8mb4_unicode_ci

networks:
  npm_network:
    external: true
EOF

    cd "$MYSQL_DIR"
    docker compose up -d

    # 等待 MySQL 就绪
    wait_for_service "127.0.0.1" "3306" 60

    log_success "MySQL 8.0 部署完成"
    echo ""
    echo -e "${GREEN}  MySQL 地址: 127.0.0.1:3306（仅本机访问）${NC}"
    echo -e "${GREEN}  MySQL root 密码已保存至: /opt/manus/.mysql_root_pass${NC}"
    echo ""
}

# ── 为站点创建独立 MySQL 数据库和用户 ────────────────────────────────────────
create_site_database() {
    local domain="$1"
    # 将域名转为合法的数据库名（去掉点和特殊字符）
    local db_name
    db_name=$(echo "$domain" | tr '.' '_' | tr '-' '_' | tr '[:upper:]' '[:lower:]')
    db_name="site_${db_name}"

    local db_user="${db_name}_user"
    local db_pass
    db_pass=$(gen_password 20)

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
        GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'%';
        FLUSH PRIVILEGES;
    " 2>/dev/null

    # 保存数据库信息到站点目录
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
