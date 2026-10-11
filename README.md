# CloudDrive2 原生版一键管理工具

适用系统：Debian 12/13、Ubuntu（使用 systemd 的 Linux 主机）。仅支持 **原生二进制安装**，不安装 Docker 镜像，也不会修改你的 Docker 容器。

> 这是独立编写的第三方管理脚本，不是 CloudDrive2 官方安装器。CloudDrive2 核心二进制仅从官方 GitHub 发布仓库下载。本脚本没有在真实目标服务器完成安装验证；已通过本地模拟测试。

## 中文交互菜单

**不加参数执行脚本会直接打开菜单**（并非直接安装）。界面采用单列数字选项和分组展示：

```text
欢迎使用 CloudDrive2 管理脚本
基础功能：
1、安装 CloudDrive2
2、更新 CloudDrive2
3、卸载 CloudDrive2
-------------------
服务管理：
4、查看状态
5、查看日志
6、启动 CloudDrive2
7、停止 CloudDrive2
8、重启 CloudDrive2
-------------------
配置管理：
9、备份配置
10、恢复配置
-------------------
高级选项：
11、版本管理
12、挂载与高级设置
13、系统状态
14、关于
-------------------
0、退出脚本

请输入选项 [0-14]:
```

「版本管理」包含检查版本、查看已安装版本、回滚和备份列表；「挂载与高级设置」包含启用 FUSE allow_other、迁移程序目录和查看挂载状态。退出子菜单返回主菜单。

**首次部署**：选择 `1` 安装核心和 systemd 服务。管理员密码在 CloudDrive2 网页界面管理，原生版本不提供 Docker 子菜单，且不自动开启无人值守升级。

## GitHub 下载并打开菜单（推荐）

下载脚本、检查语法，使用 root 权限打开交互菜单：

```bash
curl -fsSL https://raw.githubusercontent.com/lwhx/cd2/main/clouddrive2-manager.sh -o /tmp/clouddrive2-manager.sh
bash -n /tmp/clouddrive2-manager.sh
sudo bash /tmp/clouddrive2-manager.sh
```

已有 v1.0.0 管理脚本的服务器，可以仅更新管理脚本而**不重新安装 CloudDrive2 核心**：

```bash
sudo install -m 0755 /tmp/clouddrive2-manager.sh /usr/local/sbin/cd2-native
sudo cd2-native
```

**注意：** `2、更新 CloudDrive2` 更新官方核心程序，管理脚本自身不会自动更新；升级管理脚本请重新下载并按上面命令替换。

## 安装

将 `clouddrive2-manager.sh` 上传到服务器，然后运行：

```bash
sudo bash clouddrive2-manager.sh
# 然后选择 1、安装 CloudDrive2
```

安装完成后会自动把管理器复制到 `/usr/local/sbin/cd2-native`，以后直接运行：

```bash
sudo cd2-native
```

系统会显示单列中文管理菜单。高级操作有子菜单；回到主菜单时重新显示安装与服务状态。

如需非交互式安装，仍可运行 `sudo bash clouddrive2-manager.sh install`。其他命令行用法：

```bash
sudo cd2-native check
sudo cd2-native update
sudo cd2-native status
sudo cd2-native backup
sudo cd2-native backups
sudo cd2-native rollback
sudo cd2-native logs
```

初次安装：访问 `http://服务器IP:19798` 进入 CloudDrive2 管理界面。脚本不会自动开启防火墙端口；建议只在可信内网访问，远程访问应使用 HTTPS 反向代理和访问控制。

## 文件路径

| 用途 | 默认路径 |
|---|---|
| 当前安装版本 | `/opt/clouddrive2/current` |
| 历史二进制版本 | `/opt/clouddrive2/releases` |
| 配置与用户数据（`CLOUDDRIVE_HOME`） | `/var/lib/clouddrive2` |
| 备份文件 | `/var/backups/clouddrive2` |
| 建议的 FUSE 挂载位置 | `/mnt/clouddrive2` |
| systemd 服务 | `/etc/systemd/system/clouddrive2.service` |
| 管理命令 | `/usr/local/sbin/cd2-native` |

挂载目录 **不会自动挂载**。安装成功后，需在 CloudDrive2 网页端的「挂载点」设置中选择 `/mnt/clouddrive2` 并启用开机自动挂载。

## FUSE 与 Docker 应用

该脚本以 `clouddrive2` 独立低权限系统用户运行核心进程；安装 fuse3 前置依赖，但 `/dev/fuse` 必须由 VPS 宿主机提供。如果没有 `/dev/fuse`，网页管理通常仍能使用，但不能通过 FUSE 挂载成 Linux 目录。

如果希望其他 Linux 用户或 Docker 容器读取 FUSE 挂载：

1. 在管理菜单中使用「允许其他用户挂载」，在 `/etc/fuse.conf` 启用 `user_allow_other`。脚本执行前会备份原配置。
2. 在 CloudDrive2 的挂载点高级设置中，检查并设置 `allow_other`、UID/GID 与权限，确保读取方有权限。
3. 对已经运行的 Docker 媒体应用，可以考虑 `:rslave` 绑定传播，例如 `-v /mnt:/mnt:rslave`；否则容器在云盘完成挂载前启动，可能只会看到空目录。是否需要宿主机共享传播还取决于当前挂载配置。

## 升级、备份、恢复与回滚

- `update` 自动查询 CloudDrive2 官方 GitHub 最新核心发布包，识别 x86_64 / aarch64 / armv7，下载后核对包大小和可用的 SHA256 摘要。
- 升级前停止服务，**完整备份** `CLOUDDRIVE_HOME`，再切换程序版本；服务无法正常启动时尝试自动切回旧版本并恢复升级前配置。
- 如果原来使用非默认管理端口，更新后以进程健康状态为主要判断依据；默认 19798 在升级前可访问时，还会验证升级后恢复响应。
- `backup` 为保证配置一致性，会短暂停止并恢复服务；备份完整数据目录可能占用大量空间，请确保磁盘有余量。
- `restore latest` 会恢复最新一份备份；也可从 `backups` 列表中选择指定备份文件。恢复前旧数据会保留在 `/var/lib` 下带 `.before-restore-...` 后缀的目录。
- `rollback` 用上一版本二进制替换当前版本，**默认不会倒退配置数据**。若版本间配置格式不兼容，应另外恢复对应的 `preupdate-*` 备份。
- 停机状态下执行更新，会保留原本停止的状态，不会擅自启动服务。

## 卸载

```bash
sudo cd2-native uninstall
```

确认后仅删除程序目录和 `clouddrive2.service`，**保留配置数据、备份与挂载目录，不执行危险的递归删除云盘文件操作**。管理脚本以及独立系统用户也保留，方便重新安装。

## 安全与兼容性说明

- 如果服务器已有 CloudDrive2 Docker 容器或第三方 `clouddrive.service`，请先自行迁移、备份并停止旧服务。本脚本不会自动迁移原 Docker `/Config` 数据，也不会删除旧服务。
- 自动识别的是官方“核心服务”版本，不是独立的桌面 / 手机客户端版本。
- 本脚本本身不会自动在线升级；“一键更新”指 CloudDrive2 核心服务的更新，也不会创建无人值守的定时更新任务。
- 如果一个新版本虽启动成功但出现应用级别的兼容问题，可手动回滚；脚本不能保证覆盖全部潜在故障。
- 自动回滚与备份**不能代替异机备份**；重要配置应定期另存到其他磁盘或服务器。

官方文档：https://www.clouddrive2.com/help.html

官方发布仓库：https://github.com/cloud-fs/cloud-fs.github.io/releases/latest
