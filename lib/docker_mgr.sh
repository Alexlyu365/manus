#!/bin/bash
# =============================================================================
# docker_mgr.sh — Docker 全局管理函数库
# 对标 kejilion.sh linux_docker：容器管理、镜像管理、网络管理、清理、更换镜像源
# =============================================================================

# ── Docker 全局状态 ───────────────────────────────────────────────────────────
docker_global_status() {
    clear
    echo -e "${CYAN}── Docker 全局状态 ──────────────────────────────────${NC}"
    echo ""

    # Docker 版本
    local docker_ver
    docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "未安装")
    echo -e "  Docker 版本:  ${WHITE}${docker_ver}${NC}"
    echo ""

    # 容器统计
    local total running stopped
    total=$(docker ps -a -q 2>/dev/null | wc -l)
    running=$(docker ps -q 2>/dev/null | wc -l)
    stopped=$((total - running))
    echo -e "  容器总数:     ${WHITE}${total}${NC}  运行中: ${GREEN}${running}${NC}  已停止: ${RED}${stopped}${NC}"

    # 镜像统计
    local images_count images_size
    images_count=$(docker images -q 2>/dev/null | wc -l)
    images_size=$(docker system df 2>/dev/null | awk '/Images/{print $4}' || echo "未知")
    echo -e "  镜像数量:     ${WHITE}${images_count}${NC}  占用空间: ${WHITE}${images_size}${NC}"

    # 网络和卷
    local networks_count volumes_count
    networks_count=$(docker network ls -q 2>/dev/null | wc -l)
    volumes_count=$(docker volume ls -q 2>/dev/null | wc -l)
    echo -e "  网络数量:     ${WHITE}${networks_count}${NC}"
    echo -e "  数据卷数量:   ${WHITE}${volumes_count}${NC}"
    echo ""

    # 容器列表
    echo -e "${CYAN}── 容器列表 ─────────────────────────────────────────${NC}"
    docker ps -a --format "  {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}" 2>/dev/null | \
        column -t -s $'\t' || echo "  无容器"
    echo ""

    # 磁盘使用
    echo -e "${CYAN}── 磁盘使用 ─────────────────────────────────────────${NC}"
    docker system df 2>/dev/null | sed 's/^/  /'
    echo ""
}

# ── 容器管理菜单 ──────────────────────────────────────────────────────────────
docker_container_menu() {
    while true; do
        clear
        echo -e "${CYAN}Docker 容器管理${NC}"
        echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
        docker ps -a --format "  {{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null | column -t -s $'\t'
        echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
        echo "  1. 启动容器      2. 停止容器      3. 重启容器"
        echo "  4. 删除容器      5. 进入容器      6. 查看日志"
        echo "  7. 查看详情      8. 启动所有      9. 停止所有"
        echo "  10. 清理已停止容器"
        echo "────────────────────────────────────────────────────"
        echo "  0. 返回上一级"
        echo "────────────────────────────────────────────────────"
        read -rp "请输入选择: " choice
        case "$choice" in
            1)
                read -rp "容器名称: " cname
                docker start "$cname" && log_success "容器 ${cname} 已启动" || log_error "启动失败"
                ;;
            2)
                read -rp "容器名称: " cname
                docker stop "$cname" && log_success "容器 ${cname} 已停止" || log_error "停止失败"
                ;;
            3)
                read -rp "容器名称: " cname
                docker restart "$cname" && log_success "容器 ${cname} 已重启" || log_error "重启失败"
                ;;
            4)
                read -rp "容器名称 (将同时删除数据卷? y/N): " cname
                read -rp "是否同时删除关联数据卷? (y/N): " del_vol
                docker stop "$cname" 2>/dev/null
                if [[ "$del_vol" =~ ^[Yy]$ ]]; then
                    docker rm -v "$cname" && log_success "容器及数据卷已删除"
                else
                    docker rm "$cname" && log_success "容器已删除（数据卷保留）"
                fi
                ;;
            5)
                read -rp "容器名称: " cname
                docker exec -it "$cname" /bin/bash 2>/dev/null || \
                docker exec -it "$cname" /bin/sh
                ;;
            6)
                read -rp "容器名称: " cname
                read -rp "显示最后多少行 (默认100): " lines
                lines=${lines:-100}
                docker logs --tail "$lines" -f "$cname"
                ;;
            7)
                read -rp "容器名称: " cname
                docker inspect "$cname" | python3 -m json.tool 2>/dev/null | less
                ;;
            8)
                docker start $(docker ps -a -q) 2>/dev/null
                log_success "所有容器已启动"
                ;;
            9)
                if confirm "确认停止所有容器？"; then
                    docker stop $(docker ps -q) 2>/dev/null
                    log_success "所有运行中容器已停止"
                fi
                ;;
            10)
                local stopped_count
                stopped_count=$(docker ps -a -q -f status=exited | wc -l)
                if [ "$stopped_count" -eq 0 ]; then
                    log_info "没有已停止的容器"
                else
                    docker rm $(docker ps -a -q -f status=exited) 2>/dev/null
                    log_success "已清理 ${stopped_count} 个已停止容器"
                fi
                ;;
            0) break ;;
            *) log_warn "无效输入" ;;
        esac
        read -rp "按回车键继续..."
    done
}

# ── 镜像管理菜单 ──────────────────────────────────────────────────────────────
docker_image_menu() {
    while true; do
        clear
        echo -e "${CYAN}Docker 镜像管理${NC}"
        echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
        docker images --format "  {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" 2>/dev/null | \
            column -t -s $'\t'
        echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
        echo "  1. 拉取镜像      2. 更新镜像      3. 删除镜像"
        echo "  4. 删除所有未使用镜像              5. 搜索镜像"
        echo "  6. 导出镜像      7. 导入镜像"
        echo "────────────────────────────────────────────────────"
        echo "  0. 返回上一级"
        echo "────────────────────────────────────────────────────"
        read -rp "请输入选择: " choice
        case "$choice" in
            1)
                read -rp "镜像名称 (如 nginx:alpine): " img
                docker pull "$img" && log_success "镜像 ${img} 拉取成功"
                ;;
            2)
                read -rp "镜像名称 (留空更新所有): " img
                if [ -z "$img" ]; then
                    log_step "更新所有镜像..."
                    docker images --format "{{.Repository}}:{{.Tag}}" | grep -v '<none>' | \
                    while read -r image; do
                        echo "  更新: $image"
                        docker pull "$image" 2>/dev/null
                    done
                    log_success "所有镜像更新完成"
                else
                    docker pull "$img" && log_success "镜像 ${img} 更新完成"
                fi
                ;;
            3)
                read -rp "镜像名称或 ID: " img
                docker rmi "$img" && log_success "镜像已删除" || log_error "删除失败（可能有容器在使用）"
                ;;
            4)
                local dangling_count
                dangling_count=$(docker images -q -f dangling=true | wc -l)
                log_info "将删除 ${dangling_count} 个未使用镜像"
                if confirm "确认删除所有未使用镜像？"; then
                    docker image prune -a -f
                    log_success "清理完成"
                fi
                ;;
            5)
                read -rp "搜索关键词: " keyword
                docker search "$keyword" | head -20
                ;;
            6)
                read -rp "镜像名称: " img
                local safe_name
                safe_name=$(echo "$img" | tr '/:' '_')
                local output_file="/opt/manus/backups/image_${safe_name}_$(date +%Y%m%d).tar"
                mkdir -p /opt/manus/backups
                docker save -o "$output_file" "$img" && \
                    log_success "镜像已导出到: ${output_file}"
                ;;
            7)
                read -rp "tar 文件路径: " tar_file
                [ -f "$tar_file" ] || { log_error "文件不存在"; continue; }
                docker load -i "$tar_file" && log_success "镜像导入成功"
                ;;
            0) break ;;
            *) log_warn "无效输入" ;;
        esac
        read -rp "按回车键继续..."
    done
}

# ── Docker 清理 ───────────────────────────────────────────────────────────────
docker_cleanup() {
    clear
    echo -e "${CYAN}Docker 清理${NC}"
    echo ""
    echo -e "  将清理以下内容："
    echo -e "  - 所有已停止的容器"
    echo -e "  - 所有未被使用的网络"
    echo -e "  - 所有悬空镜像（<none>）"
    echo -e "  - 所有未使用的构建缓存"
    echo ""

    # 显示可释放空间
    docker system df 2>/dev/null | sed 's/^/  /'
    echo ""

    if confirm "确认执行清理？（不会删除运行中容器的数据）"; then
        log_step "执行 Docker 系统清理..."
        docker system prune -f 2>/dev/null
        log_success "清理完成"
        echo ""
        echo -e "  清理后磁盘状态:"
        docker system df 2>/dev/null | sed 's/^/  /'
    fi
}

# ── 更换 Docker 镜像源 ────────────────────────────────────────────────────────
docker_change_mirror() {
    clear
    echo -e "${CYAN}更换 Docker 镜像源${NC}"
    echo ""
    echo "  当前配置:"
    cat /etc/docker/daemon.json 2>/dev/null | sed 's/^/  /' || echo "  （无配置文件）"
    echo ""
    echo "  可选镜像源:"
    echo "  1. 阿里云镜像 (推荐国内)"
    echo "  2. 腾讯云镜像"
    echo "  3. 网易镜像"
    echo "  4. 清华大学镜像"
    echo "  5. 自定义镜像源"
    echo "  6. 恢复官方源（删除镜像加速配置）"
    echo "  0. 取消"
    echo ""
    read -rp "请输入选择: " choice

    local mirrors=()
    case "$choice" in
        1) mirrors=("https://registry.cn-hangzhou.aliyuncs.com") ;;
        2) mirrors=("https://mirror.ccs.tencentyun.com") ;;
        3) mirrors=("https://hub-mirror.c.163.com") ;;
        4) mirrors=("https://docker.mirrors.tuna.tsinghua.edu.cn") ;;
        5)
            read -rp "输入镜像源地址 (https://...): " custom_mirror
            mirrors=("$custom_mirror")
            ;;
        6)
            # 删除 registry-mirrors 配置
            if [ -f /etc/docker/daemon.json ]; then
                python3 -c "
import json
with open('/etc/docker/daemon.json') as f:
    cfg = json.load(f)
cfg.pop('registry-mirrors', None)
with open('/etc/docker/daemon.json', 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null
            fi
            systemctl restart docker 2>/dev/null
            log_success "已恢复官方源"
            return
            ;;
        0) return ;;
        *) log_warn "无效输入"; return ;;
    esac

    # 写入 daemon.json
    mkdir -p /etc/docker
    local daemon_file="/etc/docker/daemon.json"
    local mirrors_json
    mirrors_json=$(printf '"%s",' "${mirrors[@]}" | sed 's/,$//')

    if [ -f "$daemon_file" ]; then
        python3 -c "
import json
with open('${daemon_file}') as f:
    cfg = json.load(f)
cfg['registry-mirrors'] = [${mirrors_json}]
with open('${daemon_file}', 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null
    else
        cat > "$daemon_file" << EOF
{
  "registry-mirrors": [${mirrors_json}]
}
EOF
    fi

    systemctl daemon-reload 2>/dev/null
    systemctl restart docker 2>/dev/null
    log_success "Docker 镜像源已更新，Docker 已重启"
    echo ""
    echo "  新配置:"
    cat "$daemon_file" | sed 's/^/  /'
}

# ── Docker 备份与迁移 ─────────────────────────────────────────────────────────
docker_backup_menu() {
    while true; do
        clear
        echo -e "${CYAN}Docker 备份与迁移${NC}"
        echo ""
        echo "  1. 备份指定容器的数据卷"
        echo "  2. 备份所有 manus 托管站点"
        echo "  3. 恢复数据卷备份"
        echo "  4. 查看备份列表"
        echo "  0. 返回上一级"
        echo ""
        read -rp "请输入选择: " choice
        case "$choice" in
            1)
                read -rp "容器名称: " cname
                local backup_dir="/opt/manus/backups"
                mkdir -p "$backup_dir"
                local backup_file="${backup_dir}/${cname}_$(date +%Y%m%d_%H%M%S).tar.gz"
                # 获取容器挂载的卷
                local volumes
                volumes=$(docker inspect "$cname" --format '{{range .Mounts}}{{.Source}} {{end}}' 2>/dev/null)
                if [ -z "$volumes" ]; then
                    log_warn "容器 ${cname} 没有挂载数据卷"
                else
                    log_step "备份数据卷: ${volumes}"
                    tar -czf "$backup_file" $volumes 2>/dev/null && \
                        log_success "备份完成: ${backup_file}" || \
                        log_error "备份失败"
                fi
                ;;
            2)
                # 调用 backup.sh 中的函数
                if declare -f backup_all_sites &>/dev/null; then
                    backup_all_sites
                else
                    log_warn "请先加载 backup.sh"
                fi
                ;;
            3)
                read -rp "备份文件路径: " backup_file
                read -rp "恢复到目录 (默认 /): " restore_dir
                restore_dir=${restore_dir:-/}
                [ -f "$backup_file" ] || { log_error "文件不存在"; continue; }
                tar -xzf "$backup_file" -C "$restore_dir" && \
                    log_success "恢复完成" || log_error "恢复失败"
                ;;
            4)
                local backup_dir="/opt/manus/backups"
                if [ -d "$backup_dir" ]; then
                    echo ""
                    ls -lh "$backup_dir" 2>/dev/null | sed 's/^/  /'
                else
                    log_info "备份目录不存在"
                fi
                ;;
            0) break ;;
            *) log_warn "无效输入" ;;
        esac
        read -rp "按回车键继续..."
    done
}

# ── Docker 主菜单 ─────────────────────────────────────────────────────────────
docker_main_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║                  Docker 管理中心                     ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
        echo ""
        docker_global_status
        echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
        echo "  1. 容器管理          2. 镜像管理"
        echo "  3. 清理无用资源      4. 更换镜像源"
        echo "  5. 备份与迁移        6. 重启 Docker 服务"
        echo "────────────────────────────────────────────────────"
        echo "  0. 返回主菜单"
        echo "────────────────────────────────────────────────────"
        read -rp "请输入选择: " choice
        case "$choice" in
            1) docker_container_menu ;;
            2) docker_image_menu ;;
            3) docker_cleanup ;;
            4) docker_change_mirror ;;
            5) docker_backup_menu ;;
            6)
                systemctl restart docker && log_success "Docker 已重启" || log_error "重启失败"
                read -rp "按回车键继续..."
                ;;
            0) break ;;
            *) log_warn "无效输入" ;;
        esac
    done
}
