#!/bin/sh
set -eu

# ── 核心配置 ──
STACK_DIR="${STACK_DIR:-/mnt/docker-data/sub2api-deploy}"
SUB2API_IMAGE_PREFIX="weishaw/sub2api:"
SUB2API_REPO="Wei-Shaw/sub2api"
BACKUP_DIR="$STACK_DIR/backup"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
HEALTH_URL="http://localhost:8080/health"
PUBLIC_HEALTH_URL="https://sub2.ebato.win/health"
MAX_BACKUPS=10
HEALTH_TIMEOUT=90
HEALTH_INTERVAL=5

# ── 参数解析 ──
CHECK_ONLY=0
VERIFY_ONLY=0
BACKUP_ONLY=0
CLEANUP_ONLY=0
ROLLBACK=0

case "${1:-}" in
  --check-only) CHECK_ONLY=1 ;;
  --verify)     VERIFY_ONLY=1 ;;
  --backup-only) BACKUP_ONLY=1 ;;
  --cleanup-only) CLEANUP_ONLY=1 ;;
  --rollback)   ROLLBACK=1 ;;
  --help|-h)
    echo "sub2api Docker 服务自动更新脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --check-only    仅检查版本，不更新"
    echo "  --verify        仅验证服务状态"
    echo "  --backup-only   仅备份数据库和 compose 文件"
    echo "  --cleanup-only  仅清理旧镜像和悬空镜像"
    echo "  --rollback      回滚到最近一次备份"
    echo "  --help, -h      显示此帮助信息"
    exit 0
    ;;
  "") ;;
  *)
    echo "未知参数: $1" >&2
    echo "使用 --help 查看用法" >&2
    exit 1
    ;;
esac

# ── 依赖检查 ──
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "✗ 缺少必要命令: $1" >&2
    exit 1
  }
}

require_cmd docker
require_cmd curl
require_cmd sed
require_cmd grep
require_cmd awk
require_cmd date

# ── Compose project 验证 ──

# 从 docker compose config 提取 project name
compose_project() {
  (
    cd "$STACK_DIR"
    docker compose config 2>/dev/null \
      | sed -n 's/^name:[[:space:]]*//p' \
      | head -n 1
  )
}

# 验证容器属于当前 compose project（防止误操作非本 project 的容器）
# 注：仅检查 project 标签。容器名与 compose service 名可能不一致
# （如容器名 sub2api-postgres 对应 service 名 postgres），故不比较 service 标签。
verify_compose_container() {
  container="$1"
  project="$2"

  # 容器不存在则跳过
  if ! docker inspect "$container" >/dev/null 2>&1; then
    return 0
  fi

  container_project="$(docker inspect "$container" --format '{{index .Config.Labels "com.docker.compose.project"}}')"

  if [ "$container_project" != "$project" ]; then
    echo "✗ 容器 $container 存在但不属于 compose project $project" >&2
    echo "  修复方法: cd $STACK_DIR && docker stop $container && docker rm $container && docker compose up -d" >&2
    exit 1
  fi
}

# ── 版本工具函数 ──

# 去掉版本号前导 v
normalize_version() {
  printf '%s' "$1" | sed 's/^v//'
}

# 比较两个版本号，$1 > $2 返回 0，否则返回 1（纯 shell 实现，不依赖 sort -V）
version_gt() {
  a="$(normalize_version "$1")"
  b="$(normalize_version "$2")"

  OLD_IFS="$IFS"
  IFS='.'
  set -- $a
  a_major="${1:-0}"; a_minor="${2:-0}"; a_patch="${3:-0}"
  set -- $b
  b_major="${1:-0}"; b_minor="${2:-0}"; b_patch="${3:-0}"
  IFS="$OLD_IFS"

  # 去除非数字后缀（如 "1rc1" -> "1"）
  a_major=$(printf '%s' "$a_major" | sed 's/[^0-9].*//'); a_major="${a_major:-0}"
  a_minor=$(printf '%s' "$a_minor" | sed 's/[^0-9].*//'); a_minor="${a_minor:-0}"
  a_patch=$(printf '%s' "$a_patch" | sed 's/[^0-9].*//'); a_patch="${a_patch:-0}"
  b_major=$(printf '%s' "$b_major" | sed 's/[^0-9].*//'); b_major="${b_major:-0}"
  b_minor=$(printf '%s' "$b_minor" | sed 's/[^0-9].*//'); b_minor="${b_minor:-0}"
  b_patch=$(printf '%s' "$b_patch" | sed 's/[^0-9].*//'); b_patch="${b_patch:-0}"

  if [ "$a_major" -gt "$b_major" ] 2>/dev/null; then return 0; fi
  if [ "$a_major" -lt "$b_major" ] 2>/dev/null; then return 1; fi
  if [ "$a_minor" -gt "$b_minor" ] 2>/dev/null; then return 0; fi
  if [ "$a_minor" -lt "$b_minor" ] 2>/dev/null; then return 1; fi
  if [ "$a_patch" -gt "$b_patch" ] 2>/dev/null; then return 0; fi
  return 1
}

# 比较两个版本号是否相等
version_eq() {
  [ "$(normalize_version "$1")" = "$(normalize_version "$2")" ]
}

# 查询 GitHub Release 最新 tag（支持 GITHUB_TOKEN 环境变量避免 rate limit）
latest_release_tag() {
  repo="$1"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL --max-time 15 -H "Authorization: token $GITHUB_TOKEN" \
      "https://api.github.com/repos/$repo/releases/latest" \
      | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n 1
  else
    curl -fsSL --max-time 15 "https://api.github.com/repos/$repo/releases/latest" \
      | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n 1
  fi
}

# ── 容器与镜像管理 ──

# 获取 sub2api 当前运行版本（从镜像 tag 提取）
running_sub2api_version() {
  if ! docker inspect sub2api >/dev/null 2>&1; then
    return 1
  fi
  image=$(docker inspect -f '{{.Config.Image}}' sub2api 2>/dev/null || true)
  if [ -z "$image" ]; then
    return 1
  fi
  # 提取 : 后的版本号
  echo "$image" | sed 's|.*:||'
}

# 获取容器当前使用的镜像 ID
container_image_id() {
  service="$1"
  docker inspect -f '{{.Image}}' "$service" 2>/dev/null || true
}

# 清理被替换的旧镜像（仅当未被其他容器使用时）
cleanup_old_image() {
  service="$1"
  old_image_id="$2"
  current_image_id="$(container_image_id "$service")"

  if [ -z "$old_image_id" ] || [ "$old_image_id" = "$current_image_id" ]; then
    return 0
  fi

  echo "正在清理 $service 旧镜像 ..."
  if docker image rm "$old_image_id" >/dev/null 2>&1; then
    echo "✓ 已删除 $service 旧镜像 $old_image_id"
  else
    echo "  ! 跳过 $service 旧镜像 $old_image_id（可能仍被其他容器使用）"
  fi
}

# 清理悬空镜像
cleanup_dangling_images() {
  if docker images -q -f dangling=true 2>/dev/null | grep -q .; then
    echo "正在清理未使用的悬空镜像 ..."
    docker image prune -f >/dev/null
    echo "✓ 悬空镜像清理完成"
  fi
}

# 仅清理模式：清理各服务旧镜像 + 悬空镜像
do_cleanup_only() {
  echo "── 仅清理模式 ──"
  echo ""

  # 清理各服务的旧镜像（同一仓库中非当前使用的镜像）
  for service in sub2api sub2api-postgres sub2api-redis; do
    current_image_id="$(container_image_id "$service")"
    current_image="$(docker inspect -f '{{.Config.Image}}' "$service" 2>/dev/null || true)"
    if [ -z "$current_image" ]; then
      continue
    fi
    # 提取仓库名（不含 tag）
    repo="${current_image%:*}"
    # 列出该仓库的所有镜像 ID（去重），清理非当前的
    docker images -q "$repo" 2>/dev/null | sort -u | while read -r img_id; do
      if [ -n "$img_id" ] && [ "$img_id" != "$current_image_id" ]; then
        cleanup_old_image "$service" "$img_id"
      fi
    done
  done

  echo ""
  cleanup_dangling_images
  echo ""
  echo "✓ 清理完成"
}

# ── 备份相关 ──

# 备份 PostgreSQL 数据库
backup_database() {
  TS=$(date +%Y%m%d%H%M%S)
  DUMP_FILE="/tmp/sub2api-$TS.dump"

  echo "正在备份 PostgreSQL 数据库 ..."
  if ! docker exec sub2api-postgres pg_dump -U sub2api -d sub2api -F c -f "$DUMP_FILE"; then
    echo "✗ pg_dump 失败" >&2
    return 1
  fi
  mkdir -p "$BACKUP_DIR"
  if ! docker cp "sub2api-postgres:$DUMP_FILE" "$BACKUP_DIR/sub2api-$TS.dump"; then
    echo "✗ docker cp 失败" >&2
    docker exec sub2api-postgres rm -f "$DUMP_FILE" 2>/dev/null || true
    return 1
  fi
  docker exec sub2api-postgres rm "$DUMP_FILE" 2>/dev/null || true
  chmod 600 "$BACKUP_DIR/sub2api-$TS.dump"
  echo "✓ 数据库备份完成: $BACKUP_DIR/sub2api-$TS.dump"
}

# 备份 docker-compose.yml
backup_compose() {
  TS=$(date +%Y%m%d%H%M%S)
  cp "$COMPOSE_FILE" "$STACK_DIR/docker-compose.yml.bak-$TS"
  echo "✓ compose 文件备份完成: $STACK_DIR/docker-compose.yml.bak-$TS"
}

# 清理旧备份，保留最近 MAX_BACKUPS 份
cleanup_old_backups() {
  echo "清理旧备份（保留最近 $MAX_BACKUPS 份）..."

  # 清理数据库备份
  (
    cd "$BACKUP_DIR" 2>/dev/null || exit 0
    ls -t sub2api-*.dump 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | while read -r old; do
      rm -f "$old"
      echo "  已删除旧数据库备份: $old"
    done
  )

  # 清理 compose 备份
  (
    cd "$STACK_DIR" 2>/dev/null || exit 0
    ls -t docker-compose.yml.bak-* 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | while read -r old; do
      rm -f "$old"
      echo "  已删除旧 compose 备份: $old"
    done
  )
}

# ── 镜像 tag 更新 ──

# 用 awk 精确替换 docker-compose.yml 中 image: weishaw/sub2api:xxx 行为新版本
ensure_sub2api_image_tag() {
  new_ver="$(normalize_version "$1")"
  new_image="${SUB2API_IMAGE_PREFIX}${new_ver}"

  tmp_file="$COMPOSE_FILE.tmp.$$"
  awk -v new_image="$new_image" '
    /^[[:space:]]*image:[[:space:]]*weishaw\/sub2api:/ {
      match($0, /^[[:space:]]*/);
      print substr($0, 1, RLENGTH) "image: " new_image
      changed = 1
      next
    }
    { print }
    END { if (!changed) exit 2 }
  ' "$COMPOSE_FILE" > "$tmp_file" || {
    rm -f "$tmp_file"
    echo "✗ 无法更新 docker-compose.yml 中的 sub2api 镜像 tag" >&2
    return 1
  }
  mv "$tmp_file" "$COMPOSE_FILE"
  echo "✓ 已更新 docker-compose.yml: image: $new_image"
}

# ── 健康检查 ──

# 循环轮询健康检查端点，最多 timeout 秒，每 interval 秒一次
wait_for_health() {
  url="$1"
  timeout="$2"
  interval="$3"

  elapsed=0
  echo "等待健康检查通过 ..."
  while [ "$elapsed" -lt "$timeout" ]; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo "000")
    if [ "$code" = "200" ]; then
      echo "✓ 健康检查通过 (${elapsed}s)"
      return 0
    fi
    printf "  ... 等待中 (%ds/%ds, HTTP %s)\n" "$elapsed" "$timeout" "$code"
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "✗ 健康检查超时（${timeout}s）" >&2
  return 1
}

# ── 验证 ──

do_verify() {
  echo "── 验证服务状态 ──"
  echo ""
  echo "Compose 状态:"
  docker compose -f "$COMPOSE_FILE" ps
  echo ""

  echo "健康检查:"
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$HEALTH_URL" 2>/dev/null || echo "000")
  if [ "$code" = "200" ]; then
    echo "  ✓ 本地 /health → $code"
  else
    echo "  ✗ 本地 /health → $code"
  fi

  code2=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$PUBLIC_HEALTH_URL" 2>/dev/null || echo "000")
  if [ "$code2" = "200" ]; then
    echo "  ✓ 公网 /health → $code2"
  else
    echo "  ✗ 公网 /health → $code2"
  fi
  echo ""

  echo "当前镜像:"
  docker inspect -f '{{.Config.Image}}' sub2api 2>/dev/null || echo "  (无法获取 sub2api 容器信息)"
}

# 显示回滚提示
show_rollback_hint() {
  echo ""
  echo "✗ 更新失败，可执行回滚:"
  echo "  cd $STACK_DIR"
  echo "  cp docker-compose.yml.bak-<timestamp> docker-compose.yml"
  echo "  docker compose up -d sub2api postgres redis"
  echo ""
  echo "或恢复最近备份:"
  _latest_bak=$(ls -t "$STACK_DIR"/docker-compose.yml.bak-* 2>/dev/null | head -n 1 || true)
  if [ -n "$_latest_bak" ]; then
    echo "  cp \"$_latest_bak\" \"$COMPOSE_FILE\""
    echo "  docker compose up -d sub2api postgres redis"
  fi
}

# ── 主流程 ──

# 1. 回滚模式
if [ "$ROLLBACK" -eq 1 ]; then
  echo "── 回滚模式 ──"
  echo ""
  _latest_bak=$(ls -t "$STACK_DIR"/docker-compose.yml.bak-* 2>/dev/null | head -n 1 || true)
  if [ -z "$_latest_bak" ]; then
    echo "✗ 未找到 docker-compose.yml 备份" >&2
    exit 1
  fi
  echo "正在恢复最近备份: $_latest_bak"
  cp "$_latest_bak" "$COMPOSE_FILE"
  echo "✓ 已恢复 compose 文件"
  (
    cd "$STACK_DIR"
    docker compose up -d sub2api postgres redis
  )
  wait_for_health "$HEALTH_URL" "$HEALTH_TIMEOUT" "$HEALTH_INTERVAL" || true
  echo ""
  do_verify
  exit 0
fi

# 2. 验证模式
if [ "$VERIFY_ONLY" -eq 1 ]; then
  do_verify
  exit 0
fi

# 3. 仅备份模式
if [ "$BACKUP_ONLY" -eq 1 ]; then
  echo "── 仅备份模式 ──"
  echo ""
  backup_database
  backup_compose
  cleanup_old_backups
  echo ""
  echo "✓ 备份完成"
  exit 0
fi

# 4. 仅清理模式（清理旧镜像 + 悬空镜像，不更新服务）
if [ "$CLEANUP_ONLY" -eq 1 ]; then
  do_cleanup_only
  exit 0
fi

# 5. 检查 STACK_DIR 和 COMPOSE_FILE 存在
if [ ! -d "$STACK_DIR" ]; then
  echo "✗ 部署目录不存在: $STACK_DIR" >&2
  exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "✗ docker-compose.yml 不存在: $COMPOSE_FILE" >&2
  exit 1
fi

# 6. 验证 compose project（防止误操作非本 project 的容器）
COMPOSE_PROJECT="$(compose_project)"
if [ -z "$COMPOSE_PROJECT" ]; then
  echo "✗ 无法从 $STACK_DIR 解析 compose project name" >&2
  exit 1
fi
verify_compose_container "sub2api" "$COMPOSE_PROJECT"
verify_compose_container "sub2api-postgres" "$COMPOSE_PROJECT"
verify_compose_container "sub2api-redis" "$COMPOSE_PROJECT"

# 7. 获取当前版本
SUB2API_LOCAL="$(running_sub2api_version 2>/dev/null || true)"
if [ -z "$SUB2API_LOCAL" ]; then
  echo "✗ 无法获取 sub2api 当前版本（容器是否存在？）" >&2
  exit 1
fi

# 8. 获取最新版本
SUB2API_LATEST="$(latest_release_tag "$SUB2API_REPO" 2>/dev/null || true)"
if [ -z "$SUB2API_LATEST" ]; then
  echo "✗ 无法获取 sub2api 最新版本（GitHub API 请求失败？）" >&2
  echo "  可设置 GITHUB_TOKEN 环境变量避免 rate limit" >&2
  exit 1
fi

# 9. 显示版本对比
echo "── sub2api 版本检查 ──"
echo ""
echo "  当前版本: $SUB2API_LOCAL"
echo "  最新版本: $SUB2API_LATEST"
echo ""

# 10. 如果已是最新（版本相等或本地更新）
if version_eq "$SUB2API_LOCAL" "$SUB2API_LATEST" || version_gt "$SUB2API_LOCAL" "$SUB2API_LATEST"; then
  echo "✓ 已是最新版本"
  echo ""
  echo "检查 PostgreSQL / Redis 镜像更新 ..."
  (
    cd "$STACK_DIR"
    docker compose pull postgres redis 2>/dev/null || true
    docker compose up -d postgres redis
  )
  echo ""
  do_verify
  exit 0
fi

# 11. 有新版本
echo "⬆ sub2api: $SUB2API_LOCAL → $SUB2API_LATEST"

# 12. 仅检查模式
if [ "$CHECK_ONLY" -eq 1 ]; then
  echo ""
  echo "（--check-only 模式，不执行更新）"
  exit 0
fi

# 13. 自动执行更新（不询问确认）
echo ""
echo "── 开始更新 sub2api ──"
echo ""

# a. 备份数据库（失败则中止）
if ! backup_database; then
  echo "✗ 数据库备份失败，中止更新" >&2
  exit 1
fi

# b. 备份 compose 文件
backup_compose

# c. 清理旧备份
cleanup_old_backups

# d. 记录旧镜像 ID
_old_sub2api_image_id="$(container_image_id "sub2api")"
_old_postgres_image_id="$(container_image_id "sub2api-postgres")"
_old_redis_image_id="$(container_image_id "sub2api-redis")"

# e. 更新 docker-compose.yml 中的镜像 tag
ensure_sub2api_image_tag "$SUB2API_LATEST"

# f. 拉取新镜像
echo "正在拉取新镜像 ..."
if ! ( cd "$STACK_DIR" && docker compose pull sub2api postgres redis ); then
  echo "✗ docker compose pull 失败" >&2
  show_rollback_hint
  exit 1
fi

# g. 启动新容器
echo "正在启动新容器 ..."
if ! ( cd "$STACK_DIR" && docker compose up -d sub2api postgres redis ); then
  echo "✗ docker compose up -d 失败" >&2
  show_rollback_hint
  exit 1
fi

# h. 等待健康检查（超时显示日志 + 回滚提示）
echo ""
if ! wait_for_health "$HEALTH_URL" "$HEALTH_TIMEOUT" "$HEALTH_INTERVAL"; then
  echo ""
  echo "最近日志:"
  docker logs --tail 30 sub2api 2>&1 || true
  show_rollback_hint
  exit 1
fi

# i. 清理旧镜像
echo ""
cleanup_old_image "sub2api" "$_old_sub2api_image_id"
cleanup_old_image "sub2api-postgres" "$_old_postgres_image_id"
cleanup_old_image "sub2api-redis" "$_old_redis_image_id"

# j. 清理悬空镜像
cleanup_dangling_images

# k. 更新完成
echo ""
echo "✓ 更新完成"

# 14. 验证
echo ""
do_verify
