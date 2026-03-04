# Manus Deploy — 一键服务器部署系统

> 一套为产品展示、图片展示、视频展示类网站设计的自动化 Linux 服务器部署与多站点管理系统。
> 支持在单台服务器上部署多个网站，站点之间完全隔离、互不影响。

---

## 目录

- [系统架构](#系统架构)
- [快速开始](#快速开始)
- [服务器初始化](#服务器初始化)
- [部署网站](#部署网站)
- [日常管理命令](#日常管理命令)
- [管理面板访问](#管理面板访问)
- [目录结构说明](#目录结构说明)
- [网站类型说明](#网站类型说明)
- [与 Manus 开发的网站配合使用](#与-manus-开发的网站配合使用)
- [常见问题](#常见问题)

---

## 系统架构

```
互联网
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│  服务器 (Ubuntu 20.04/22.04/24.04)                       │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  Nginx Proxy Manager (端口 80/443/81)            │   │
│  │  统一处理所有域名的 HTTP/HTTPS 请求               │   │
│  │  自动申请 Let's Encrypt SSL 证书                  │   │
│  └──────┬──────────────┬──────────────┬─────────────┘   │
│         │              │              │                  │
│         ▼              ▼              ▼                  │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐          │
│  │ 站点A容器  │ │ 站点B容器  │ │ 站点C容器  │          │
│  │ site_a.com │ │ site_b.com │ │ site_c.com │          │
│  │ (独立网络) │ │ (独立网络) │ │ (独立网络) │          │
│  └────────────┘ └────────────┘ └────────────┘          │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  MySQL 8.0 (仅本机访问，端口 3306)               │   │
│  │  每个站点拥有独立的数据库和用户                   │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  Portainer (端口 9000) — Docker 可视化管理        │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### 技术栈

| 组件 | 技术 | 说明 |
|------|------|------|
| 容器化 | Docker + Docker Compose | 每个网站独立容器，互不影响 |
| 反向代理 | Nginx Proxy Manager | 可视化管理域名、SSL、端口转发 |
| SSL 证书 | Let's Encrypt | 自动申请和续期 HTTPS 证书 |
| 数据库 | MySQL 8.0 | 每站独立数据库，仅本机访问 |
| 防火墙 | UFW | 自动配置端口规则 |
| 监控 | Portainer | Docker 容器可视化管理面板 |
| 备份 | 自动定时脚本 | 每日凌晨 3:00 自动备份 |

---

## 快速开始

### 第一步：初始化服务器（仅需执行一次）

在全新的 Ubuntu 服务器上以 root 用户执行：

```bash
bash <(curl -s https://raw.githubusercontent.com/Alexlyu365/manus/main/server-init.sh)
```

脚本将自动完成所有基础环境配置，约需 5-10 分钟。

### 第二步：部署网站

```bash
manus add
```

按照交互式提示输入域名和网站类型，即可完成部署。

### 第三步：配置域名代理

在 Nginx Proxy Manager 管理界面（`http://服务器IP:81`）中添加代理规则并申请 SSL 证书。

---

## 服务器初始化

### 系统要求

| 项目 | 最低要求 | 推荐配置 |
|------|---------|---------|
| 操作系统 | Ubuntu 20.04 LTS | Ubuntu 22.04 LTS |
| CPU | 1 核 | 2 核以上 |
| 内存 | 1 GB | 2 GB 以上 |
| 磁盘 | 20 GB | 50 GB 以上（视媒体文件量） |
| 网络 | 公网 IP | 公网 IP + 已解析域名 |

### 初始化内容

执行 `server-init.sh` 后，服务器将完成以下配置：

1. **系统更新** — 更新所有软件包至最新版本
2. **基础工具** — 安装 curl、git、vim、htop 等常用工具
3. **Docker Engine** — 安装最新版 Docker，配置日志限制和自动重启
4. **系统优化** — 调整内核参数（TCP 连接、文件描述符等）
5. **UFW 防火墙** — 开放 22/80/443/81/9000 端口，其余拒绝
6. **Nginx Proxy Manager** — 部署可视化反向代理（端口 81）
7. **Portainer** — 部署 Docker 可视化管理面板（端口 9000）
8. **MySQL 8.0** — 部署数据库，生成随机 root 密码并保存
9. **自动备份** — 配置每日凌晨 3:00 自动备份所有站点
10. **manus 命令** — 安装到 `/usr/local/bin/manus`，全局可用

---

## 部署网站

### 方式一：交互式部署（推荐）

```bash
manus add
```

按提示输入域名和选择网站类型，脚本自动完成：
- 创建站点目录 `/opt/sites/域名/`
- 生成 Docker Compose 配置
- 创建独立数据库（可选）
- 生成 `.env` 环境变量文件
- 启动容器

### 方式二：从 Git 仓库部署

```bash
manus git
```

输入 Git 仓库地址和域名，自动克隆代码并部署。若仓库中已有 `docker-compose.yml`，将直接使用；否则按选择的类型自动生成配置。

### 部署后操作

站点容器启动后，需要在 **Nginx Proxy Manager** 中添加代理规则：

1. 打开 `http://服务器IP:81`，登录管理界面
2. 点击 **Proxy Hosts** → **Add Proxy Host**
3. 填写信息：
   - **Domain Names**: 你的域名（如 `example.com`）
   - **Forward Hostname/IP**: 容器名（如 `site_example_com`）
   - **Forward Port**: 容器端口（静态网站填 `80`，其他类型填部署时显示的端口）
4. 切换到 **SSL** 标签页：
   - 选择 **Request a new SSL Certificate**
   - 勾选 **Force SSL**
   - 点击 **Save**

SSL 证书将自动申请，通常在 30 秒内完成。

---

## 日常管理命令

所有命令均可直接在服务器上执行，或通过 `manus` 交互式菜单操作。

```bash
# 查看所有命令
manus help

# 进入交互式菜单
manus

# 查看所有站点状态
manus list

# 查看系统总览（CPU/内存/磁盘/容器状态）
manus status

# 启动 / 停止 / 重启站点
manus start example.com
manus stop example.com
manus restart example.com

# 更新站点（重新拉取代码并重建容器）
manus update example.com

# 查看站点实时日志
manus logs example.com

# 备份指定站点
manus backup example.com

# 备份所有站点
manus backup

# 删除站点（会提示是否先备份）
manus remove example.com

# 更新 manus 工具自身
manus self-update
```

---

## 管理面板访问

初始化完成后，可通过以下地址访问管理面板：

| 面板 | 地址 | 默认账号 | 默认密码 |
|------|------|---------|---------|
| Nginx Proxy Manager | `http://服务器IP:81` | `admin@example.com` | `changeme` |
| Portainer | `http://服务器IP:9000` | 首次访问自行设置 | — |

> **重要**：首次登录 Nginx Proxy Manager 后，请立即修改默认密码！

### 建议：为管理面板配置域名

可以在 NPM 中为管理面板本身配置域名和 SSL，例如：
- `npm.yourdomain.com` → `nginx-proxy-manager:81`
- `portainer.yourdomain.com` → `portainer:9000`

配置后可通过 HTTPS 域名访问，更安全。

---

## 目录结构说明

```
/opt/manus/                     # manus 系统目录
├── lib/                        # 函数库
│   ├── common.sh               # 通用工具函数
│   ├── docker.sh               # Docker 管理函数
│   ├── firewall.sh             # 防火墙配置函数
│   └── backup.sh               # 备份恢复函数
├── scripts/                    # 自动化脚本
│   └── backup-all.sh           # 自动备份脚本（cron 调用）
├── nginx-proxy-manager/        # NPM 数据目录
├── portainer/                  # Portainer 数据目录
├── mysql/                      # MySQL 数据目录
├── backups/                    # 备份文件存储
├── manage.sh                   # 管理主脚本
├── sites.conf                  # 站点注册表
└── .mysql_root_pass            # MySQL root 密码（权限 600）

/opt/sites/                     # 所有网站目录
├── example.com/                # 站点目录（以域名命名）
│   ├── html/                   # 网站文件（上传到此目录）
│   ├── uploads/                # 用户上传文件（图片/视频）
│   ├── logs/                   # 日志文件
│   ├── docker-compose.yml      # 容器配置
│   ├── nginx.conf              # Nginx 配置（静态/PHP）
│   ├── .env                    # 环境变量（含数据库密码）
│   └── .db_info                # 数据库连接信息
└── another-site.com/           # 另一个站点...
```

---

## 网站类型说明

### 静态网站（推荐用于产品展示）

适用于纯 HTML/CSS/JS 网站，包括产品展示页、图片画廊等。

**特性：**
- 基于 Nginx Alpine 镜像，体积极小，性能极高
- 自动配置图片缓存（30天）、视频断点续传
- 支持单页应用（SPA）路由
- 最大文件上传 500MB

**部署后操作：** 将网站文件上传到 `/opt/sites/域名/html/` 目录即可。

### Node.js 应用

适用于 Next.js、Express、Nuxt.js 等框架开发的网站。

**特性：**
- 使用多阶段 Docker 构建，镜像体积小
- 非 root 用户运行，安全性高
- 自动健康检查
- 支持热更新（`manus update 域名`）

**部署要求：** 仓库根目录需有 `package.json`，启动命令为 `node server.js`（可在 Dockerfile 中修改）。

### PHP 应用

适用于 Laravel、WordPress 或原生 PHP 网站。

**特性：**
- PHP 8.2 + Nginx 双容器架构
- 已优化 PHP 配置（500MB 上传限制、OPcache 加速）
- 支持 Laravel 路由

---

## 与 Manus 开发的网站配合使用

当 Manus 为你开发网站代码并上传到 GitHub 后，你可以用以下方式一键部署：

### 方式一：使用 `manus git` 命令

```bash
manus git
# 输入 GitHub 仓库地址
# 输入域名
# 选择网站类型
```

### 方式二：仓库中包含 docker-compose.yml

Manus 开发的网站代码仓库中若已包含 `docker-compose.yml`，则：

```bash
# 克隆仓库到站点目录
git clone https://github.com/Alexlyu365/your-site.git /opt/sites/example.com

# 进入目录启动
cd /opt/sites/example.com
docker compose up -d --build

# 注册到 manus 管理系统
# （之后可用 manus list/stop/start 等命令管理）
```

### 推荐工作流

1. **Manus 开发网站** → 代码上传到你的 GitHub 仓库
2. **你在服务器执行** `manus git` → 输入仓库地址和域名
3. **在 NPM 中配置** 域名代理和 SSL 证书
4. **网站上线** — 全程约 5 分钟

---

## 常见问题

**Q: SSL 证书申请失败怎么办？**

确认域名已正确解析到服务器 IP，且服务器 80/443 端口已开放。Let's Encrypt 需要通过 HTTP 验证域名所有权。

**Q: 如何上传大视频文件？**

网站文件目录 `/opt/sites/域名/html/` 可以直接通过 SFTP/SCP 上传文件，无大小限制。若通过网站后台上传，已配置最大 500MB。

**Q: 如何查看 MySQL 数据库密码？**

```bash
# root 密码
cat /opt/manus/.mysql_root_pass

# 某个站点的数据库密码
cat /opt/sites/example.com/.env
```

**Q: 如何连接 MySQL 数据库？**

```bash
# 在服务器上连接
docker exec -it manus-mysql mysql -u root -p

# 使用 Navicat 等工具连接（需要 SSH 隧道，MySQL 不对外暴露）
# SSH 主机: 服务器IP
# MySQL 主机: 127.0.0.1:3306
```

**Q: 备份文件在哪里？**

```bash
ls -lh /opt/manus/backups/
```

**Q: 如何迁移到新服务器？**

1. 在旧服务器执行 `manus backup`（备份所有站点）
2. 将 `/opt/manus/backups/` 目录复制到新服务器
3. 在新服务器初始化后，执行恢复命令（进入 `manus` 菜单 → 备份管理 → 恢复）

---

## 开放端口说明

| 端口 | 协议 | 用途 | 说明 |
|------|------|------|------|
| 22 | TCP | SSH | 服务器远程管理 |
| 80 | TCP | HTTP | 网站访问（自动跳转 HTTPS）|
| 443 | TCP | HTTPS | 网站 SSL 访问 |
| 81 | TCP | NPM 管理界面 | Nginx Proxy Manager |
| 9000 | TCP | Portainer | Docker 可视化管理 |
| 3306 | TCP | MySQL | 仅绑定 127.0.0.1，不对外 |

---

*由 [Manus AI](https://manus.im) 生成 · 项目地址: [github.com/Alexlyu365/manus](https://github.com/Alexlyu365/manus)*
