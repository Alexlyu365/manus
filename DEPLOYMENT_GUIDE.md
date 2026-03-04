# Manus Deploy — 服务器部署操作手册

> **适用系统**：Google Cloud Debian 12 (Bookworm) / Ubuntu 20.04 / 22.04 / 24.04
> **最后更新**：2026-03

---

## 目录

1. [整体流程概览](#1-整体流程概览)
2. [第一部分：Google Cloud 服务器创建](#2-第一部分google-cloud-服务器创建)
3. [第二部分：安装前必做准备](#3-第二部分安装前必做准备)
4. [第三部分：执行一键初始化](#4-第三部分执行一键初始化)
5. [第四部分：初始化完成后的必要配置](#5-第四部分初始化完成后的必要配置)
6. [第五部分：部署第一个网站](#6-第五部分部署第一个网站)
7. [第六部分：日常管理操作](#7-第六部分日常管理操作)
8. [注意事项与常见错误](#8-注意事项与常见错误)
9. [重要密码和地址汇总](#9-重要密码和地址汇总)

---

## 1. 整体流程概览

整套系统分为 **两个阶段**，第一阶段只需做一次，第二阶段每次新建网站时重复执行。

```
第一阶段（一次性，约 15 分钟）
─────────────────────────────────────────────────────────
Google Cloud 创建服务器
    → 配置 VPC 防火墙规则（开放端口）
    → 配置 SSH 密钥
    → 执行一键初始化脚本
    → 登录管理面板修改默认密码
    → 限制管理端口访问 IP

第二阶段（每次建站，约 5 分钟）
─────────────────────────────────────────────────────────
执行 manus add（或 manus git）
    → 在 Nginx Proxy Manager 添加代理规则
    → 申请 SSL 证书
    → 网站上线
```

---

## 2. 第一部分：Google Cloud 服务器创建

### 2.1 推荐配置

| 配置项 | 推荐值 | 说明 |
|--------|--------|------|
| 机器类型 | `e2-medium`（2 vCPU / 4 GB）起 | 单站点可用 `e2-small`，多站点建议 `e2-medium` 以上 |
| 操作系统 | **Debian GNU/Linux 12 (Bookworm)** | 脚本完整适配，推荐首选 |
| 磁盘 | SSD 持久化磁盘，50 GB 起 | 图片/视频网站建议 100 GB 以上 |
| 区域 | 根据目标用户选择 | 面向中国大陆用户建议选香港或台湾 |
| 网络 | 允许 HTTP 和 HTTPS 流量 | 创建时勾选，后续还需手动配置防火墙规则 |

### 2.2 创建实例步骤

在 Google Cloud 控制台中，进入 **Compute Engine → VM 实例 → 创建实例**，按以下顺序配置：

第一步，选择区域和机器类型，建议选择靠近目标用户的区域。

第二步，在"启动磁盘"中点击"更改"，选择 **Debian GNU/Linux 12 (Bookworm)**，磁盘大小根据需求调整。

第三步，在"防火墙"部分，勾选"允许 HTTP 流量"和"允许 HTTPS 流量"。

第四步，展开"高级选项 → 安全 → 管理 SSH 密钥"，添加你的 SSH 公钥（获取方式见下一节）。

第五步，点击"创建"，等待实例启动（约 1 分钟）。

---

## 3. 第二部分：安装前必做准备

> **重要**：以下两项准备工作必须在运行初始化脚本之前完成，否则初始化后可能无法登录服务器。

### 3.1 配置 SSH 密钥（最重要）

初始化脚本会**强制禁用 SSH 密码登录**，只允许密钥认证。这是防止暴力破解的核心安全措施。如果在配置密钥之前运行脚本，将无法再登录服务器。

**在本地电脑上执行**（如果已有密钥可跳过生成步骤）：

```bash
# 生成 SSH 密钥（推荐使用 ed25519 算法，更安全）
ssh-keygen -t ed25519 -C "your@email.com"
# 按提示操作，密钥默认保存在 ~/.ssh/id_ed25519

# 查看公钥内容（需要复制到 Google Cloud）
cat ~/.ssh/id_ed25519.pub
```

将上面命令输出的公钥内容（以 `ssh-ed25519` 开头的一整行），复制到 Google Cloud 控制台的 **Compute Engine → 元数据 → SSH 密钥** 中添加。

**验证密钥登录是否成功**（在运行初始化脚本之前必须验证）：

```bash
# 将 YOUR_IP 替换为服务器的外部 IP 地址
# 将 YOUR_USER 替换为你的 Google Cloud 用户名（通常是邮箱前缀）
ssh -i ~/.ssh/id_ed25519 YOUR_USER@YOUR_IP

# 成功登录后，提示符会变为类似: your_user@instance-name:~$
```

### 3.2 配置 Google Cloud VPC 防火墙规则

Google Cloud 有独立的 VPC 防火墙，与服务器内部的 UFW 是两层独立的防护。**必须在 VPC 防火墙中开放端口，外部才能访问服务器上的服务。**

进入 **VPC 网络 → 防火墙 → 创建防火墙规则**，创建一条入站规则：

| 字段 | 填写内容 |
|------|---------|
| 名称 | `manus-deploy-ports` |
| 网络 | `default` |
| 流量方向 | 入站 |
| 来源 IP 范围 | `0.0.0.0/0`（所有 IP，后续可收紧） |
| 协议和端口 | TCP: `80, 443, 81, 9000, 9443` |

> **安全建议**：端口 81、9000、9443 是管理界面端口，建议将来源 IP 限制为你自己的固定 IP，而非 `0.0.0.0/0`。初始化完成后可以修改此规则，或通过 `manus restrict-admin <你的IP>` 在服务器内部进一步限制。

---

## 4. 第三部分：执行一键初始化

### 4.1 连接服务器

```bash
ssh -i ~/.ssh/id_ed25519 YOUR_USER@YOUR_SERVER_IP
```

### 4.2 运行初始化脚本

> **注意**：Google Cloud Debian 12 的默认用户不是 root，必须使用 `sudo`。

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/Alexlyu365/manus/main/server-init.sh)
```

脚本启动后会显示操作清单，并询问是否继续。**在确认 SSH 密钥已配置且可以正常登录后**，输入 `y` 继续。

### 4.3 初始化过程说明

脚本会依次完成以下 12 个步骤，整个过程约 5-10 分钟，期间无需任何操作：

| 步骤 | 内容 | 耗时 |
|------|------|------|
| 1 | 更新系统软件包 | 1-3 分钟 |
| 2 | 安装基础工具 | 约 30 秒 |
| 3 | 安装 Docker Engine | 1-2 分钟 |
| 4 | 优化系统内核参数 | 即时 |
| 5 | 配置 UFW 防火墙（修复 Docker 绕过问题） | 即时 |
| 6 | 加固 SSH 安全（禁用密码登录） | 即时 |
| 7 | 安装 Fail2ban 防暴力破解 | 约 30 秒 |
| 8 | 配置自动安全更新 | 即时 |
| 9 | 创建目录结构 | 即时 |
| 10 | 部署 NPM + Portainer + MySQL | 2-3 分钟 |
| 11 | 配置每日自动备份 | 即时 |
| 12 | 安装 manus 管理命令 | 即时 |

### 4.4 初始化完成后的输出

脚本完成后会显示所有管理面板的访问地址和密码，**请立即截图或记录保存**，格式如下：

```
Nginx Proxy Manager 地址: http://YOUR_IP:81
  账号: admin@example.com
  密码: changeme  ← 请立即修改！

Portainer 地址: http://YOUR_IP:9000
  首次访问请在 5 分钟内设置管理员密码

MySQL 地址: 127.0.0.1:3306（仅本机访问）
  root 密码: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

---

## 5. 第四部分：初始化完成后的必要配置

> **以下步骤必须完成**，否则服务器存在安全隐患。

### 5.1 修改 Nginx Proxy Manager 默认密码

在浏览器中打开 `http://YOUR_SERVER_IP:81`，使用默认账号登录：

- 账号：`admin@example.com`
- 密码：`changeme`

登录后系统会立即要求修改密码，按提示设置一个强密码（建议 16 位以上，包含大小写字母、数字和符号）。同时修改账号邮箱为你自己的邮箱，用于接收 SSL 证书到期提醒。

**NPM 界面说明**：

| 菜单项 | 用途 |
|--------|------|
| Proxy Hosts | 代理主机，每个网站在这里添加一条记录 |
| SSL Certificates | SSL 证书管理，可手动申请或查看到期时间 |
| Access Lists | 访问控制列表，可设置 IP 白名单或密码保护 |
| Streams | TCP/UDP 流量转发（一般不需要） |

### 5.2 配置 Portainer

在浏览器中打开 `http://YOUR_SERVER_IP:9000`，**首次访问必须在 5 分钟内完成**，否则 Portainer 会锁定并需要重启容器。

按提示设置管理员用户名和密码，然后选择"Get Started"使用本地 Docker 环境。

**Portainer 界面说明**：

| 菜单项 | 用途 |
|--------|------|
| Containers | 查看所有容器状态、启停、查看日志 |
| Images | 管理 Docker 镜像 |
| Volumes | 管理数据卷 |
| Networks | 查看 Docker 网络 |
| Stacks | 管理 Docker Compose 项目 |

### 5.3 限制管理端口访问 IP（强烈推荐）

管理界面（NPM 端口 81、Portainer 端口 9000/9443）默认对所有 IP 开放，建议限制为只有你自己的 IP 才能访问。

**在服务器上执行**：

```bash
# 查看你当前的公网 IP（在本地电脑浏览器中打开）
# https://api.ipify.org

# 在服务器上执行限制命令
manus restrict-admin 你的公网IP
# 例如: manus restrict-admin 203.0.113.100
```

执行后，端口 81、9000、9443 只有来自指定 IP 的访问才会被允许。

> **注意**：如果你的 IP 会变化（如家庭宽带），每次 IP 变化后需要重新执行此命令，或者在 Google Cloud VPC 防火墙中配置。

### 5.4 保存 MySQL root 密码

MySQL root 密码已自动生成并保存在服务器上，执行以下命令查看：

```bash
cat /opt/manus/.mysql_root_pass
```

**请将此密码保存到你的密码管理器中**，以备不时之需（如手动操作数据库）。

### 5.5 验证所有服务正常运行

```bash
# 查看所有容器状态（应全部显示 Up）
docker ps

# 查看防火墙状态
sudo ufw status

# 查看 Fail2ban 状态
sudo fail2ban-client status
```

正常状态下应看到以下容器在运行：

| 容器名 | 状态 |
|--------|------|
| `nginx-proxy-manager` | Up |
| `portainer` | Up |
| `docker-socket-proxy` | Up |
| `manus-mysql` | Up |

---

## 6. 第五部分：部署第一个网站

### 6.1 方式一：交互式部署（推荐）

```bash
manus add
```

脚本会依次询问：

1. **网站域名**（如 `example.com`）— 请确保域名已解析到服务器 IP
2. **网站类型** — 选择 `1`（静态网站，适合产品展示/图片/视频）
3. **是否需要数据库** — 产品展示类网站通常选 `n`（不需要）

完成后脚本会输出容器名称，记录下来用于下一步。

### 6.2 方式二：从 GitHub 仓库部署

```bash
manus git
```

输入网站代码的 GitHub 仓库地址，脚本会自动克隆并部署。

### 6.3 在 NPM 中添加代理规则（每次建站必做）

这是唯一需要手动操作的步骤，约 1 分钟。

打开 NPM 管理界面（`http://YOUR_IP:81`），点击 **Proxy Hosts → Add Proxy Host**：

| 字段 | 填写内容 |
|------|---------|
| Domain Names | 你的域名，如 `example.com` |
| Scheme | `http` |
| Forward Hostname / IP | 容器名，如 `site_example_com` |
| Forward Port | 静态网站填 `80`，Node.js 填 `3000`，PHP 填 `80` |
| Cache Assets | 建议开启（图片/视频缓存） |
| Block Common Exploits | 建议开启 |
| Websockets Support | Node.js 应用需要开启 |

切换到 **SSL** 标签页：

| 字段 | 填写内容 |
|------|---------|
| SSL Certificate | 选择 `Request a new SSL Certificate` |
| Force SSL | 开启（强制 HTTPS） |
| HTTP/2 Support | 开启 |
| Email Address | 填写你的邮箱（用于证书到期提醒） |

点击 **Save**，NPM 会自动向 Let's Encrypt 申请免费 SSL 证书，约 30 秒完成。

> **前提条件**：申请 SSL 证书之前，域名必须已经解析到服务器 IP，且 80 端口可以从外网访问。DNS 解析生效通常需要 5-30 分钟。

### 6.4 上传网站文件

网站文件目录位于服务器的 `/opt/sites/域名/html/`，可以通过 SCP 或 SFTP 上传：

```bash
# 从本地上传文件到服务器（在本地电脑执行）
scp -r ./dist/* YOUR_USER@YOUR_IP:/opt/sites/example.com/html/

# 或使用 rsync（支持增量同步，适合大量文件）
rsync -avz --delete ./dist/ YOUR_USER@YOUR_IP:/opt/sites/example.com/html/
```

---

## 7. 第六部分：日常管理操作

所有管理操作通过 `manus` 命令完成，在服务器上执行：

```bash
manus help          # 查看所有可用命令
manus list          # 查看所有已部署站点
manus add           # 部署新站点（交互式）
manus git           # 从 GitHub 仓库部署站点
manus stop 域名     # 停止站点
manus start 域名    # 启动站点
manus restart 域名  # 重启站点
manus logs 域名     # 查看站点日志
manus backup        # 手动备份所有站点
manus restore       # 从备份恢复站点
manus delete 域名   # 删除站点（会提示确认）
manus restrict-admin IP  # 限制管理端口访问 IP
```

### 7.1 更新网站内容

对于静态网站，直接替换 `/opt/sites/域名/html/` 目录下的文件即可，无需重启容器。

对于 Node.js 或 PHP 网站，更新代码后需要重建容器：

```bash
cd /opt/sites/example.com
git pull                    # 拉取最新代码
docker compose up -d --build  # 重新构建并启动
```

### 7.2 查看备份

自动备份每天凌晨 3:00 执行，备份文件保存在 `/opt/manus/backups/`：

```bash
ls -lh /opt/manus/backups/   # 查看所有备份文件
manus backup                  # 立即执行手动备份
```

### 7.3 查看系统资源

```bash
docker stats --no-stream    # 查看各容器资源占用
df -h                        # 查看磁盘使用情况
free -h                      # 查看内存使用情况
```

---

## 8. 注意事项与常见错误

### 8.1 安装前注意事项

**注意事项一：SSH 密钥必须提前配置**。脚本会强制禁用密码登录，如果在没有配置密钥的情况下运行，初始化完成后将永久无法通过密码登录。唯一的补救方式是通过 Google Cloud 控制台的串行控制台（Serial Console）登录，操作较为繁琐。

**注意事项二：Google Cloud VPC 防火墙必须提前开放端口**。服务器内部的 UFW 和 Google Cloud VPC 防火墙是两层独立的防护，两者都需要开放端口，外部才能访问。

**注意事项三：域名 DNS 需要提前解析**。申请 SSL 证书时，Let's Encrypt 会验证域名是否指向服务器 IP。如果 DNS 未生效，证书申请会失败。建议在部署网站前 30 分钟先将域名解析到服务器 IP。

**注意事项四：不要在脚本运行过程中断开 SSH 连接**。初始化过程约 5-10 分钟，期间断开连接可能导致部分步骤未完成。建议使用 `tmux` 或 `screen` 在后台运行：

```bash
# 使用 tmux 运行（断开连接后脚本继续运行）
sudo tmux new-session -s deploy
sudo bash <(curl -fsSL https://raw.githubusercontent.com/Alexlyu365/manus/main/server-init.sh)
# 如果断开连接，重新连接后执行: sudo tmux attach -t deploy
```

### 8.2 安装过程中的常见错误

**错误：`curl: (6) Could not resolve host`**

原因：服务器无法访问 GitHub（部分地区网络问题）。

解决：等待几分钟后重试，或检查服务器的 DNS 设置：

```bash
cat /etc/resolv.conf
# 如果 DNS 有问题，临时修改为 Google DNS:
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
```

**错误：`E: Unable to locate package docker-ce`**

原因：Docker 软件源未正确添加，通常是网络问题导致 GPG 密钥下载失败。

解决：手动重新添加 Docker 软件源后重试：

```bash
sudo rm /etc/apt/sources.list.d/docker.list 2>/dev/null
sudo rm /etc/apt/keyrings/docker.gpg 2>/dev/null
sudo apt-get update
# 然后重新运行初始化脚本
```

**错误：Portainer 首次访问提示"Your Portainer instance timed out"**

原因：Portainer 首次启动后 5 分钟内未完成管理员账号设置，自动锁定。

解决：重启 Portainer 容器：

```bash
docker restart portainer
# 然后立即在浏览器中打开 http://YOUR_IP:9000 完成设置
```

**错误：SSL 证书申请失败，提示"DNS problem"**

原因：域名 DNS 尚未解析到服务器 IP，或解析未生效。

解决：在本地电脑验证 DNS 是否生效：

```bash
# 在本地电脑执行，将 example.com 替换为你的域名
nslookup example.com
# 或
dig +short example.com
# 返回的 IP 应与服务器 IP 一致
```

### 8.3 安全注意事项

**定期检查 Fail2ban 封禁状态**，避免误封自己的 IP：

```bash
sudo fail2ban-client status sshd
# 如果自己的 IP 被封，执行解封:
sudo fail2ban-client set sshd unbanip 你的IP
```

**定期检查 SSL 证书有效期**。NPM 会自动续期，但如果服务器 80 端口被临时关闭，续期可能失败。在 NPM 界面的 SSL Certificates 菜单中可以查看所有证书的到期时间。

**定期检查磁盘空间**，图片和视频网站磁盘占用增长较快：

```bash
df -h
du -sh /opt/sites/*   # 查看各站点占用空间
```

---

## 9. 重要密码和地址汇总

> **请将以下信息保存到安全的地方（如密码管理器）**

初始化完成后，请填写并保存以下信息：

| 项目 | 地址 / 值 |
|------|---------|
| 服务器 IP | `___________________` |
| SSH 登录命令 | `ssh -i ~/.ssh/id_ed25519 USER@IP` |
| NPM 管理界面 | `http://YOUR_IP:81` |
| NPM 账号 | `___________________` |
| NPM 密码 | `___________________` |
| Portainer 管理界面 | `http://YOUR_IP:9000` |
| Portainer 账号 | `___________________` |
| Portainer 密码 | `___________________` |
| MySQL root 密码 | `cat /opt/manus/.mysql_root_pass` |
| 备份文件位置 | `/opt/manus/backups/` |
| 站点文件位置 | `/opt/sites/域名/html/` |
| 管理命令 | `manus help` |

---

*文档版本：v1.2 | 最后更新：2026-03 | 仓库：github.com/Alexlyu365/manus*
