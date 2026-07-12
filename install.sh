#!/bin/sh
set -eu

# sub2api 一键更新脚本安装器
# 在 Mac 上执行，部署 update-sub2api.sh 到路由器并安装 sub2 wrapper

# 默认配置
DEFAULT_HOST="192.168.31.81"
DEFAULT_USER="root"
DEFAULT_DIR="/mnt/docker-data/sub2api-deploy"

# GitHub raw URL（用于下载 update-sub2api.sh 到路由器）
SCRIPT_URL="https://raw.githubusercontent.com/Souitou-iop/sub2api-smart-update/main/update-sub2api.sh"
# 如果 GitHub 不可用，使用本地文件
LOCAL_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 用法显示 ──

show_usage() {
  cat << 'USAGE_EOF'
用法: sh install.sh [user@host] [部署目录]

参数:
  user@host   SSH 目标（默认 root@192.168.31.81）
  部署目录     路由器上的部署目录（默认 /mnt/docker-data/sub2api-deploy）

示例:
  sh install.sh                                    # 用默认值安装
  sh install.sh root@192.168.31.81                 # 指定 SSH 目标
  sh install.sh root@192.168.1.100 /opt/sub2api    # 指定目标和目录

要求:
  - Mac 上已配置 SSH 密钥认证到路由器
  - 执行 ssh-copy-id root@192.168.31.81 配置免密登录
USAGE_EOF
}

# ── 参数解析 ──

case "${1:-}" in
  --help|-h)
    show_usage
    exit 0
    ;;
  "")
    REMOTE_USER="$DEFAULT_USER"
    REMOTE_HOST="$DEFAULT_HOST"
    STACK_DIR="$DEFAULT_DIR"
    ;;
  *)
    REMOTE_ARG="$1"
    REMOTE_USER="${REMOTE_ARG%@*}"
    REMOTE_HOST="${REMOTE_ARG#*@}"
    STACK_DIR="${2:-$DEFAULT_DIR}"
    ;;
esac

# ── 主要函数 ──

# 测试 SSH 密钥认证
test_ssh() {
  ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "echo ok" >/dev/null 2>&1
}

# 远程执行命令
remote_exec() {
  ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "$@"
}

# 部署 update-sub2api.sh 到路由器
deploy_remote_script() {
  # 先尝试从 GitHub 下载
  if remote_exec "mkdir -p '$STACK_DIR' && curl -fsSLo '$STACK_DIR/update-sub2api.sh' '$SCRIPT_URL' && chmod +x '$STACK_DIR/update-sub2api.sh'"; then
    return 0
  fi
  # GitHub 失败，从本地 scp
  echo "  GitHub 下载失败，使用本地文件..."
  if [ ! -f "$LOCAL_SCRIPT_DIR/update-sub2api.sh" ]; then
    echo "  ✗ 本地文件不存在: $LOCAL_SCRIPT_DIR/update-sub2api.sh" >&2
    return 1
  fi
  scp -o ConnectTimeout=10 -o BatchMode=yes "$LOCAL_SCRIPT_DIR/update-sub2api.sh" "${REMOTE_USER}@${REMOTE_HOST}:$STACK_DIR/update-sub2api.sh"
  remote_exec "chmod +x '$STACK_DIR/update-sub2api.sh'"
}

# 在 Mac 上安装 sub2 wrapper
install_sub2_wrapper() {
  if [ ! -f "$LOCAL_SCRIPT_DIR/sub2" ]; then
    echo "  ✗ 本地文件不存在: $LOCAL_SCRIPT_DIR/sub2" >&2
    return 1
  fi
  # 优先安装到 ~/.local/bin（无需 sudo，通常在 PATH 中）
  LOCAL_BIN="$HOME/.local/bin"
  if [ -d "$LOCAL_BIN" ] && [ -w "$LOCAL_BIN" ]; then
    cp "$LOCAL_SCRIPT_DIR/sub2" "$LOCAL_BIN/sub2"
    chmod +x "$LOCAL_BIN/sub2"
    SUB2_PATH="$LOCAL_BIN/sub2"
  elif [ -w /usr/local/bin ]; then
    cp "$LOCAL_SCRIPT_DIR/sub2" /usr/local/bin/sub2
    chmod +x /usr/local/bin/sub2
    SUB2_PATH="/usr/local/bin/sub2"
  else
    sudo cp "$LOCAL_SCRIPT_DIR/sub2" /usr/local/bin/sub2
    sudo chmod +x /usr/local/bin/sub2
    SUB2_PATH="/usr/local/bin/sub2"
  fi
}

# ── 主流程 ──

echo "sub2api 一键更新脚本安装器"
echo "========================"
echo "SSH 目标：${REMOTE_USER}@${REMOTE_HOST}"
echo "部署目录：${STACK_DIR}"
echo ""

# 1. 测试 SSH 连接
echo "测试 SSH 连接..."
if ! test_ssh; then
  echo "✗ SSH 密钥认证失败：${REMOTE_USER}@${REMOTE_HOST}"
  echo "请先配置免密登录："
  echo "  ssh-copy-id ${REMOTE_USER}@${REMOTE_HOST}"
  exit 1
fi
echo "✓ SSH 连接成功"
echo ""

# 2. 部署 update-sub2api.sh 到路由器
echo "部署 update-sub2api.sh 到路由器..."
if ! deploy_remote_script; then
  echo "✗ 部署远程脚本失败"
  exit 1
fi
echo "✓ 已部署 update-sub2api.sh 到路由器"
echo ""

# 3. 在 Mac 上安装 sub2 wrapper
echo "安装 sub2 命令到本机..."
if ! install_sub2_wrapper; then
  echo "✗ 安装 sub2 wrapper 失败"
  exit 1
fi
echo "✓ 已安装 sub2 命令到 $SUB2_PATH"
echo ""

# 4. 验证安装
echo "验证安装..."
# 检查路由器上脚本存在
if ! remote_exec "test -f '$STACK_DIR/update-sub2api.sh'" >/dev/null 2>&1; then
  echo "✗ 路由器上脚本不存在: $STACK_DIR/update-sub2api.sh"
  exit 1
fi
echo "  ✓ 路由器脚本验证通过"
# 检查 Mac 上 sub2 命令可用
if ! sub2 --help >/dev/null 2>&1; then
  echo "✗ Mac 上 sub2 命令不可用"
  exit 1
fi
echo "  ✓ sub2 命令验证通过"
echo ""

# 5. 显示完成信息
echo "========================"
echo "安装完成！"
echo ""
echo "使用方法："
echo "  sub2 update              检查并更新"
echo "  sub2 update --check-only 只检查版本"
echo "  sub2 update --verify     验证服务状态"
echo "  sub2 update --backup-only 只备份"
echo ""
echo "环境变量（可选）："
echo "  SUB2_HOST=${REMOTE_HOST}"
echo "  SUB2_USER=${REMOTE_USER}"
echo "  SUB2_DIR=${STACK_DIR}"
echo "========================"
