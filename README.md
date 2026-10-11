# CloudDrive2 原生版一键管理工具

适用：Debian 12/13、Ubuntu（systemd）。部署 CloudDrive2 **原生二进制服务**，不依赖 Docker。管理脚本不是 CloudDrive2 官方项目，也不会自动同步下载整个云盘。

## 📁 目录结构（v1.3.0）

**程序与本地配置现在统一放在 `/opt/clouddrive2` 下。** 网盘文件仍存储在各自的云盘服务端。

```text
/opt/clouddrive2/
├── current -> releases/1.x.x  # 当前运行版本（软链接）
├── releases/                 # 各版本二进制程序
├── previous -> releases/...  # 上一个程序版本（存在时）
└── config/                   # CloudDrive2 本地配置与运行状态
```

| 用途 | 默认路径 |
|---|---|
| 下载的管理脚本 | `/root/clouddrive2-manager.sh` |
| 程序与配置根目录 | `/opt/clouddrive2` |
| 当前程序版本 | `/opt/clouddrive2/current` |
| **本地配置目录（CLOUDDRIVE_HOME）** | **`/opt/clouddrive2/config`** |
| 程序历史版本 | `/opt/clouddrive2/releases` |
| 备份目录（独立于程序目录） | `/var/backups/clouddrive2` |
| 网盘挂载位置（需在 Web UI 中启用） | `/mnt/clouddrive2` |
| systemd 服务 | `/etc/systemd/system/clouddrive2.service` |
| 已安装的菜单管理命令 | `/usr/local/sbin/cd2-native` |
| 自动更新检测缓存 | `/var/cache/clouddrive2-native-manager` |

**配置目录并不等于网盘文件目录。** 里面是 CloudDrive2 账号相关状态、挂载设置、缓存、运行数据等；原云盘文件不在此复制一份。备份单独放在 `/var/backups`，避免卸载程序时一起误删。

## 安装 / 打开中文菜单

以 root 登录 Debian/Ubuntu 后：

```bash
curl -fsSL https://raw.githubusercontent.com/lwhx/cd2/main/clouddrive2-manager.sh -o /root/clouddrive2-manager.sh
bash -n /root/clouddrive2-manager.sh
bash /root/clouddrive2-manager.sh
```

进入主菜单选择 `1、安装 CloudDrive2`。以后也可以用 `cd2-native` 打开菜单；若没有 root 权限，则使用 `sudo cd2-native`。

如果服务器上已经安装了较旧的管理脚本，可以只更新管理脚本而不重装核心：

```bash
install -m 0755 /root/clouddrive2-manager.sh /usr/local/sbin/cd2-native
cd2-native
```

网页界面默认端口为 `19798`。建议仅在可信网络中访问，公网环境应通过 HTTPS 反代及访问控制保护。

## 卸载：新增两种模式

在主菜单选 `3、卸载 CloudDrive2`：

```text
CloudDrive2 卸载选项：
1、仅卸载程序（保留配置、缓存和备份，可重新安装）
2、卸载并删除全部本地数据（配置、缓存、备份均删除）
0、返回主菜单
-------------------
远端网盘文件与 /mnt/clouddrive2 挂载目录始终不会删除。
请输入选项 [0-2]:
```

- **模式 1（默认推荐）**：需要输入 `UNINSTALL` 确认；停止并禁用 systemd 服务，移除程序文件与服务单元，保留 `/opt/clouddrive2/config` 及 `/var/backups/clouddrive2`。重新安装可复用保留配置。
- **模式 2（危险）**：需要完整输入 `DELETE-ALL-LOCAL-DATA` 再执行。删除整套 `/opt/clouddrive2`、本地配置、管理备份、版本检测缓存；旧版尚未迁移时，还会删除其 `/var/lib/clouddrive2` 目录。
- 无论选择哪种模式，**不会递归删除云端网盘文件，也不会删除或遍历 `/mnt/clouddrive2`**。检测到待删除目录内存在活跃挂载时，会拒绝卸载，以免误操作 FUSE 内容。
- 管理脚本文件与系统服务用户会保留，便于日后重新安装；彻底卸载不包括对 CloudDrive2 云端账号、订阅或网盘内容执行远程删除操作。

命令行与菜单等效：

```bash
cd2-native uninstall           # 保留配置
cd2-native uninstall --purge   # 删除全部本地配置、缓存和备份（二次强确认）
```

## 旧版配置迁移（v1.2.x → v1.3.0）

**升级管理脚本不等于迁移用户配置。** 对已用旧版脚本部署的服务器，默认继续读取旧目录 `/var/lib/clouddrive2`，保证现有配置不被误判为不存在。

如需改为同目录布局：

1. 先下载 v1.3.0 的新脚本，更新 `cd2-native`。
2. 运行 `cd2-native`，选择 **12、挂载与高级设置 → 4、迁移旧版配置到程序目录**；或执行 `cd2-native migrate-config`。
3. 脚本会停止服务、备份旧配置、复制到 `/opt/clouddrive2/config`、更新 systemd 与状态记录，并验证新服务；成功后清理旧目录。
4. 如果迁移失败，保留旧目录并尝试恢复旧版服务设置。迁移前备份保存在 `/var/backups/clouddrive2`，可用于人工恢复。

迁移过程可能短暂中断 FUSE 挂载和依赖它的媒体服务，请选择低使用时段操作。**如果旧版 CloudDrive2 使用 Docker 或别的安装器部署，本工具不会自动接管或清除对方的数据。**

历史备份兼容：支持管理器旧版生成的 `clouddrive2/` 备份结构，以及新版 `config/` 结构。恢复前会核验 SHA256，且会保留被覆盖的配置目录以便排查。

## 主菜单及其他功能

```text
欢迎使用 CloudDrive2 管理脚本

程序目录：/opt/clouddrive2/current
配置目录：/opt/clouddrive2/config
更新检测：已是最新版本 ...

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

- 打开主菜单时自动比对官方 GitHub Releases 最新核心版本，成功结果缓存 6 小时，检查失败不影响使用。
- **不会自动安装更新**；选择 2 才会下载核心、先备份配置再升级，启动失败时尝试回滚。
- 通过 `11` 查看版本及回滚，`12` 管理 FUSE allow_other、配置迁移和程序目录搬迁。
- 查看日志显示最近 80 行；需要持续跟踪时运行 `cd2-native logs`。
- FUSE 挂载要在 CloudDrive2 Web 界面配置；需要宿主机提供 `/dev/fuse`，并针对其他 Docker 应用配置权限及挂载传播。

该脚本在 GitHub Actions 中检查语法及模拟菜单/文件操作，但还需在你的真实 Debian VPS 上验证 FUSE 与 CloudDrive2 服务的完整生命周期。

官方文档：https://www.clouddrive2.com/help.html  
官方发布：https://github.com/cloud-fs/cloud-fs.github.io/releases/latest
