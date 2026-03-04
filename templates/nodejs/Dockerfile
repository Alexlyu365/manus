# ============================================================
# Node.js 生产环境 Dockerfile 模板
# 使用多阶段构建，减小最终镜像体积
# ============================================================

# ── 构建阶段 ──────────────────────────────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

# 复制依赖文件
COPY package*.json ./
# 如果使用 yarn
# COPY yarn.lock ./

# 安装依赖（仅生产依赖）
RUN npm ci --only=production 2>/dev/null || npm install --only=production

# 复制源代码
COPY . .

# 构建（如果是 Next.js / Nuxt 等需要构建的框架）
# RUN npm run build

# ── 运行阶段 ──────────────────────────────────────────────────────────────────
FROM node:20-alpine AS runner

# 安装必要工具
RUN apk add --no-cache curl tzdata

WORKDIR /app

# 设置时区
ENV TZ=Asia/Shanghai

# 创建非 root 用户运行应用
RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001

# 从构建阶段复制文件
COPY --from=builder --chown=nodejs:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=nodejs:nodejs /app .

# 创建上传目录
RUN mkdir -p /app/uploads /app/logs && \
    chown -R nodejs:nodejs /app/uploads /app/logs

USER nodejs

EXPOSE 3000

# 健康检查端点（请在应用中实现 /health 路由）
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

CMD ["node", "server.js"]
# 如果是 Next.js:
# CMD ["node", ".next/standalone/server.js"]
