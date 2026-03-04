# manus-deploy 使用教程

> **适用系统**：Ubuntu 20.04/22.04 · Debian 11/12（推荐 Google Cloud Debian 12）
> **仓库地址**：`https://github.com/Alexlyu365/manus`（私有仓库）
> **最后更新**：2026-03-04

---

## 目录

1. [整体架构概览](#1-整体架构概览)
2. [快速开始](#2-快速开始)
3. [核心命令：网站部署](#3-核心命令网站部署)
4. [站点生命周期管理](#4-站点生命周期管理)
5. [备份与恢复](#5-备份与恢复)
6. [站点克隆与迁移](#6-站点克隆与迁移)
7. [服务器管理](#7-服务器管理)
8. [Docker 管理中心](#8-docker-管理中心)
9. [网络工具](#9-网络工具)
10. [系统工具](#10-系统工具)
11. [安全与访问控制](#11-安全与访问控制)
12. [manus.config.json 完整参考](#12-manusconfigjson-完整参考)
13. [完整命令速查表](#13-完整命令速查表)
14. [常见问题排查](#14-常见问题排查)

---

## 1. 整体架构概览

manus-deploy 采用**两层分离架构**，将服务器基础环境与网站应用完全解耦：

```
┌─────────────────────────────────────────────────────────────────┐
│                         互联网                                   │
└────────────────────────┬────────────────────────────────────────┘
                         │ 80 / 443
┌────────────────────────▼────────────────────────────────────────┐
│              Nginx Proxy Manager（统一入口）                      │
│              自动 SSL · 域名路由 · 可视化管理                      │
└──────┬──────────────────┬──────────────────┬────────────────────┘
       │                  │                  │
┌──────▼──────┐  ┌────────▼──────┐  ┌────────▼──────┐
│  网站 A      │  │  网站 B        │  │  网站 C        │
│  独立容器    │  │  独立容器      │  │  独立容器      │
│  独立网络    │  │  独立网络      │  │  独立网络      │
│  独立数据库  │  │  独立数据库    │  │  独立数据库    │
└─────────────┘  └───────────────┘  └───────────────┘
┌─────────────────────────────────────────────────────────────────┐
│  基础层：Docker · MySQL · Portainer · UFW · Fail2ban             │
└─────────────────────────────────────────────────────────────────┘
```

每个网站运行在独立的 Docker 容器中，拥有独立的网络命名空间和数据库，互不影响。所有网站统一通过 Nginx Proxy Manager 对外提供服务，由其负责 SSL 证书申请和域名路由。

---

## 2. 快速开始

### 第一步：初始化服务器（仅需一次）

在全新的 Ubuntu/Debian 服务器上执行以下命令，自动完成所有基础环境配置：

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/Alexlyu365/manus/main/server-init.sh)
```

**安装过程约 5–15 分钟**，脚本将自动完成：

| 步骤 | 内容 |
|------|------|
| 系统更新 | `apt-get update && upgrade` |
| 安装依赖 | `curl git jq openssl` 等基础工具 |
| 安装 Docker | 官方源安装 Docker Engine + Docker Compose |
| 部署 Nginx Proxy Manager | 可视化域名/SSL 管理，监听 80/443/81 端口 |
| 部署 Portainer | Docker 容器可视化管理，监听 9000 端口 |
| 部署 MySQL 8.0 | 数据库服务，仅内网访问 |
| 配置 UFW 防火墙 | 开放必要端口，修复 Docker UFW 绕过问题 |
| 安装 Fail2ban | SSH/Nginx 暴力破解防护 |
| 加固 SSH | 禁用密码登录，仅允许密钥认证 |
| 注册 manus 命令 | 全局可用 `manus` 命令 |

### 第二步：初始化后必做配置

**1. 修改 Nginx Proxy Manager 默认密码**

访问 `http://服务器IP:81`，使用默认账号登录后立即修改密码：

```
默认邮箱：admin@example.com
默认密码：changeme
```

**2. 配置 NPM 凭据（一键部署的前提）**

```bash
manus npm-login
```

按提示输入你在 NPM 界面设置的邮箱和密码。此操作只需执行一次，凭据会加密保存在服务器上。

**3. 限制管理面板访问 IP（强烈推荐）**

```bash
manus restrict-admin 你的公网IP
# 示例：manus restrict-admin 203.0.113.10
```

执行后，NPM（端口 81）和 Portainer（端口 9000）将只允许指定 IP 访问，大幅提升安全性。

---

## 3. 核心命令：网站部署

### 3.1 一键部署（推荐）

`manus deploy` 是整套系统的核心命令，能够读取网站仓库中的 `manus.config.json` 配置文件，自动完成从代码到上线的全部流程。

**语法：**
```bash
manus deploy <GitHub仓库地址> [自定义域名]
```

**示例：**
```bash
# 部署公开仓库
manus deploy https://github.com/Alexlyu365/my-product-site.git

# 部署并指定域名（覆盖配置文件中的域名）
manus deploy https://github.com/Alexlyu365/my-product-site.git shop.example.com

# 不带参数，交互式输入仓库地址
manus deploy
```

**自动完成的 7 个步骤：**

```
Step 1/7  克隆代码仓库
Step 2/7  读取 manus.config.json 配置
Step 3/7  复制网站文件到部署目录
Step 4/7  生成 Docker Compose 配置
Step 5/7  启动容器（等待健康检查通过）
Step 6/7  调用 NPM API 创建代理规则
Step 7/7  申请 Let's Encrypt SSL 证书
```

全程无需手动操作任何界面，约 2–5 分钟完成。

### 3.2 部署私有仓库

如果你的网站代码存放在 GitHub 私有仓库中，需要先配置 Personal Access Token：

```bash
# 第一步：配置 Token
manus github-token

# 第二步：正常部署（脚本自动注入认证）
manus deploy https://github.com/Alexlyu365/private-site.git
```

获取 Token 的方法：访问 `https://github.com/settings/tokens`，创建 Classic Token，勾选 `repo` 权限。

### 3.3 手动部署（交互式）

当网站仓库没有 `manus.config.json` 时，使用交互式向导逐步配置：

```bash
manus add
```

向导将依次询问：
1. 网站域名
2. 网站类型（静态 / Node.js / PHP）
3. 是否创建独立数据库
4. 是否从 Git 仓库克隆代码

### 3.4 从 Git 仓库部署（旧版交互式）

```bash
manus git
```

适用于仓库中已有自定义 `docker-compose.yml` 的情况，脚本会直接使用仓库中的配置文件启动容器。

---

## 4. 站点生命周期管理

### 4.1 查看所有站点

```bash
manus list
```

输出示例：
```
域名                                类型      状态      创建时间
────────────────────────────────────────────────────────────────
shop.example.com                    static    🟢 运行   2026-01-15
blog.example.com                    nodejs    🟢 运行   2026-02-01
api.example.com                     php       🔴 停止   2026-02-20
```

### 4.2 网站健康监控

```bash
manus monitor
```

实时检查每个站点的 HTTP 状态码、响应时间和容器运行状态：

```
域名                                HTTP状态   响应时间     容器状态
────────────────────────────────────────────────────────────────────
shop.example.com                    200        0.342s       运行中
blog.example.com                    200        0.891s       运行中
api.example.com                     000        无法连接     已停止
```

### 4.3 启动、停止、重启站点

```bash
# 启动指定站点
manus start shop.example.com

# 停止指定站点
manus stop shop.example.com

# 重启指定站点
manus restart shop.example.com

# 不带参数，交互式选择
manus start
```

### 4.4 更新站点

当网站代码在 GitHub 上有更新后，执行以下命令拉取最新代码并重新构建容器：

```bash
manus update shop.example.com
```

脚本会自动执行 `git pull` 并重新构建 Docker 镜像，做到零停机更新（旧容器继续运行直到新容器就绪）。

### 4.5 查看站点日志

```bash
# 实时查看日志（Ctrl+C 退出）
manus logs shop.example.com

# 不带参数，交互式选择站点
manus logs
```

### 4.6 删除站点

```bash
manus remove shop.example.com

# 支持别名
manus rm shop.example.com
manus delete shop.example.com
```

删除前脚本会询问是否先创建备份（强烈推荐选择是），然后依次停止容器、删除镜像、删除数据库、清理文件。

---

## 5. 备份与恢复

### 5.1 备份指定站点

```bash
manus backup shop.example.com
```

备份文件保存在 `/opt/manus/backups/` 目录，文件名格式为 `shop.example.com_20260304_143022.tar.gz`，包含网站文件和数据库导出。

### 5.2 备份所有站点

```bash
manus backup
# 选择 "备份所有站点"
```

### 5.3 查看备份列表

```bash
manus backup
# 选择 "查看备份列表"
```

输出示例：
```
备份文件列表（/opt/manus/backups/）:
────────────────────────────────────────────────────────
shop.example.com_20260304_020000.tar.gz    45M   2026-03-04
shop.example.com_20260303_020000.tar.gz    43M   2026-03-03
blog.example.com_20260304_020000.tar.gz    12M   2026-03-04
```

### 5.4 自动备份

服务器初始化时已自动配置每日凌晨 2 点执行全量备份，备份保留最近 7 天。查看定时任务：

```bash
crontab -l | grep manus
# 输出：0 2 * * * /opt/manus/manage.sh backup >> /var/log/manus-backup.log 2>&1
```

---

## 6. 站点克隆与迁移

### 6.1 克隆站点（同服务器复制到新域名）

适用场景：基于现有站点快速创建一个相同配置的新站点（如 A/B 测试、多语言版本）。

```bash
manus clone
```

交互式输入源域名和新域名，脚本自动复制所有文件和配置，并替换其中的域名引用。

### 6.2 迁移站点（跨服务器）

**导出（在旧服务器上执行）：**

```bash
manus migrate
# 选择 "导出当前站点"
# 输入要导出的域名
```

生成一个包含网站文件和数据库的压缩包，例如 `shop.example.com_export_20260304.tar.gz`。

**导入（在新服务器上执行）：**

```bash
# 先将备份文件传输到新服务器
scp shop.example.com_export_20260304.tar.gz user@新服务器IP:/tmp/

# 在新服务器上导入
manus migrate
# 选择 "导入站点"
# 输入备份文件路径：/tmp/shop.example.com_export_20260304.tar.gz
```

### 6.3 批量操作

```bash
manus batch
```

提供以下批量操作选项：

| 选项 | 操作 |
|------|------|
| 1 | 启动所有站点 |
| 2 | 停止所有站点 |
| 3 | 重启所有站点 |
| 4 | 更新所有站点（拉取 GitHub 最新代码） |
| 5 | 备份所有站点 |

---

## 7. 服务器管理

### 7.1 系统信息面板

```bash
manus sysinfo
# 或
manus info
```

显示完整的服务器状态面板，包含：

```
╔══════════════════════════════════════════════════════════════╗
║                    服务器状态面板                              ║
╚══════════════════════════════════════════════════════════════╝
  主机名:    my-server
  系统:      Debian GNU/Linux 12 (bookworm)
  内核:      6.1.0-18-amd64
  运行时间:  up 15 days, 3 hours

  CPU:       Intel(R) Xeon(R) @ 2.20GHz (2 核)
  CPU 使用:  ████░░░░░░  12%
  内存:      ████████░░  1.2G / 2.0G (62%)
  磁盘:      ███░░░░░░░  18G / 50G (36%)
  Swap:      ░░░░░░░░░░  0M / 0M

  公网 IP:   34.xxx.xxx.xxx
  内网 IP:   10.128.0.2
  DNS:       8.8.8.8, 1.1.1.1
  BBR 状态:  已启用 (bbr + fq)
```

### 7.2 系统状态总览

```bash
manus status
```

显示服务器基本信息、资源使用情况、Docker 容器状态和已部署站点列表的综合概览。

---

## 8. Docker 管理中心

```bash
manus docker
```

进入 Docker 管理交互式菜单，提供以下功能：

### 8.1 容器管理

| 操作 | 说明 |
|------|------|
| 查看所有容器 | 显示运行状态、镜像、端口 |
| 启动/停止/重启容器 | 按容器名操作 |
| 查看容器日志 | 实时日志流 |
| 进入容器终端 | `docker exec -it` |
| 删除容器 | 支持同时删除关联数据卷 |

### 8.2 镜像管理

```bash
# 在 Docker 管理菜单中选择 "镜像管理"
```

| 操作 | 说明 |
|------|------|
| 查看所有镜像 | 显示大小、创建时间 |
| 拉取镜像 | `docker pull <镜像名>` |
| 删除镜像 | 支持删除悬空镜像 |
| 清理无用镜像 | 一键清理所有 `<none>` 镜像 |

### 8.3 切换 Docker 镜像源（国内加速）

在国内服务器上，Docker Hub 拉取速度可能较慢，可切换为国内镜像源：

```bash
# 在 Docker 管理菜单中选择 "更换镜像源"
```

可选镜像源：

| 镜像源 | 地址 |
|--------|------|
| 阿里云（推荐） | `https://registry.cn-hangzhou.aliyuncs.com` |
| 腾讯云 | `https://mirror.ccs.tencentyun.com` |
| 网易 | `https://hub-mirror.c.163.com` |
| 官方（默认） | `https://registry-1.docker.io` |

### 8.4 Docker 系统清理

```bash
# 在 Docker 管理菜单中选择 "系统清理"
```

一键清理停止的容器、无用镜像、无用网络和无用数据卷，释放磁盘空间。

---

## 9. 网络工具

```bash
manus network
# 或
manus net
```

### 9.1 BBR 网络加速

BBR（Bottleneck Bandwidth and Round-trip propagation time）是 Google 开发的 TCP 拥塞控制算法，能显著提升网络吞吐量，特别适合高延迟场景。

```bash
# 在网络工具菜单中选择 "BBR 管理"
# 选择 "开启 BBR + FQ（高性能模式）"
```

开启后立即生效，无需重启。验证方式：

```bash
sysctl net.ipv4.tcp_congestion_control
# 期望输出：net.ipv4.tcp_congestion_control = bbr
```

### 9.2 DNS 优化

将系统 DNS 切换为更快速可靠的公共 DNS：

```bash
# 在网络工具菜单中选择 "DNS 优化"
```

可选方案：

| 方案 | 主 DNS | 备 DNS | 特点 |
|------|--------|--------|------|
| Cloudflare | 1.1.1.1 | 1.0.0.1 | 全球最快，注重隐私 |
| Google | 8.8.8.8 | 8.8.4.4 | 稳定可靠 |
| 阿里云 | 223.5.5.5 | 223.6.6.6 | 国内访问快 |

### 9.3 Swap 虚拟内存管理

对于内存较小（1GB 以下）的服务器，建议开启 Swap：

```bash
# 在网络工具菜单中选择 "Swap 管理"
# 选择 "创建 Swap"，推荐大小为物理内存的 1–2 倍
```

示例：1GB 内存的服务器建议创建 2GB Swap。

### 9.4 网络诊断

```bash
# 在网络工具菜单中选择 "网络诊断"
```

提供以下诊断工具：

| 工具 | 说明 |
|------|------|
| Ping 测试 | 测试到目标主机的连通性 |
| 端口检测 | 检查指定端口是否开放 |
| 路由追踪 | `traceroute` 查看网络路径 |
| DNS 解析 | 验证域名是否正确解析到本服务器 |
| 网速测试 | 使用 speedtest-cli 测试带宽 |

---

## 10. 系统工具

```bash
manus system
# 或
manus sys
```

### 10.1 系统更新

```bash
# 在系统工具菜单中选择 "系统更新"
```

执行 `apt-get update && apt-get upgrade`，更新完成后若需要重启会提示确认。

### 10.2 系统清理

```bash
# 在系统工具菜单中选择 "系统清理"
```

依次清理：apt 缓存、7 天前的旧日志、临时文件、Docker 无用资源。

### 10.3 时区设置

```bash
# 在系统工具菜单中选择 "时区设置"
```

提供常用时区快速选择，也支持手动输入任意时区（如 `Asia/Shanghai`）。

### 10.4 SSL 证书到期检查

```bash
manus ssl-check
```

检查所有托管站点的 SSL 证书到期时间，并以颜色区分状态：

```
域名                                到期状态         到期日期
────────────────────────────────────────────────────────────
shop.example.com                    89天后到期       2026-06-01
blog.example.com                    12天后到期       2026-03-16  ⚠️
api.example.com                     已过期           2026-02-28  ❌
```

### 10.5 日志管理

```bash
# 在系统工具菜单中选择 "日志管理"
```

| 功能 | 说明 |
|------|------|
| 查看系统日志 | `journalctl` 最近 50 行 |
| 查看 Docker 日志 | 按容器名查看 |
| 查看 Nginx 日志 | NPM 容器的访问日志 |
| 清理旧日志 | 删除 7 天前的日志文件 |
| 清理 systemd 日志 | 保留最近 3 天 |
| 设置日志轮转 | 配置每日自动轮转，保留 7 天 |

### 10.6 更新 manus 脚本自身

```bash
manus self-update
# 或
manus update-self
```

从 GitHub 拉取最新版本的脚本，自动保留本地配置（sites.conf、NPM 凭据等），更新后显示变更日志。

---

## 11. 安全与访问控制

### 11.1 限制管理面板访问 IP

```bash
manus restrict-admin <你的公网IP>

# 示例
manus restrict-admin 203.0.113.10

# 允许多个 IP（用逗号分隔）
manus restrict-admin 203.0.113.10,198.51.100.20
```

此命令通过 UFW 规则限制 Nginx Proxy Manager（端口 81）和 Portainer（端口 9000）只允许指定 IP 访问。

### 11.2 查看 Fail2ban 状态

Fail2ban 在服务器初始化时已自动配置，保护 SSH 和 Nginx：

```bash
# 查看 SSH 封禁状态
fail2ban-client status sshd

# 查看 Nginx 封禁状态
fail2ban-client status nginx-http-auth

# 手动解封某个 IP
fail2ban-client set sshd unbanip 203.0.113.10
```

封禁规则：
- SSH：3 次失败后封禁 2 小时
- Nginx：5 次失败后封禁 1 小时

### 11.3 GitHub Token 管理

```bash
manus github-token
```

提供以下操作：
- 配置新 Token（用于访问私有仓库）
- 更新现有 Token
- 删除 Token（恢复公开仓库模式）

Token 以 600 权限保存在 `/opt/manus/.github_token`，只有 root 可读。

---

## 12. manus.config.json 完整参考

每个网站仓库的根目录必须包含此配置文件，Manus 生成网站时会自动创建。

```json
{
  "site": {
    "domain": "shop.example.com",     // 必填：网站域名
    "email": "admin@example.com",     // 必填：SSL 证书申请邮箱
    "type": "static",                 // 网站类型：static / nodejs / php
    "description": "产品展示网站"      // 可选：描述
  },

  "build": {
    "type": "static",                 // 构建类型：static / nodejs / php
    "source_dir": "dist",             // 网站文件目录（相对于仓库根目录）
    "build_command": "",              // 构建命令（Node.js 项目需要，如 "npm run build"）
    "node_version": "20"              // Node.js 版本（仅 nodejs 类型需要）
  },

  "server": {
    "port": 80,                       // 容器内部监听端口
    "max_upload_size": "500m",        // 最大上传文件大小（图片/视频）
    "enable_gzip": true,              // 是否启用 Gzip 压缩
    "enable_cache": true,             // 是否启用静态文件缓存
    "cache_days": 30                  // 静态文件缓存天数
  },

  "ssl": {
    "enabled": true,                  // 是否申请 SSL 证书
    "force_https": true,              // 是否强制 HTTP 跳转 HTTPS
    "http2": true                     // 是否启用 HTTP/2
  },

  "database": {
    "enabled": false,                 // 是否创建独立数据库
    "name": "shop_db",                // 数据库名（enabled 为 true 时必填）
    "user": "shop_user"               // 数据库用户名
  },

  "env": {
    "APP_ENV": "production",          // 自定义环境变量（注入到容器）
    "API_KEY": "your-api-key"
  }
}
```

**各类型网站的典型配置：**

**静态网站（产品展示）：**
```json
{
  "site": { "domain": "shop.example.com", "email": "admin@example.com", "type": "static" },
  "build": { "type": "static", "source_dir": "dist" },
  "server": { "max_upload_size": "500m", "cache_days": 30 },
  "ssl": { "enabled": true, "force_https": true },
  "database": { "enabled": false }
}
```

**Node.js 应用（需要构建）：**
```json
{
  "site": { "domain": "app.example.com", "email": "admin@example.com", "type": "nodejs" },
  "build": { "type": "nodejs", "source_dir": ".", "build_command": "npm run build", "node_version": "20" },
  "server": { "port": 3000 },
  "ssl": { "enabled": true, "force_https": true },
  "database": { "enabled": true, "name": "app_db", "user": "app_user" }
}
```

**PHP 应用：**
```json
{
  "site": { "domain": "cms.example.com", "email": "admin@example.com", "type": "php" },
  "build": { "type": "php", "source_dir": "." },
  "server": { "port": 80, "max_upload_size": "500m" },
  "ssl": { "enabled": true, "force_https": true },
  "database": { "enabled": true, "name": "cms_db", "user": "cms_user" }
}
```

---

## 13. 完整命令速查表

### 网站管理命令

| 命令 | 说明 | 示例 |
|------|------|------|
| `manus deploy <仓库>` | ★ 一键全自动部署 | `manus deploy https://github.com/user/site.git` |
| `manus add` | 手动交互式部署 | `manus add` |
| `manus git` | 从 Git 仓库部署（旧版） | `manus git` |
| `manus list` | 查看所有站点 | `manus list` |
| `manus monitor` | 网站健康监控 | `manus monitor` |
| `manus start <域名>` | 启动站点 | `manus start shop.example.com` |
| `manus stop <域名>` | 停止站点 | `manus stop shop.example.com` |
| `manus restart <域名>` | 重启站点 | `manus restart shop.example.com` |
| `manus update <域名>` | 更新站点代码并重建 | `manus update shop.example.com` |
| `manus logs <域名>` | 查看站点实时日志 | `manus logs shop.example.com` |
| `manus backup [域名]` | 备份站点（不填则全部） | `manus backup shop.example.com` |
| `manus remove <域名>` | 删除站点 | `manus remove shop.example.com` |
| `manus clone` | 克隆站点到新域名 | `manus clone` |
| `manus migrate` | 跨服务器迁移站点 | `manus migrate` |
| `manus batch` | 批量操作所有站点 | `manus batch` |

### 服务器管理命令

| 命令 | 说明 | 示例 |
|------|------|------|
| `manus sysinfo` | 系统信息面板 | `manus sysinfo` |
| `manus status` | 系统状态总览 | `manus status` |
| `manus docker` | Docker 管理中心 | `manus docker` |
| `manus network` | 网络工具（BBR/DNS/Swap） | `manus network` |
| `manus system` | 系统工具（更新/清理/时区） | `manus system` |
| `manus ssl-check` | SSL 证书到期检查 | `manus ssl-check` |

### 工具命令

| 命令 | 说明 | 示例 |
|------|------|------|
| `manus npm-login` | 设置 NPM 登录凭据 | `manus npm-login` |
| `manus github-token` | 配置 GitHub 私有仓库 Token | `manus github-token` |
| `manus restrict-admin <IP>` | 限制管理面板访问 IP | `manus restrict-admin 203.0.113.10` |
| `manus self-update` | 更新 manus 脚本自身 | `manus self-update` |
| `manus help` | 显示帮助信息 | `manus help` |
| `manus` | 进入交互式主菜单 | `manus` |

---

## 14. 常见问题排查

### Q1：执行 `manus deploy` 后提示 "NPM 凭据未配置"

**原因**：未执行 `manus npm-login` 配置 Nginx Proxy Manager 的登录凭据。

**解决**：
```bash
manus npm-login
# 输入 NPM 管理界面的邮箱和密码
```

### Q2：SSL 证书申请失败

**原因**：域名尚未解析到服务器 IP，或 DNS 解析尚未生效。

**解决**：
```bash
# 验证域名是否已解析到服务器
manus network
# 选择 "网络诊断" → "DNS 解析"

# 或直接使用 dig 命令
dig +short shop.example.com
# 应输出服务器的公网 IP
```

DNS 解析通常需要 5–30 分钟生效，解析生效后重新执行 `manus deploy` 即可。

### Q3：容器启动后无法访问网站

**原因**：可能是端口冲突或容器内部错误。

**解决**：
```bash
# 查看容器日志
manus logs shop.example.com

# 查看所有容器状态
manus docker
# 选择 "查看全局状态"
```

### Q4：Google Cloud 服务器无法访问 NPM 管理界面（端口 81）

**原因**：Google Cloud 有独立的 VPC 防火墙，需要在控制台手动开放端口。

**解决**：登录 Google Cloud Console → VPC 网络 → 防火墙规则 → 创建规则，开放 TCP 端口 81 和 9000。

### Q5：`manus deploy` 提示 "克隆仓库失败"

**原因**：私有仓库未配置 Token，或 Token 已过期。

**解决**：
```bash
manus github-token
# 更新 GitHub Personal Access Token
```

### Q6：磁盘空间不足

**解决**：
```bash
# 清理 Docker 无用资源
manus docker
# 选择 "系统清理"

# 清理系统日志和临时文件
manus system
# 选择 "系统清理"

# 查看各目录占用
du -sh /opt/manus/sites/* 2>/dev/null | sort -rh | head -10
du -sh /opt/manus/backups/* 2>/dev/null | sort -rh | head -10
```

### Q7：忘记 MySQL root 密码

```bash
# 密码保存在此文件中
cat /opt/manus/.mysql_root_password
```

### Q8：忘记 NPM 管理员密码

在 NPM 管理界面（`http://服务器IP:81`）点击 "Forgot Password" 重置，或重新执行 `manus npm-login` 更新本地保存的凭据。

---

*本文档由 Manus AI 生成，与 manus-deploy 脚本同步更新。*
*如有问题，请查看 [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) 或 [SECURITY_AUDIT.md](./SECURITY_AUDIT.md)。*
