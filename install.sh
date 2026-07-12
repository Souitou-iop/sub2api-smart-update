#!/bin/sh
set -eu

# sub2api 一键更新脚本安装器（通用版）
# 支持本地模式、远程 SSH 模式，密钥认证和密码认证，中英文双语

# GitHub raw URL（用于下载 update-sub2api.sh 到路由器）
SCRIPT_URL="https://raw.githubusercontent.com/Souitou-iop/sub2api-smart-update/main/update-sub2api.sh"
# 如果 GitHub 不可用，使用本地文件
LOCAL_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="update-sub2api.sh"
DEFAULT_STACK_DIR="/mnt/docker-data/sub2api-deploy"

# ── 用法显示（双语，--help 时 L 尚未确定，同时显示中英文）──

show_usage() {
  cat << 'USAGE_EOF'
用法 / Usage: sh install.sh [--local|user@host] [部署目录]

参数 / Arguments:
  --local       本地安装模式（不通过 SSH）/ Local install mode (no SSH)
  user@host     SSH 目标（例如 root@192.168.1.1）/ SSH target
  部署目录       部署目录（默认 /mnt/docker-data/sub2api-deploy）/ Stack directory

不传参数时，脚本会交互式询问。
Without arguments, the script runs interactively.

示例 / Examples:
  sh install.sh                                    # 交互式安装 / Interactive
  sh install.sh --local                            # 本地安装 / Local install
  sh install.sh root@192.168.1.1                   # 指定 SSH 目标 / Specify SSH target
  sh install.sh root@192.168.1.1 /opt/sub2api      # 指定目标和目录 / Specify target and dir

要求 / Requirements:
  - 远程模式：已配置 SSH 密钥认证或安装 sshpass
  - Remote mode: SSH key auth configured or sshpass installed
  - 密钥认证：执行 ssh-copy-id root@<router-ip> 配置免密登录
  - Key auth: run ssh-copy-id root@<router-ip>
USAGE_EOF
}

# ── --help 在语言选择前处理，避免阻塞 ──

case "${1:-}" in
  --help|-h)
    show_usage
    exit 0
    ;;
esac

# ── 语言选择 ──

echo "Select language / 请选择语言:"
echo "  1) English"
echo "  2) 简体中文"
printf "> "
read -r _lang < /dev/tty
case "$_lang" in
  2|zh|ZH|中文) L=zh ;;
  *) L=en ;;
esac
echo ""

# ── i18n 消息函数（根据 L 返回对应语言文本）──

msg() {
  if [ "$L" = "zh" ]; then
    case "$1" in
      mode)       echo "安装模式:" ;;
      local_m)    echo "  1) 本地安装" ;;
      remote_m)   echo "  2) 远程 SSH 安装" ;;
      host)       printf "远程地址 (例如 192.168.1.1): " ;;
      user)       printf "SSH 用户名 [root]: " ;;
      auth)       echo "SSH 认证方式:" ;;
      auth_key)   echo "  1) 免密 SSH (密钥认证)" ;;
      auth_pass)  echo "  2) 密码认证" ;;
      pass)       printf "SSH 密码: " ;;
      dir)        printf "部署目录 [$DEFAULT_STACK_DIR]: " ;;
      conn_ok)    echo "✓ 连接成功" ;;
      conn_fail)  echo "✗ 连接失败" ;;
      conn_retry) echo "请检查地址、用户名和密码是否正确" ;;
      installed)  echo "✓ 已安装脚本" ;;
      not_inst)   echo "未安装脚本" ;;
      chk_ok)     echo "✓ 已是最新版本" ;;
      chk_new)    echo "⬆ 脚本有新版本" ;;
      ask_check)  printf "检查更新？(y/n): " ;;
      ask_install) printf "安装？(y/n): " ;;
      ask_update) printf "更新？(y/n): " ;;
      doing_inst) echo "正在安装 ..." ;;
      doing_upd)  echo "正在更新 ..." ;;
      ok)         echo "✓ 完成" ;;
      fail)       echo "✗ 失败" ;;
      verify)     echo "验证服务 ..." ;;
      verify_ok)  echo "✓ 服务正常" ;;
      verify_fail) echo "✗ 服务异常" ;;
      err_dir)    echo "✗ 目录不存在: $STACK_DIR" ;;
      bye)        echo "操作完成。" ;;
      sshpass_warn) echo "提示: 密码认证需要安装 sshpass" ;;
      sshpass_install) echo "正在安装 sshpass ..." ;;
    esac
  else
    case "$1" in
      mode)       echo "Install mode:" ;;
      local_m)    echo "  1) Local" ;;
      remote_m)   echo "  2) Remote via SSH" ;;
      host)       printf "Remote address (e.g. 192.168.1.1): " ;;
      user)       printf "SSH username [root]: " ;;
      auth)       echo "SSH authentication:" ;;
      auth_key)   echo "  1) Key-based (passwordless)" ;;
      auth_pass)  echo "  2) Password" ;;
      pass)       printf "SSH password: " ;;
      dir)        printf "Stack directory [$DEFAULT_STACK_DIR]: " ;;
      conn_ok)    echo "✓ Connected" ;;
      conn_fail)  echo "✗ Connection failed" ;;
      conn_retry) echo "Please check address, username and password" ;;
      installed)  echo "✓ Script installed" ;;
      not_inst)   echo "Script not installed" ;;
      chk_ok)     echo "✓ Up-to-date" ;;
      chk_new)    echo "⬆ Script update available" ;;
      ask_check)  printf "Check for updates? (y/n): " ;;
      ask_install) printf "Install? (y/n): " ;;
      ask_update) printf "Update? (y/n): " ;;
      doing_inst) echo "Installing ..." ;;
      doing_upd)  echo "Updating ..." ;;
      ok)         echo "✓ Done" ;;
      fail)       echo "✗ Failed" ;;
      verify)     echo "Verifying services ..." ;;
      verify_ok)  echo "✓ All services OK" ;;
      verify_fail) echo "✗ Service check failed" ;;
      err_dir)    echo "✗ Directory not found: $STACK_DIR" ;;
      bye)        echo "Done." ;;
      sshpass_warn) echo "Note: Password auth requires sshpass" ;;
      sshpass_install) echo "Installing sshpass ..." ;;
    esac
  fi
}

# 封装是/否询问（支持 y/Y/yes/Yes/是）
ask_yn() {
  msg "$1"
  read -r _a < /dev/tty
  case "$_a" in
    [yY]|[yY][eE][sS]|是) return 0 ;;
    *) return 1 ;;
  esac
}

# ── 参数解析 ──

MODE="" ; REMOTE_HOST="" ; REMOTE_USER="root" ; STACK_DIR="" ; SSH_PASS="" ; AUTH_MODE=""

case "${1:-}" in
  --local)
    MODE="local"
    STACK_DIR="${2:-$DEFAULT_STACK_DIR}"
    ;;
  "")
    # 交互式稍后处理
    ;;
  *)
    MODE="remote"
    REMOTE_ARG="$1"
    REMOTE_USER="${REMOTE_ARG%@*}"
    REMOTE_HOST="${REMOTE_ARG#*@}"
    STACK_DIR="${2:-$DEFAULT_STACK_DIR}"
    ;;
esac

# ── SSH 辅助函数 ──

# 测试密钥认证（BatchMode=yes 禁用密码交互）
test_key_auth() {
  ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "echo ok" >/dev/null 2>&1
}

# 测试密码认证（自动安装 sshpass：apt-get / brew / yum）
test_pass_auth() {
  if ! command -v sshpass >/dev/null 2>&1; then
    msg sshpass_warn
    msg sshpass_install
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update && sudo apt-get install -y sshpass
    elif command -v brew >/dev/null 2>&1; then
      brew install sshpass
    elif command -v yum >/dev/null 2>&1; then
      sudo yum install -y sshpass
    else
      [ "$L" = "zh" ] && echo "无法自动安装 sshpass，请手动安装" >&2 || echo "Cannot install sshpass automatically" >&2
      return 1
    fi
  fi
  sshpass -p "$SSH_PASS" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "echo ok" >/dev/null 2>&1
}

# 远程执行命令（根据 AUTH_MODE 选择 ssh 或 sshpass）
remote() {
  if [ "$AUTH_MODE" = "key" ]; then
    ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "$@" 2>&1
  else
    sshpass -p "$SSH_PASS" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "$@" 2>&1
  fi
}

# 部署脚本（远程：curl + scp 回退；本地：curl + cp 回退）
deploy_script() {
  if [ "$MODE" = "remote" ]; then
    # 先尝试从 GitHub 下载到远程
    if remote "mkdir -p '$STACK_DIR' && curl -fsSLo '$SCRIPT_PATH' '$SCRIPT_URL' && chmod +x '$SCRIPT_PATH'"; then
      return 0
    fi
    # GitHub 失败，从本地 scp
    [ "$L" = "zh" ] && echo "  GitHub 下载失败，使用本地文件..." || echo "  GitHub download failed, using local file..."
    if [ ! -f "$LOCAL_SCRIPT_DIR/$SCRIPT_NAME" ]; then
      [ "$L" = "zh" ] && echo "  ✗ 本地文件不存在: $LOCAL_SCRIPT_DIR/$SCRIPT_NAME" >&2 || echo "  ✗ Local file not found: $LOCAL_SCRIPT_DIR/$SCRIPT_NAME" >&2
      return 1
    fi
    remote "mkdir -p '$STACK_DIR'" || true
    if [ "$AUTH_MODE" = "key" ]; then
      scp -o ConnectTimeout=10 -o BatchMode=yes "$LOCAL_SCRIPT_DIR/$SCRIPT_NAME" "${REMOTE_USER}@${REMOTE_HOST}:$SCRIPT_PATH"
    else
      sshpass -p "$SSH_PASS" scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$LOCAL_SCRIPT_DIR/$SCRIPT_NAME" "${REMOTE_USER}@${REMOTE_HOST}:$SCRIPT_PATH"
    fi
    remote "chmod +x '$SCRIPT_PATH'"
  else
    # 本地模式：先尝试 curl，失败则 cp
    mkdir -p "$STACK_DIR"
    if curl -fsSLo "$SCRIPT_PATH" "$SCRIPT_URL" && chmod +x "$SCRIPT_PATH"; then
      return 0
    fi
    [ "$L" = "zh" ] && echo "  GitHub 下载失败，使用本地文件..." || echo "  GitHub download failed, using local file..."
    if [ ! -f "$LOCAL_SCRIPT_DIR/$SCRIPT_NAME" ]; then
      [ "$L" = "zh" ] && echo "  ✗ 本地文件不存在: $LOCAL_SCRIPT_DIR/$SCRIPT_NAME" >&2 || echo "  ✗ Local file not found: $LOCAL_SCRIPT_DIR/$SCRIPT_NAME" >&2
      return 1
    fi
    cp "$LOCAL_SCRIPT_DIR/$SCRIPT_NAME" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
  fi
}

# 在 Mac 上安装 sub2 wrapper（优先 ~/.local/bin，其次 /usr/local/bin）
install_sub2_wrapper() {
  if [ ! -f "$LOCAL_SCRIPT_DIR/sub2" ]; then
    [ "$L" = "zh" ] && echo "  ✗ 本地文件不存在: $LOCAL_SCRIPT_DIR/sub2" >&2 || echo "  ✗ Local file not found: $LOCAL_SCRIPT_DIR/sub2" >&2
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

# ── 交互式模式选择 ──

if [ "$MODE" = "" ]; then
  msg mode
  echo "  $(msg local_m)"
  echo "  $(msg remote_m)"
  printf "> "
  read -r _mode < /dev/tty
  case "$_mode" in
    1|local) MODE="local" ;;
    2|remote) MODE="remote" ;;
    *) [ "$L" = "zh" ] && echo "无效选择" || echo "Invalid choice"; exit 1 ;;
  esac
fi

# ── 远程模式：询问 SSH 信息并测试连接 ──

if [ "$MODE" = "remote" ]; then
  if [ -z "$REMOTE_HOST" ]; then
    msg host
    read -r REMOTE_HOST < /dev/tty
    if [ -z "$REMOTE_HOST" ]; then
      [ "$L" = "zh" ] && echo "✗ 必须提供 SSH 地址" || echo "✗ Remote address required"
      exit 1
    fi
  fi

  # 询问用户名
  if [ "$REMOTE_USER" = "root" ]; then
    msg user
    read -r _user < /dev/tty
    if [ -n "$_user" ]; then
      REMOTE_USER="$_user"
    fi
  fi

  # 先尝试密钥认证，失败则询问认证方式
  echo ""
  [ "$L" = "zh" ] && echo "测试 SSH 连接 ..." || echo "Testing SSH connection ..."
  if test_key_auth; then
    AUTH_MODE="key"
    msg conn_ok
  else
    [ "$L" = "zh" ] && echo "密钥认证失败。" || echo "Key-based authentication failed."
    msg auth
    echo "  $(msg auth_key)"
    echo "  $(msg auth_pass)"
    printf "> "
    read -r _auth < /dev/tty
    case "$_auth" in
      1|key)
        AUTH_MODE="key"
        [ "$L" = "zh" ] && echo "请先配置免密登录：" || echo "Please set up SSH key authentication first."
        echo "Run: ssh-copy-id ${REMOTE_USER}@${REMOTE_HOST}"
        exit 1
        ;;
      2|pass)
        AUTH_MODE="pass"
        msg pass
        read -r -s SSH_PASS < /dev/tty
        echo ""
        if test_pass_auth; then
          msg conn_ok
        else
          msg conn_fail
          msg conn_retry
          exit 1
        fi
        ;;
      *)
        [ "$L" = "zh" ] && echo "无效选择" || echo "Invalid choice"
        exit 1
        ;;
    esac
  fi
else
  # 本地模式：检查目录存在
  if [ ! -d "$STACK_DIR" ]; then
    msg err_dir
    exit 1
  fi
fi

# 询问部署目录
if [ -z "$STACK_DIR" ]; then
  msg dir
  read -r STACK_DIR < /dev/tty
  [ -z "$STACK_DIR" ] && STACK_DIR="$DEFAULT_STACK_DIR"
fi

SCRIPT_PATH="$STACK_DIR/$SCRIPT_NAME"

# ── 显示主信息 ──

echo ""
echo "sub2api 一键更新脚本安装器"
echo "========================"
if [ "$MODE" = "remote" ]; then
  echo "SSH 目标：${REMOTE_USER}@${REMOTE_HOST}"
else
  [ "$L" = "zh" ] && echo "模式：本地安装" || echo "Mode: Local"
fi
echo "部署目录：${STACK_DIR}"
echo ""

# ── 检查脚本是否已安装（md5 对比 GitHub 版本）──

_installed=0
if [ "$MODE" = "remote" ]; then
  remote "test -f '$SCRIPT_PATH'" >/dev/null 2>&1 && _installed=1 || true
else
  [ -f "$SCRIPT_PATH" ] && _installed=1 || true
fi

if [ "$_installed" -eq 1 ]; then
  msg installed
  [ "$L" = "zh" ] && printf "正在检查脚本更新 ... " || printf "Checking script update ... "
  _gh=$(curl -fsSL --max-time 15 "$SCRIPT_URL" 2>/dev/null | (md5 -q 2>/dev/null || md5sum 2>/dev/null | cut -d' ' -f1) || echo "x")
  if [ "$MODE" = "remote" ]; then
    _lc=$(remote "md5sum '$SCRIPT_PATH'" 2>/dev/null | cut -d' ' -f1 || echo "y")
  else
    _lc=$(md5 -q "$SCRIPT_PATH" 2>/dev/null || md5sum "$SCRIPT_PATH" 2>/dev/null | cut -d' ' -f1 || echo "y")
  fi
  if [ "$_gh" = "$_lc" ]; then
    msg chk_ok
  else
    if [ "$MODE" = "remote" ]; then
      _local_lines=$(remote "wc -l < '$SCRIPT_PATH'" 2>/dev/null || echo "?")
    else
      _local_lines=$(wc -l < "$SCRIPT_PATH" 2>/dev/null || echo "?")
    fi
    _remote_lines=$(curl -fsSL --max-time 15 "$SCRIPT_URL" 2>/dev/null | wc -l | tr -d ' ')
    msg chk_new
    if [ "$L" = "zh" ]; then
      echo "  本地: ${_local_lines} 行 → 最新: ${_remote_lines} 行"
    else
      echo "  Local: ${_local_lines} lines → Latest: ${_remote_lines} lines"
    fi
    if ask_yn ask_update; then
      echo ""
      msg doing_upd
      deploy_script && msg ok || msg fail
    fi
  fi
else
  msg not_inst
  if ask_yn ask_install; then
    echo ""
    msg doing_inst
    deploy_script && msg ok || msg fail
  fi
fi

# ── 远程模式：安装 sub2 wrapper 到本机 ──

if [ "$MODE" = "remote" ]; then
  echo ""
  [ "$L" = "zh" ] && echo "安装 sub2 命令到本机..." || echo "Installing sub2 wrapper..."
  if ! install_sub2_wrapper; then
    [ "$L" = "zh" ] && echo "✗ 安装 sub2 wrapper 失败" || echo "✗ Install sub2 wrapper failed"
    exit 1
  fi
  [ "$L" = "zh" ] && echo "✓ 已安装 sub2 命令到 $SUB2_PATH" || echo "✓ Installed sub2 to $SUB2_PATH"
fi

# ── 验证安装 ──

echo ""
msg verify

if [ "$MODE" = "remote" ]; then
  # 检查路由器上脚本存在
  if ! remote "test -f '$SCRIPT_PATH'" >/dev/null 2>&1; then
    [ "$L" = "zh" ] && echo "  ✗ 路由器上脚本不存在: $SCRIPT_PATH" || echo "  ✗ Remote script not found: $SCRIPT_PATH"
    exit 1
  fi
  [ "$L" = "zh" ] && echo "  ✓ 路由器脚本验证通过" || echo "  ✓ Remote script verified"
  # 检查 Mac 上 sub2 命令可用
  if ! sub2 --help >/dev/null 2>&1; then
    [ "$L" = "zh" ] && echo "  ✗ Mac 上 sub2 命令不可用" || echo "  ✗ sub2 command not available"
    exit 1
  fi
  [ "$L" = "zh" ] && echo "  ✓ sub2 命令验证通过" || echo "  ✓ sub2 command verified"
else
  # 本地模式：检查脚本存在
  if [ ! -f "$SCRIPT_PATH" ]; then
    [ "$L" = "zh" ] && echo "  ✗ 脚本不存在: $SCRIPT_PATH" || echo "  ✗ Script not found: $SCRIPT_PATH"
    exit 1
  fi
  [ "$L" = "zh" ] && echo "  ✓ 脚本验证通过" || echo "  ✓ Script verified"
fi

# ── 显示完成信息 ──

echo ""
echo "========================"
[ "$L" = "zh" ] && echo "安装完成！" || echo "Installation complete!"
echo ""
if [ "$L" = "zh" ]; then
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
else
  echo "Usage:"
  echo "  sub2 update              Check and update"
  echo "  sub2 update --check-only Check version only"
  echo "  sub2 update --verify     Verify service status"
  echo "  sub2 update --backup-only Backup only"
  echo ""
  echo "Environment variables (optional):"
  echo "  SUB2_HOST=${REMOTE_HOST}"
  echo "  SUB2_USER=${REMOTE_USER}"
  echo "  SUB2_DIR=${STACK_DIR}"
fi
echo "========================"

echo ""
msg bye
