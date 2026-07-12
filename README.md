# sub2api-smart-update

一键更新路由器上的 sub2api + PostgreSQL + Redis Docker 服务。

## 快速安装

在 Mac 上执行：

```sh
sh install.sh
```

默认连接 `root@192.168.31.81`，部署目录 `/mnt/docker-data/sub2api-deploy`。

支持参数覆盖：

```sh
sh install.sh user@host /custom/dir
```

## 使用

安装完成后，在 Mac 上直接执行：

```sh
sub2 update
```

脚本会自动完成：检查版本 → 备份数据库 → 拉取新镜像 → 重启容器 → 健康检查 → 清理旧镜像 → 验证。

## 要求

- Mac 上已配置 SSH 密钥认证到路由器（`ssh-copy-id root@192.168.31.81`）
- 路由器上已安装 Docker
- sub2api 已部署在 `/mnt/docker-data/sub2api-deploy/`

## License

MIT
