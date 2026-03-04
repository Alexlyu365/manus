#!/bin/bash
# =============================================================================
# deploy.sh — 网站一键部署核心函数库
# 项目: manus-deploy
# 功能: 读取网站仓库的 manus.config.json，自动完成容器构建、NPM 配置、SSL 申请
# =============================================================================

# ── 读取并解析 manus.config.json ──────────────────────────────────────────────
parse_site_config() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        log_error "未找到配置文件: $config_file"
        log_error "网站仓库根目录必须包含 manus.config.json"
        return 1
    fi

    # 使用 python3 解析 JSON（系统自带，无需额外安装）
    python3 - "$config_file" << 'PYEOF'
import sys, json, os

config_file = sys.argv[1]
with open(config_file) as f:
    cfg = json.load(f)

site    = cfg.get("site", {})
build   = cfg.get("build", {})
server  = cfg.get("server", {})
ssl_cfg = cfg.get("ssl", {})
db      = cfg.get("database", {})
env     = cfg.get("env", {})

domain      = site.get("domain", "")
email       = site.get("email", "")
site_type   = site.get("type", "static")

build_type  = build.get("type", "static")
source_dir  = build.get("source_dir", "dist")
build_cmd   = build.get("build_command", "")
node_ver    = build.get("node_version", "20")

port        = server.get("port", 80)
max_upload  = server.get("max_upload_size", "500m")
enable_gzip = str(server.get("enable_gzip", True)).lower()
cache_days  = server.get("cache_days", 30)

ssl_enabled = str(ssl_cfg.get("enabled", True)).lower()
force_https = str(ssl_cfg.get("force_https", True)).lower()

db_enabled  = str(db.get("enabled", False)).lower()
db_name     = db.get("name", "")
db_user     = db.get("user", "")

if not domain:
    print("ERROR: manus.config.json 中 site.domain 不能为空", file=sys.stderr)
    sys.exit(1)
if not email:
    print("ERROR: manus.config.json 中 site.email 不能为空", file=sys.stderr)
    sys.exit(1)

# 输出为 shell 变量
print(f'SITE_DOMAIN="{domain}"')
print(f'SITE_EMAIL="{email}"')
print(f'SITE_TYPE="{site_type}"')
print(f'BUILD_TYPE="{build_type}"')
print(f'BUILD_SOURCE_DIR="{source_dir}"')
print(f'BUILD_COMMAND="{build_cmd}"')
print(f'NODE_VERSION="{node_ver}"')
print(f'SERVER_PORT="{port}"')
print(f'MAX_UPLOAD_SIZE="{max_upload}"')
print(f'ENABLE_GZIP="{enable_gzip}"')
print(f'CACHE_DAYS="{cache_days}"')
print(f'SSL_ENABLED="{ssl_enabled}"')
print(f'FORCE_HTTPS="{force_https}"')
print(f'DB_ENABLED="{db_enabled}"')
print(f'DB_NAME="{db_name}"')
print(f'DB_USER="{db_user}"')

# 输出环境变量
for k, v in env.items():
    print(f'SITE_ENV_{k}="{v}"')
PYEOF
}

# ── 生成静态网站 docker-compose.yml ──────────────────────────────────────────
generate_static_compose() {
    local site_dir="$1"
    local domain="$2"
    local container_name="$3"
    local max_upload="${4:-500m}"
    local cache_days="${5:-30}"

    cat > "${site_dir}/docker-compose.yml" << EOF
version: '3.8'

services:
  web:
    image: nginx:alpine
    container_name: ${container_name}
    restart: unless-stopped
    volumes:
      - ./html:/usr/share/nginx/html:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    networks:
      - npm_network
    expose:
      - "80"
    deploy:
      resources:
        limits:
          memory: 512m
          cpus: '1.0'
    security_opt:
      - no-new-privileges:true
    read_only: false
    labels:
      - "manus.site=${domain}"
      - "manus.managed=true"

networks:
  npm_network:
    external: true
EOF

    # 生成 nginx.conf（大文件优化）
    cat > "${site_dir}/nginx.conf" << EOF
server {
    listen 80;
    server_name ${domain} www.${domain};
    root /usr/share/nginx/html;
    index index.html index.htm;

    # 大文件上传支持（图片/视频）
    client_max_body_size ${max_upload};

    # Gzip 压缩
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/javascript application/javascript
               application/json image/svg+xml;

    # 静态资源缓存（图片/视频/字体）
    location ~* \.(jpg|jpeg|png|gif|webp|svg|ico|mp4|webm|woff|woff2|ttf|otf)\$ {
        expires ${cache_days}d;
        add_header Cache-Control "public, immutable";
        add_header Vary Accept-Encoding;
    }

    # CSS/JS 缓存
    location ~* \.(css|js)\$ {
        expires 7d;
        add_header Cache-Control "public";
    }

    # SPA 路由支持（如果是 React/Vue 单页应用）
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # 安全头
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # 隐藏 nginx 版本
    server_tokens off;
}
EOF
}

# ── 生成 Node.js 网站 docker-compose.yml ─────────────────────────────────────
generate_nodejs_compose() {
    local site_dir="$1"
    local domain="$2"
    local container_name="$3"
    local port="${4:-3000}"
    local node_version="${5:-20}"

    cat > "${site_dir}/docker-compose.yml" << EOF
version: '3.8'

services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: ${container_name}
    restart: unless-stopped
    env_file:
      - .env
    networks:
      - npm_network
      - mysql_network
    expose:
      - "${port}"
    deploy:
      resources:
        limits:
          memory: 1g
          cpus: '2.0'
    security_opt:
      - no-new-privileges:true
    labels:
      - "manus.site=${domain}"
      - "manus.managed=true"

networks:
  npm_network:
    external: true
  mysql_network:
    external: true
EOF

    # 如果没有 Dockerfile，生成默认的
    if [ ! -f "${site_dir}/Dockerfile" ]; then
        cat > "${site_dir}/Dockerfile" << EOF
FROM node:${node_version}-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

FROM node:${node_version}-alpine
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY . .
EXPOSE ${port}
CMD ["node", "server.js"]
EOF
    fi
}

# ── 生成 PHP 网站 docker-compose.yml ─────────────────────────────────────────
generate_php_compose() {
    local site_dir="$1"
    local domain="$2"
    local container_name="$3"
    local max_upload="${4:-500m}"

    cat > "${site_dir}/docker-compose.yml" << EOF
version: '3.8'

services:
  web:
    image: php:8.2-apache
    container_name: ${container_name}
    restart: unless-stopped
    volumes:
      - ./html:/var/www/html:ro
      - ./php.ini:/usr/local/etc/php/conf.d/custom.ini:ro
    networks:
      - npm_network
      - mysql_network
    expose:
      - "80"
    deploy:
      resources:
        limits:
          memory: 1g
          cpus: '2.0'
    security_opt:
      - no-new-privileges:true
    labels:
      - "manus.site=${domain}"
      - "manus.managed=true"

networks:
  npm_network:
    external: true
  mysql_network:
    external: true
EOF

    # 生成 php.ini
    cat > "${site_dir}/php.ini" << EOF
upload_max_filesize = ${max_upload}
post_max_size = ${max_upload}
max_execution_time = 300
memory_limit = 256M
EOF
}

# ── 创建网站数据库 ────────────────────────────────────────────────────────────
create_site_database() {
    local db_name="$1"
    local db_user="$2"
    local domain="$3"

    if [ -z "$db_name" ]; then
        # 从域名自动生成数据库名（去掉点和横线）
        db_name=$(echo "$domain" | tr '.-' '_' | tr '[:upper:]' '[:lower:]')
    fi
    if [ -z "$db_user" ]; then
        db_user="${db_name}_user"
    fi

    # 生成随机密码
    local db_password
    db_password=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)

    log_step "创建数据库: ${db_name} / 用户: ${db_user}"

    local mysql_root_pass
    mysql_root_pass=$(cat /opt/manus/.mysql_root_pass 2>/dev/null)

    if [ -z "$mysql_root_pass" ]; then
        log_warn "未找到 MySQL root 密码，跳过数据库创建"
        return 1
    fi

    docker exec manus-mysql mysql -uroot -p"${mysql_root_pass}" << EOF 2>/dev/null
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'%' IDENTIFIED BY '${db_password}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'%';
FLUSH PRIVILEGES;
EOF

    log_success "数据库创建成功"

    # 保存数据库凭据到 .env 文件
    echo "DB_HOST=manus-mysql"      >> "$4/.env"
    echo "DB_PORT=3306"             >> "$4/.env"
    echo "DB_NAME=${db_name}"       >> "$4/.env"
    echo "DB_USER=${db_user}"       >> "$4/.env"
    echo "DB_PASSWORD=${db_password}" >> "$4/.env"

    log_info "数据库凭据已写入 .env 文件"
}

# ── 主部署函数 ────────────────────────────────────────────────────────────────
deploy_site_from_repo() {
    local repo_url="$1"
    local custom_domain="${2:-}"  # 可选：覆盖 config 中的域名

    # ── Step 1: 克隆仓库 ─────────────────────────────────────────────────────
    log_step "[1/7] 克隆网站仓库..."

    # 提取仓库名
    local repo_name
    repo_name=$(basename "$repo_url" .git)
    local tmp_dir="/tmp/manus-deploy-${repo_name}-$$"

    if ! git clone --depth=1 "$repo_url" "$tmp_dir" 2>/dev/null; then
        log_error "仓库克隆失败: $repo_url"
        log_error "请检查仓库地址是否正确，以及是否有访问权限"
        return 1
    fi
    log_success "仓库克隆成功: $tmp_dir"

    # ── Step 2: 读取配置文件 ──────────────────────────────────────────────────
    log_step "[2/7] 读取 manus.config.json..."

    local config_file="${tmp_dir}/manus.config.json"
    local config_vars
    config_vars=$(parse_site_config "$config_file") || {
        rm -rf "$tmp_dir"
        return 1
    }

    # 导入配置变量
    eval "$config_vars"

    # 允许命令行覆盖域名
    if [ -n "$custom_domain" ]; then
        SITE_DOMAIN="$custom_domain"
    fi

    log_success "配置读取成功"
    log_info "  域名: ${SITE_DOMAIN}"
    log_info "  类型: ${SITE_TYPE}"
    log_info "  邮箱: ${SITE_EMAIL}"

    # ── Step 3: 准备站点目录 ──────────────────────────────────────────────────
    log_step "[3/7] 准备站点目录..."

    local safe_name
    safe_name=$(echo "$SITE_DOMAIN" | tr '.' '-' | tr '[:upper:]' '[:lower:]')
    local container_name="site_${safe_name}"
    local site_dir="/opt/sites/${SITE_DOMAIN}"

    # 如果站点已存在，询问是否更新
    if [ -d "$site_dir" ]; then
        log_warn "站点目录已存在: $site_dir"
        if confirm "是否更新现有站点？（容器将重新构建）"; then
            log_info "更新模式：保留数据，重新部署代码"
        else
            rm -rf "$tmp_dir"
            return 0
        fi
    fi

    mkdir -p "$site_dir"

    # ── Step 4: 执行构建 ──────────────────────────────────────────────────────
    log_step "[4/7] 构建网站..."

    case "$BUILD_TYPE" in
        static)
            # 静态网站：直接复制文件
            if [ -n "$BUILD_COMMAND" ]; then
                log_info "执行构建命令: $BUILD_COMMAND"
                (cd "$tmp_dir" && eval "$BUILD_COMMAND") || {
                    log_error "构建命令执行失败"
                    rm -rf "$tmp_dir"
                    return 1
                }
            fi

            # 确定源文件目录
            local src_dir="${tmp_dir}"
            if [ -n "$BUILD_SOURCE_DIR" ] && [ -d "${tmp_dir}/${BUILD_SOURCE_DIR}" ]; then
                src_dir="${tmp_dir}/${BUILD_SOURCE_DIR}"
            fi

            mkdir -p "${site_dir}/html"
            cp -r "${src_dir}/." "${site_dir}/html/"

            # 生成 docker-compose.yml 和 nginx.conf
            generate_static_compose "$site_dir" "$SITE_DOMAIN" "$container_name" \
                "$MAX_UPLOAD_SIZE" "$CACHE_DAYS"
            ;;

        nodejs)
            # Node.js：复制整个仓库，构建镜像
            cp -r "${tmp_dir}/." "${site_dir}/"
            generate_nodejs_compose "$site_dir" "$SITE_DOMAIN" "$container_name" \
                "$SERVER_PORT" "$NODE_VERSION"
            ;;

        php)
            # PHP：复制文件
            mkdir -p "${site_dir}/html"
            cp -r "${tmp_dir}/." "${site_dir}/html/"
            generate_php_compose "$site_dir" "$SITE_DOMAIN" "$container_name" \
                "$MAX_UPLOAD_SIZE"
            ;;

        *)
            log_error "不支持的构建类型: $BUILD_TYPE"
            rm -rf "$tmp_dir"
            return 1
            ;;
    esac

    # ── Step 5: 创建数据库（如需要）──────────────────────────────────────────
    if [ "$DB_ENABLED" = "true" ]; then
        log_step "[5/7] 创建数据库..."
        touch "${site_dir}/.env"
        chmod 600 "${site_dir}/.env"
        create_site_database "$DB_NAME" "$DB_USER" "$SITE_DOMAIN" "$site_dir"
    else
        log_info "[5/7] 跳过数据库创建（未启用）"
    fi

    # ── Step 6: 启动容器 ──────────────────────────────────────────────────────
    log_step "[6/7] 启动容器..."

    # 确保 npm_network 存在
    docker network create npm_network 2>/dev/null || true

    (cd "$site_dir" && docker compose up -d --build) || {
        log_error "容器启动失败"
        rm -rf "$tmp_dir"
        return 1
    }

    # 等待容器就绪
    sleep 3
    if ! docker ps --filter "name=${container_name}" --filter "status=running" | grep -q "$container_name"; then
        log_error "容器启动后未正常运行，请检查日志: docker logs ${container_name}"
        rm -rf "$tmp_dir"
        return 1
    fi
    log_success "容器已启动: ${container_name}"

    # ── Step 7: 配置 NPM 代理规则和 SSL ──────────────────────────────────────
    log_step "[7/7] 配置 Nginx Proxy Manager..."

    # 加载 NPM API 函数库
    local npm_lib="/opt/manus/lib/npm_api.sh"
    if [ ! -f "$npm_lib" ]; then
        npm_lib="$(dirname "${BASH_SOURCE[0]}")/npm_api.sh"
    fi

    if [ ! -f "$npm_lib" ]; then
        log_warn "未找到 npm_api.sh，跳过自动 NPM 配置"
        log_warn "请手动在 NPM 界面 (http://服务器IP:81) 添加代理规则"
        _print_manual_npm_guide "$SITE_DOMAIN" "$container_name" "$SERVER_PORT"
    else
        source "$npm_lib"

        # 获取 NPM Token
        local npm_token
        npm_token=$(npm_get_token) || {
            log_warn "无法获取 NPM Token，跳过自动配置"
            log_warn "请先运行: manus npm-login"
            _print_manual_npm_guide "$SITE_DOMAIN" "$container_name" "$SERVER_PORT"
            _print_deploy_success "$SITE_DOMAIN" "$container_name" false
            rm -rf "$tmp_dir"
            return 0
        }

        # 检查是否已有代理规则
        local proxy_id
        if npm_proxy_exists "$SITE_DOMAIN" "$npm_token"; then
            log_info "代理规则已存在，跳过创建"
            proxy_id=$(npm_get_proxy_id "$SITE_DOMAIN" "$npm_token")
        else
            proxy_id=$(npm_create_proxy "$SITE_DOMAIN" "$container_name" \
                "$SERVER_PORT" "$npm_token") || {
                log_warn "NPM 代理规则创建失败，请手动配置"
                _print_manual_npm_guide "$SITE_DOMAIN" "$container_name" "$SERVER_PORT"
                _print_deploy_success "$SITE_DOMAIN" "$container_name" false
                rm -rf "$tmp_dir"
                return 0
            }
        fi

        # 申请 SSL 证书
        local cert_id="0"
        if [ "$SSL_ENABLED" = "true" ]; then
            cert_id=$(npm_request_ssl "$SITE_DOMAIN" "$SITE_EMAIL" "$npm_token")
            if [ "$cert_id" != "0" ] && [ -n "$cert_id" ]; then
                npm_update_proxy_ssl "$proxy_id" "$cert_id" "$npm_token"
            fi
        fi

        _print_deploy_success "$SITE_DOMAIN" "$container_name" \
            "$([ "$cert_id" != "0" ] && echo true || echo false)"
    fi

    # 记录站点信息
    _register_site "$SITE_DOMAIN" "$container_name" "$BUILD_TYPE" "$repo_url"

    # 清理临时目录
    rm -rf "$tmp_dir"
}

# ── 打印手动 NPM 配置指南 ─────────────────────────────────────────────────────
_print_manual_npm_guide() {
    local domain="$1"
    local container="$2"
    local port="$3"

    echo ""
    echo -e "${YELLOW}══════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  手动配置 NPM 步骤（容器已启动，只差最后一步）${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  1. 打开 NPM 管理界面: http://$(get_public_ip):81"
    echo "  2. Proxy Hosts → Add Proxy Host"
    echo "     Domain:   ${domain}  www.${domain}"
    echo "     Scheme:   http"
    echo "     Host:     ${container}"
    echo "     Port:     ${port}"
    echo "  3. SSL 标签 → Request new SSL → Force SSL → Save"
    echo ""
}

# ── 打印部署成功信息 ──────────────────────────────────────────────────────────
_print_deploy_success() {
    local domain="$1"
    local container="$2"
    local ssl_ok="$3"

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              网站部署完成！                           ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    if [ "$ssl_ok" = "true" ]; then
        echo -e "  ${GREEN}✓ 网站地址: https://${domain}${NC}"
        echo -e "  ${GREEN}✓ SSL 证书: 已自动申请并启用${NC}"
    else
        echo -e "  ${CYAN}网站地址: http://${domain}${NC}"
        echo -e "  ${YELLOW}SSL 证书: 请在 DNS 解析生效后手动申请${NC}"
    fi
    echo ""
    echo -e "  容器名: ${container}"
    echo -e "  文件目录: /opt/sites/${domain}/"
    echo ""
    echo -e "  管理命令:"
    echo -e "    ${CYAN}manus logs ${domain}${NC}     # 查看日志"
    echo -e "    ${CYAN}manus restart ${domain}${NC}  # 重启"
    echo -e "    ${CYAN}manus update ${domain}${NC}   # 从 GitHub 更新"
    echo ""
}

# ── 注册站点到 sites.conf ─────────────────────────────────────────────────────
_register_site() {
    local domain="$1"
    local container="$2"
    local type="$3"
    local repo="$4"

    local sites_conf="/opt/manus/sites.conf"
    touch "$sites_conf"

    # 如果已存在则更新，否则追加
    if grep -q "^${domain}|" "$sites_conf"; then
        sed -i "s|^${domain}|.*|${domain}|${container}|${type}|${repo}|$(date +%Y-%m-%d)|" "$sites_conf"
    else
        echo "${domain}|${container}|${type}|${repo}|$(date +%Y-%m-%d)" >> "$sites_conf"
    fi
}
