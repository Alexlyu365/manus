# 网站名称

产品展示网站，由 Manus AI 生成并维护。

## 快速部署

```bash
# 在已初始化的服务器上执行一条命令即可完成部署
manus deploy https://github.com/Alexlyu365/此仓库名.git
```

部署完成后自动：
- 启动 Docker 容器
- 在 Nginx Proxy Manager 创建代理规则
- 申请 Let's Encrypt SSL 证书并启用 HTTPS

## 更新网站内容

```bash
# 方式一：手动更新
manus update your-domain.com

# 方式二：推送代码自动触发（需配置 GitHub Actions Secrets）
git push origin main
```

## 配置说明

`manus.config.json` 包含网站的所有部署配置，由 Manus AI 自动生成，通常无需手动修改。

| 配置项 | 说明 |
|--------|------|
| `site.domain` | 网站域名 |
| `site.email` | SSL 证书申请邮箱 |
| `build.type` | 构建类型（static / nodejs / php）|
| `build.source_dir` | 构建产物目录（静态网站）|
| `server.max_upload_size` | 最大上传文件大小 |

## GitHub Actions 自动部署配置

在仓库 Settings → Secrets and variables → Actions 中添加：

| Secret 名称 | 值 |
|-------------|-----|
| `SERVER_HOST` | 服务器 IP 地址 |
| `SERVER_USER` | SSH 用户名（通常为 root）|
| `SERVER_SSH_KEY` | SSH 私钥内容 |
| `SITE_DOMAIN` | 网站域名 |
