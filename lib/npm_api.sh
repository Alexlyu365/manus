#!/bin/bash
# =============================================================================
# npm_api.sh — Nginx Proxy Manager API 操作函数库
# 项目: manus-deploy
# 功能: 通过 NPM REST API 自动创建代理规则、申请 SSL 证书，无需手动操作界面
# API 文档: http://YOUR_IP:81/api/schema
# =============================================================================

# ── NPM API 配置（从 /opt/manus/npm_credentials 读取）────────────────────────
NPM_API_BASE="http://127.0.0.1:81/api"
NPM_CREDS_FILE="/opt/manus/.npm_credentials"

# ── 获取 NPM API Token ────────────────────────────────────────────────────────
npm_get_token() {
    if [ ! -f "$NPM_CREDS_FILE" ]; then
        log_error "未找到 NPM 凭据文件: $NPM_CREDS_FILE"
        log_error "请先运行: manus npm-login"
        return 1
    fi

    local npm_email npm_password
    npm_email=$(grep "^email=" "$NPM_CREDS_FILE" | cut -d= -f2-)
    npm_password=$(grep "^password=" "$NPM_CREDS_FILE" | cut -d= -f2-)

    if [ -z "$npm_email" ] || [ -z "$npm_password" ]; then
        log_error "NPM 凭据文件格式错误，请重新运行: manus npm-login"
        return 1
    fi

    local response token
    response=$(curl -s -X POST "${NPM_API_BASE}/tokens" \
        -H "Content-Type: application/json" \
        -d "{\"identity\":\"${npm_email}\",\"secret\":\"${npm_password}\"}" \
        2>/dev/null)

    token=$(echo "$response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$token" ]; then
        log_error "NPM 登录失败，请检查账号密码是否正确"
        log_error "可以通过 manus npm-login 重新设置"
        log_error "API 响应: $response"
        return 1
    fi

    echo "$token"
}

# ── 检查域名是否已存在代理规则 ────────────────────────────────────────────────
npm_proxy_exists() {
    local domain="$1"
    local token="$2"

    local response
    response=$(curl -s -X GET "${NPM_API_BASE}/nginx/proxy-hosts" \
        -H "Authorization: Bearer ${token}" 2>/dev/null)

    echo "$response" | grep -q "\"${domain}\""
}

# ── 获取已有代理规则的 ID ─────────────────────────────────────────────────────
npm_get_proxy_id() {
    local domain="$1"
    local token="$2"

    local response
    response=$(curl -s -X GET "${NPM_API_BASE}/nginx/proxy-hosts" \
        -H "Authorization: Bearer ${token}" 2>/dev/null)

    # 找到包含该域名的记录并提取 id
    echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data:
    domains = item.get('domain_names', [])
    if '${domain}' in domains or 'www.${domain}' in domains:
        print(item['id'])
        break
" 2>/dev/null
}

# ── 创建代理规则 ──────────────────────────────────────────────────────────────
npm_create_proxy() {
    local domain="$1"
    local forward_host="$2"   # 容器名
    local forward_port="$3"   # 容器内端口
    local token="$4"
    local ssl_id="${5:-0}"    # SSL 证书 ID，0 表示无

    log_step "在 NPM 中创建代理规则: ${domain} → ${forward_host}:${forward_port}"

    # 构建域名列表（同时支持 www 子域名）
    local domain_names="[\"${domain}\", \"www.${domain}\"]"

    # SSL 配置
    local ssl_config='"certificate_id": 0, "ssl_forced": false, "http2_support": false, "hsts_enabled": false'
    if [ "$ssl_id" != "0" ] && [ -n "$ssl_id" ]; then
        ssl_config="\"certificate_id\": ${ssl_id}, \"ssl_forced\": true, \"http2_support\": true, \"hsts_enabled\": false"
    fi

    local payload
    payload=$(cat << EOF
{
    "domain_names": ${domain_names},
    "forward_scheme": "http",
    "forward_host": "${forward_host}",
    "forward_port": ${forward_port},
    "access_list_id": 0,
    "certificate_id": 0,
    "ssl_forced": false,
    "http2_support": false,
    "hsts_enabled": false,
    "hsts_subdomains": false,
    "websockets_support": false,
    "block_exploits": true,
    "allow_websocket_upgrade": true,
    "caching_enabled": true,
    "locations": [],
    "advanced_config": "client_max_body_size 500m;\nproxy_read_timeout 300s;\nproxy_connect_timeout 300s;"
}
EOF
)

    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X POST "${NPM_API_BASE}/nginx/proxy-hosts" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | head -n -1)

    if [ "$http_code" = "201" ]; then
        local proxy_id
        proxy_id=$(echo "$body" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
        log_success "代理规则创建成功 (ID: ${proxy_id})"
        echo "$proxy_id"
    else
        log_error "代理规则创建失败 (HTTP ${http_code})"
        log_error "响应: $body"
        return 1
    fi
}

# ── 申请 Let's Encrypt SSL 证书 ───────────────────────────────────────────────
npm_request_ssl() {
    local domain="$1"
    local email="$2"
    local token="$3"

    log_step "申请 SSL 证书: ${domain} (Let's Encrypt)"
    log_info "注意: 申请前请确认域名 DNS 已解析到本服务器 IP"

    local payload
    payload=$(cat << EOF
{
    "provider": "letsencrypt",
    "domain_names": ["${domain}", "www.${domain}"],
    "meta": {
        "letsencrypt_email": "${email}",
        "letsencrypt_agree": true,
        "dns_challenge": false
    }
}
EOF
)

    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X POST "${NPM_API_BASE}/nginx/certificates" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | head -n -1)

    if [ "$http_code" = "201" ]; then
        local cert_id
        cert_id=$(echo "$body" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
        log_success "SSL 证书申请成功 (ID: ${cert_id})"
        echo "$cert_id"
    else
        log_warn "SSL 证书申请失败 (HTTP ${http_code})"
        log_warn "可能原因: DNS 未解析、80 端口不可达、Let's Encrypt 频率限制"
        log_warn "响应: $body"
        log_warn "你可以稍后手动在 NPM 界面申请 SSL 证书"
        echo "0"
    fi
}

# ── 更新代理规则绑定 SSL 证书 ─────────────────────────────────────────────────
npm_update_proxy_ssl() {
    local proxy_id="$1"
    local cert_id="$2"
    local token="$3"

    if [ "$cert_id" = "0" ] || [ -z "$cert_id" ]; then
        return 0
    fi

    log_step "为代理规则 #${proxy_id} 绑定 SSL 证书 #${cert_id}..."

    local payload
    payload=$(cat << EOF
{
    "certificate_id": ${cert_id},
    "ssl_forced": true,
    "http2_support": true,
    "hsts_enabled": false
}
EOF
)

    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X PUT "${NPM_API_BASE}/nginx/proxy-hosts/${proxy_id}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    http_code=$(echo "$response" | tail -1)

    if [ "$http_code" = "200" ]; then
        log_success "SSL 已绑定，HTTPS 已启用（强制跳转）"
    else
        local body
        body=$(echo "$response" | head -n -1)
        log_warn "SSL 绑定失败 (HTTP ${http_code}): $body"
    fi
}

# ── 删除代理规则 ──────────────────────────────────────────────────────────────
npm_delete_proxy() {
    local proxy_id="$1"
    local token="$2"

    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X DELETE "${NPM_API_BASE}/nginx/proxy-hosts/${proxy_id}" \
        -H "Authorization: Bearer ${token}" 2>/dev/null)

    http_code=$(echo "$response" | tail -1)

    if [ "$http_code" = "200" ]; then
        log_success "NPM 代理规则已删除"
    else
        log_warn "NPM 代理规则删除失败 (HTTP ${http_code})"
    fi
}

# ── 保存 NPM 登录凭据 ─────────────────────────────────────────────────────────
npm_save_credentials() {
    local email="$1"
    local password="$2"

    mkdir -p /opt/manus
    cat > "$NPM_CREDS_FILE" << EOF
email=${email}
password=${password}
EOF
    chmod 600 "$NPM_CREDS_FILE"
    log_success "NPM 凭据已保存到 ${NPM_CREDS_FILE}"
}

# ── 交互式设置 NPM 凭据 ───────────────────────────────────────────────────────
npm_setup_credentials() {
    echo ""
    echo -e "${CYAN}设置 Nginx Proxy Manager 登录凭据${NC}"
    echo -e "${WHITE}（用于自动创建代理规则和申请 SSL 证书）${NC}"
    echo ""
    echo -e "${YELLOW}请先登录 NPM 界面修改默认密码后再执行此步骤${NC}"
    echo ""

    read -rp "NPM 登录邮箱: " npm_email
    read -rsp "NPM 登录密码: " npm_password
    echo ""

    # 验证凭据是否正确
    log_step "验证 NPM 凭据..."
    local response token
    response=$(curl -s -X POST "${NPM_API_BASE}/tokens" \
        -H "Content-Type: application/json" \
        -d "{\"identity\":\"${npm_email}\",\"secret\":\"${npm_password}\"}" \
        2>/dev/null)

    token=$(echo "$response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$token" ]; then
        log_error "凭据验证失败，请检查邮箱和密码是否正确"
        return 1
    fi

    npm_save_credentials "$npm_email" "$npm_password"
    log_success "NPM 凭据验证通过并已保存"
    echo ""
    echo -e "${GREEN}现在可以使用 manus deploy 一键部署网站了！${NC}"
}
