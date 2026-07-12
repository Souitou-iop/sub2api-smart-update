# sub2api 智能更新脚本

自动检测并更新 Docker Compose 中的 sub2api、PostgreSQL 和 Redis，只在有新版本时才更新，不影响其他服务。

## 快速开始

在你的电脑上执行一条命令：

```sh
curl -fsSL https://raw.githubusercontent.com/Souitou-iop/sub2api-smart-update/main/install.sh -o /tmp/install-sub2api.sh && sh /tmp/install-sub2api.sh
```

脚本会交互式询问 SSH 地址、用户名和部署目录，然后自动完成：部署更新脚本到路由器 + 安装 `sub2` 命令到本机 + 验证安装。

快捷方式：
- 指定 SSH 目标：`sh /tmp/install-sub2api.sh root@192.168.1.1`
- 自定义目录：`sh /tmp/install-sub2api.sh root@192.168.1.1 /opt/sub2api-deploy`

## 这个脚本做什么？

简单来说：帮你自动更新旁路由/服务器上的三个 Docker 服务。

```
检查版本 → 有新版本？→ 备份数据库 → 拉取镜像 → 重建容器 → 等待健康 → 清理旧镜像 → 验证服务
              ↓ 没有
            跳过（但仍 pull PG/Redis 小版本）
```

默认更新的三个服务：

| 服务 | 镜像 | 用途 |
| --- | --- | --- |
| sub2api | `weishaw/sub2api:<version>` | API 网关服务 |
| PostgreSQL | `postgres:18-alpine` | 数据库 |
| Redis | `redis:8-alpine` | 缓存 |

**注意**：sub2api 使用固定版本号镜像（如 `0.1.151`），脚本会自动从 GitHub Release 查询最新版本并修改 `docker-compose.yml` 中的镜像 tag。PostgreSQL 和 Redis 使用大版本 tag，`docker compose pull` 时会自动拿到最新小版本（含安全补丁）。

## 命令一览

安装后，在 Mac 上直接执行 `sub2` 命令：

| 命令 | 说明 |
| --- | --- |
| `sub2 update` | 检查并直接更新（不询问确认） |
| `sub2 update --check-only` | 只检查版本，不更新 |
| `sub2 update --verify` | 只验证服务状态 |
| `sub2 update --backup-only` | 只备份数据库和配置，不更新 |
| `sub2 install` | 重新安装/更新脚本本身 |
| `sub2 --help` | 显示用法 |

## 一键验证

更新后，一条命令检查所有服务是否正常：

```sh
sub2 update --verify
```

会自动检查：容器状态 + 本地健康端点 + 公网健康端点。

## 只备份数据库

如果只想备份 PostgreSQL 数据库和 `docker-compose.yml`，不更新服务：

```sh
sub2 update --backup-only
```

备份文件保存在路由器的 `<deploy-dir>/backup/` 目录下：
- `sub2api-YYYYMMDDHHMMSS.dump`：PostgreSQL 自定义格式备份（可用 `pg_restore` 恢复）
- `docker-compose.yml.bak-YYYYMMDDHHMMSS`：compose 配置备份

权限为 600，最多保留最近 10 份，更旧的自动清理。

## SSH 认证方式

脚本只支持 SSH 密钥认证（不支持密码认证）。

设置 SSH 密钥实现免密登录：

```sh
# 生成 SSH 密钥（如果还没有）
ssh-keygen -t ed25519

# 复制公钥到旁路由
ssh-copy-id root@<router-ip>
```

如果密钥认证失效，脚本会直接报错并提示执行 `ssh-copy-id`。

## 前置条件

- 旁路由或服务器已安装 Docker
- Mac 上已配置 SSH 密钥认证到旁路由
- sub2api 已部署（含 `docker-compose.yml`，三服务：sub2api + PostgreSQL + Redis）
- 能访问 GitHub（用于检查更新和下载脚本）

## 安全说明

- 更新前自动备份 PostgreSQL 数据库（`pg_dump -F c`）和 `docker-compose.yml`
- 只更新 sub2api / PostgreSQL / Redis，不影响其他服务（如 HomeAssistant）
- 检测到新版本时直接更新，不询问确认（适合 cron 定时任务）
- 版本比较基于 GitHub Release 标签
- 更新成功后只尝试删除本次被替换下来的旧镜像；如果旧镜像仍被其他容器使用，会自动跳过
- 不使用 `docker system prune -af`，只清理 sub2api 相关的旧镜像和悬空镜像
- 不修改 `.env` 文件、不重置数据库密码、不碰 Cloudflare 配置
- 备份文件权限 600，包含数据库敏感数据

## 自动更新（定时任务）

如果需要定时自动更新（如 cron），直接使用 `sub2 update` 即可（脚本本身就不询问确认）：

```sh
# 例如每天凌晨 4 点检查并更新
0 4 * * * /Users/yourname/.local/bin/sub2 update >> /tmp/sub2api-update.log 2>&1
```

## 自定义配置

如果部署目录不是默认的，或需要连接其他路由器，通过环境变量覆盖：

```sh
SUB2_HOST=192.168.1.100 \
SUB2_USER=root \
SUB2_DIR=/opt/sub2api-deploy \
sub2 update --check-only
```

| 环境变量 | 默认值 | 用途 |
| --- | --- | --- |
| `SUB2_HOST` | 安装时指定的地址 | 路由器地址 |
| `SUB2_USER` | 安装时指定的用户 | SSH 用户名 |
| `SUB2_DIR` | 安装时指定的目录 | 部署目录 |
| `GITHUB_TOKEN` | 空 | 避免 GitHub API rate limit |

## 故障排查

版本检查失败：

```sh
# 查看路由器上的脚本日志
ssh root@<router-ip> "docker logs --tail 50 sub2api"
ssh root@<router-ip> "docker inspect -f '{{.Config.Image}}' sub2api"
```

健康检查超时（更新后 `/health` 未返回 200）：

```sh
# 查看容器日志
ssh root@<router-ip> "docker logs --tail 50 sub2api"

# 回滚到上一个版本
ssh root@<router-ip> "cd <deploy-dir> && \
  cp docker-compose.yml.bak-YYYYMMDDHHMMSS docker-compose.yml && \
  docker compose up -d sub2api"
```

数据库恢复（从备份恢复）：

```sh
ssh root@<router-ip> "cd <deploy-dir> && \
  docker compose stop sub2api && \
  docker exec -i sub2api-postgres pg_restore -U sub2api -d sub2api --clean --if-exists < backup/sub2api-YYYYMMDDHHMMSS.dump && \
  docker compose up -d sub2api"
```

Docker Compose 执行失败：

```sh
ssh root@<router-ip> "cd <deploy-dir> && \
  docker compose config && \
  docker compose ps"
```

## 修改管理员密码

**注意**：修改 `.env` 中的 `ADMIN_PASSWORD` 不会同步到数据库（sub2api 只在首次 AUTO_SETUP 时读环境变量）。需要直接在数据库中修改密码 hash：

```sh
ssh root@<router-ip> "docker exec sub2api-postgres psql -U sub2api -d sub2api -c \
  \"UPDATE users SET password_hash = crypt('新密码', gen_salt('bf', 10)) WHERE email = 'admin@example.com';\""
```

## 许可证

MIT
