# manus-deploy 安全审计报告

**审计对象**: manus-deploy 一键服务器部署系统  
**审计日期**: 2026-03-04  
**审计范围**: server-init.sh、manage.sh、lib/docker.sh、lib/firewall.sh、lib/backup.sh、所有 Docker Compose 模板  
**风险评级标准**: 严重(Critical) / 高危(High) / 中危(Medium) / 低危(Low) / 信息(Info)

---

## 执行摘要

本次审计对 manus-deploy 部署系统进行了全面的安全性评估，覆盖供应链安全、容器隔离、网络暴露、身份认证、密钥管理、系统加固六个维度。审计共发现 **3 项高危风险、5 项中危风险、4 项低危风险**，并提供了对应的加固方案。总体而言，该系统的基础安全设计是合理的（MySQL 仅绑定本机、UFW 默认拒绝入站、密码随机生成），但在容器逃逸防护、防暴力破解、供应链完整性校验等方面存在可改进空间。

---

## 一、风险总览

| 编号 | 风险名称 | 受影响组件 | 风险等级 | 状态 |
|------|---------|-----------|---------|------|
| SEC-01 | Portainer 挂载 Docker Socket 导致容器逃逸 | `lib/docker.sh` | **高危** | 待加固 |
| SEC-02 | Docker 绕过 UFW 防火墙规则 | `lib/firewall.sh` | **高危** | 待加固 |
| SEC-03 | `curl \| bash` 供应链攻击风险 | `server-init.sh` | **高危** | 待加固 |
| SEC-04 | NPM 管理界面（端口 81）无访问限制 | `lib/docker.sh` | 中危 | 待加固 |
| SEC-05 | MySQL `MYSQL_ROOT_HOST='%'` 配置过宽 | `lib/docker.sh` | 中危 | 待加固 |
| SEC-06 | 缺少 Fail2ban 防暴力破解 | `lib/firewall.sh` | 中危 | 待加固 |
| SEC-07 | SSH 密码登录未强制禁用 | `lib/firewall.sh` | 中危 | 待加固 |
| SEC-08 | 容器未设置资源限制 | 所有模板 | 中危 | 待加固 |
| SEC-09 | 备份文件无加密保护 | `lib/backup.sh` | 低危 | 待加固 |
| SEC-10 | NPM 使用 `latest` 镜像标签 | `lib/docker.sh` | 低危 | 待加固 |
| SEC-11 | 缺少自动安全更新机制 | `server-init.sh` | 低危 | 待加固 |
| SEC-12 | 缺少入侵检测和审计日志 | 全局 | 低危 | 待加固 |

---

## 二、高危风险详细分析

### SEC-01 · Portainer 挂载 Docker Socket — 容器逃逸风险

**风险等级**: 高危  
**受影响文件**: `lib/docker.sh` 第 168 行

**问题描述**

当前 Portainer 的 Docker Compose 配置将宿主机的 Docker Socket 直接挂载到容器内：

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock
```

根据 OWASP Docker 安全备忘录 [^1]，Docker Socket（`/var/run/docker.sock`）是 Docker API 的主要入口，其所有者为 root。**将该 Socket 挂载到容器内，等同于向容器授予宿主机的无限制 root 权限**。一旦 Portainer 容器被攻陷（例如通过 Portainer 已知 CVE 或弱密码），攻击者可通过 Docker API 在宿主机上执行任意命令，实现完整的容器逃逸。

**攻击路径**:
```
攻击者 → 暴力破解 Portainer 密码
       → 通过 Portainer API 创建特权容器
       → 挂载宿主机根目录
       → 获得宿主机 root Shell
```

**加固方案**:

1. **首选方案（推荐）**: 将 Portainer 替换为 [Portainer Agent 模式](https://docs.portainer.io/admin/environments/add/docker/agent)，避免直接挂载 Socket。
2. **次选方案**: 为 Docker Socket 创建专用代理（如 `docker-socket-proxy`），仅暴露 Portainer 所需的只读 API，屏蔽危险操作（如 `POST /containers/create`）。
3. **配合措施**: 通过 NPM 为 Portainer 配置域名 + SSL + IP 白名单，不直接暴露 9000 端口。

---

### SEC-02 · Docker 绕过 UFW 防火墙规则

**风险等级**: 高危  
**受影响文件**: `lib/firewall.sh`、所有 Docker Compose 模板

**问题描述**

这是 Docker 与 UFW 共存时最常见、也最容易被忽视的安全问题 [^2]。Docker 在启动时会直接操作 `iptables`，在 `DOCKER` 链中插入规则，**完全绕过 UFW 的规则**。这意味着：即使 UFW 中没有开放某个端口，只要 Docker Compose 中配置了端口映射（如 `- "3000:3000"`），该端口就会对公网直接暴露。

**验证方式**:
```bash
# UFW 显示 3000 端口未开放
ufw status  # 3000 不在列表中

# 但实际上外网可以直接访问
curl http://服务器IP:3000  # 可以访问！
```

**影响范围**: 所有通过 Docker Compose 部署的站点容器，如果配置了 `ports` 映射，均会绕过 UFW 直接暴露。

**加固方案**:

修改 Docker 守护进程配置，禁止 Docker 操作 iptables（`"iptables": false`），改由 UFW 统一管理所有端口规则。同时，站点容器不应直接映射端口到宿主机，而应通过 NPM 内部网络进行反代，完全不需要 `ports` 配置。

---

### SEC-03 · `curl | bash` 供应链攻击风险

**风险等级**: 高危  
**受影响文件**: `server-init.sh`（安装命令本身）

**问题描述**

当前推荐的安装方式为：

```bash
bash <(curl -s https://raw.githubusercontent.com/Alexlyu365/manus/main/server-init.sh)
```

这种模式存在两类供应链攻击风险 [^3]：

**风险 A — GitHub 账号被盗**: 若攻击者获取了 GitHub 账号权限，可修改仓库中的脚本，下一个执行安装命令的用户将在服务器上执行恶意代码，且具有 root 权限。

**风险 B — 中间人攻击**: 虽然 HTTPS 可以防止传输层的中间人攻击，但若 GitHub CDN 或 DNS 被污染，仍存在风险。此外，`-s`（silent）参数会隐藏错误，使得网络异常时静默失败。

**加固方案**:

1. 为每个发布版本生成 SHA256 校验和文件（`checksums.sha256`），用户在执行前验证脚本完整性。
2. 将安装命令改为先下载、再校验、再执行的三步流程。
3. 启用 GitHub 仓库的分支保护规则，要求 PR 审查才能合并到 main 分支。
4. 开启 GitHub 账号的双因素认证（2FA）。

---

## 三、中危风险详细分析

### SEC-04 · NPM 管理界面无访问限制

**风险等级**: 中危  
**受影响文件**: `lib/docker.sh`、`lib/firewall.sh`

**问题描述**

Nginx Proxy Manager 管理界面（端口 81）和 Portainer（端口 9000）对所有公网 IP 开放。NPM 历史上存在多个严重漏洞，包括 CVE-2024-46257（命令注入 RCE）[^4] 和 CVE-2024-39935（OS 命令注入）[^5]，以及 2026 年初披露的 CVE-2026-1642。若管理界面暴露在公网且未及时更新，攻击者可直接利用漏洞获取服务器控制权。

**加固方案**:

1. 在 UFW 中将端口 81 和 9000 限制为仅允许你的固定 IP 访问。
2. 通过 NPM 为管理界面本身配置域名和 SSL，然后关闭 81 端口的直接访问。
3. 定期更新 NPM 镜像（`docker compose pull && docker compose up -d`）。

---

### SEC-05 · MySQL `MYSQL_ROOT_HOST='%'` 配置过宽

**风险等级**: 中危  
**受影响文件**: `lib/docker.sh` 第 247 行

**问题描述**

当前 MySQL 配置中设置了 `MYSQL_ROOT_HOST: '%'`，允许 root 用户从任意主机连接。虽然 MySQL 端口已通过 `127.0.0.1:3306:3306` 绑定到本机，但在 Docker 网络内部（`npm_network`），所有容器均可以通过 `manus-mysql:3306` 直接连接 MySQL，并使用 root 账号。若任一网站容器被攻陷，攻击者可访问所有站点的数据库。

**加固方案**:

1. 将 `MYSQL_ROOT_HOST` 改为 `localhost` 或 `127.0.0.1`，禁止 root 远程连接。
2. 每个站点的数据库用户仅授予对应数据库的权限（已实现），但应将 `'%'` 改为具体的容器网络地址段。
3. 将 MySQL 从 `npm_network` 中移除，创建独立的 `mysql_network`，仅允许需要数据库的容器加入。

---

### SEC-06 · 缺少 Fail2ban 防暴力破解

**风险等级**: 中危  
**受影响文件**: `lib/firewall.sh`

**问题描述**

当前方案仅使用 UFW 的 `limit` 规则对 SSH 进行简单的频率限制（每 30 秒最多 6 次连接），但缺少针对 SSH、NPM 管理界面、Portainer 的完整暴力破解防护。Fail2ban 可以监控日志文件，自动封禁多次认证失败的 IP，是防御暴力破解攻击的标准手段。

**加固方案**: 安装 Fail2ban，配置 SSH、Nginx（NPM）的 jail 规则，对失败登录超过 5 次的 IP 自动封禁 1 小时。

---

### SEC-07 · SSH 密码登录未强制禁用

**风险等级**: 中危  
**受影响文件**: `lib/firewall.sh` 第 68-70 行

**问题描述**

当前 `harden_ssh()` 函数中，禁用 SSH 密码登录的操作被注释为"仅提示"而非强制执行，且该函数在 `server-init.sh` 的主流程中**根本没有被调用**。这意味着服务器初始化后，SSH 密码登录仍然处于开启状态，暴露于全球的 SSH 扫描和暴力破解攻击中。

**加固方案**:

1. 在 `server-init.sh` 主流程中调用 `harden_ssh()`。
2. 强制禁用 SSH 密码登录（`PasswordAuthentication no`），要求使用密钥认证。
3. 在初始化脚本开头提示用户先配置 SSH 密钥，再执行初始化。

---

### SEC-08 · 容器未设置资源限制

**风险等级**: 中危  
**受影响文件**: 所有 Docker Compose 模板

**问题描述**

所有站点容器和基础服务容器均未配置内存和 CPU 限制。若某个站点遭受 DDoS 攻击或出现内存泄漏，可能耗尽服务器全部资源，导致其他所有站点同时宕机，违背了多站点隔离的设计目标。

**加固方案**: 在所有 Docker Compose 文件中添加 `deploy.resources.limits` 配置，根据服务器总内存合理分配每个容器的资源上限。

---

## 四、低危风险详细分析

### SEC-09 · 备份文件无加密保护

**风险等级**: 低危

备份文件（包含数据库 dump 和网站文件）以明文 `.tar.gz` 格式存储在 `/opt/manus/backups/`。若服务器被入侵或备份文件被意外泄露，所有站点数据将直接暴露。建议使用 GPG 对备份文件进行加密，或将备份上传到加密的对象存储（如 S3）。

### SEC-10 · 使用 `latest` 镜像标签

**风险等级**: 低危

NPM 和 Portainer 使用 `latest` 镜像标签，可能在 `docker compose pull` 时引入未经测试的新版本，导致服务异常。建议锁定到具体版本号（如 `jc21/nginx-proxy-manager:2.11.3`），在测试验证后再升级。

### SEC-11 · 缺少自动安全更新机制

**风险等级**: 低危

系统初始化后，宿主机操作系统的安全补丁需要手动更新。建议配置 `unattended-upgrades` 自动安装安全补丁，降低因已知漏洞被利用的风险。

### SEC-12 · 缺少入侵检测和审计日志

**风险等级**: 低危

当前方案缺少系统级别的入侵检测（如 AIDE 文件完整性监控）和集中化审计日志。建议启用 `auditd` 记录关键系统调用，并配置日志集中存储。

---

## 五、加固后的安全架构

实施以下加固措施后，整体安全架构将升级为：

```
互联网
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  Fail2ban (自动封禁暴力破解 IP)                               │
│  UFW (统一管理所有端口，Docker 不再绕过)                       │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Nginx Proxy Manager (仅 80/443 对外)                │   │
│  │  管理界面 81 端口仅允许白名单 IP 访问                  │   │
│  └──────┬──────────────┬──────────────┬─────────────────┘   │
│         │              │              │                      │
│         ▼              ▼              ▼                      │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐              │
│  │ 站点A容器  │ │ 站点B容器  │ │ 站点C容器  │              │
│  │ 无 ports   │ │ 无 ports   │ │ 无 ports   │              │
│  │ 资源限制   │ │ 资源限制   │ │ 资源限制   │              │
│  │ 非 root 用户│ │ 非 root 用户│ │ 非 root 用户│             │
│  └────────────┘ └────────────┘ └────────────┘              │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  MySQL (独立网络，root 仅本机，站点用户最小权限)       │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Docker Socket Proxy (仅暴露只读 API 给 Portainer)   │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  SSH: 密钥认证 + Fail2ban + UFW 限速                         │
│  自动安全更新: unattended-upgrades                           │
└─────────────────────────────────────────────────────────────┘
```

---

## 六、加固优先级建议

根据风险等级和实施难度，建议按以下顺序实施加固：

| 优先级 | 编号 | 加固措施 | 预计工时 |
|--------|------|---------|---------|
| P0（立即） | SEC-02 | 修复 Docker 绕过 UFW 问题 | 已集成到脚本 |
| P0（立即） | SEC-07 | 强制禁用 SSH 密码登录 | 已集成到脚本 |
| P1（本次） | SEC-01 | 引入 Docker Socket Proxy 保护 Portainer | 已集成到脚本 |
| P1（本次） | SEC-06 | 安装配置 Fail2ban | 已集成到脚本 |
| P1（本次） | SEC-04 | NPM/Portainer 端口 IP 白名单 | 已集成到脚本 |
| P1（本次） | SEC-05 | 修复 MySQL root host 配置 | 已集成到脚本 |
| P1（本次） | SEC-08 | 添加容器资源限制 | 已集成到模板 |
| P2（建议） | SEC-03 | 添加脚本完整性校验 | 已集成到脚本 |
| P2（建议） | SEC-11 | 配置自动安全更新 | 已集成到脚本 |
| P3（可选） | SEC-09 | 备份文件加密 | 手动配置 |
| P3（可选） | SEC-10 | 锁定镜像版本 | 手动更新 |
| P3（可选） | SEC-12 | 审计日志 | 手动配置 |

---

## 七、安全加固检查清单

部署完成后，请逐项确认以下安全配置：

**服务器基础安全**
- [ ] SSH 仅允许密钥登录，密码登录已禁用
- [ ] UFW 防火墙已启用，默认拒绝入站
- [ ] Fail2ban 已安装并运行（`systemctl status fail2ban`）
- [ ] 自动安全更新已启用（`systemctl status unattended-upgrades`）

**管理面板安全**
- [ ] NPM 默认密码已修改（`admin@example.com` / `changeme`）
- [ ] Portainer 管理员密码已在 5 分钟内设置
- [ ] 端口 81 和 9000 已限制为仅你的 IP 可访问（或通过 NPM 域名访问后关闭直接端口）

**数据库安全**
- [ ] MySQL root 密码已保存（`cat /opt/manus/.mysql_root_pass`）
- [ ] 各站点数据库用户仅有对应数据库的权限
- [ ] MySQL 端口未对外暴露（`ss -tlnp | grep 3306` 应显示 `127.0.0.1`）

**容器安全**
- [ ] 站点容器未使用 `--privileged` 标志
- [ ] 容器已设置内存和 CPU 限制
- [ ] Docker Socket 未直接挂载到业务容器

**备份安全**
- [ ] 自动备份已启用（`crontab -l | grep backup`）
- [ ] 备份文件权限为 600（`ls -la /opt/manus/backups/`）
- [ ] 定期测试备份恢复流程

---

## 参考资料

[^1]: [OWASP Docker Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html)
[^2]: [UFW + Docker Firewall Bypass Fix — ZeonEdge](https://zeonedge.com/it/blog/ufw-docker-firewall-bypass-fix)
[^3]: [Supply chain attacks are exploiting our assumptions — Trail of Bits](https://blog.trailofbits.com/2025/09/24/supply-chain-attacks-are-exploiting-our-assumptions/)
[^4]: [CVE-2024-46257: Nginx Proxy Manager RCE Vulnerability — SentinelOne](https://www.sentinelone.com/vulnerability-database/cve-2024-46257/)
[^5]: [CVE-2024-39935: Nginx Proxy Manager OS Command Injection — Wiz](https://www.wiz.io/vulnerability-database/cve/cve-2024-39935)

---

*审计由 Manus AI 执行 · 项目地址: [github.com/Alexlyu365/manus](https://github.com/Alexlyu365/manus)*
