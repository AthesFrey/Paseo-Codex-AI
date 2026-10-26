# Paseo Debian 工具包变更约定

修改代码、配置、测试或发布文档前，先阅读本文件。

## 发布标识

- 发布目录使用 `paseo-debian-YYYYMMDD<版本后缀>`，并同步更新 README、VALIDATION 和 `install.sh` 中定位发布目录的引用。
- 版本后缀只用于发布目录、文档和启动器定位；不要写入运行状态、systemd 描述、更新锁名、临时路径或 npm manifest。
- 内部身份固定为 `paseo-debian`，私有 npm manifest 版本固定为 `1.0.0`。
- 在 `VALIDATION.md` 记录实际核验的组件版本和日期；安装器运行时解析官方最新版本，不固定组件版本。

## 部署行为

- 面向 Debian 12/13 全新安装，不实现旧发布状态迁移或兼容分支。
- 保留 GitHub curl 安装入口、`--force` 覆盖安装和 `00` 至 `03` 多步部署。
- 保留更新事务回滚、托管资源卸载及卸载前的服务停止检查。Codex standalone 只有在确认服务停止后才可更新。
- `99-uninstall.sh` 必须支持从本地文件和 stdin 管道运行；部分安装失败时仍可清理工具管理的资源。
- 仅卸载工具管理的 Codex 命令链接，不删除 `/srv/paseo/tools` 中其他文件。保留项目、worktrees、非托管工具、缓存、paseo 用户及其他 systemd drop-in。
- Paseo 使用原生 systemd；不添加 Docker 依赖。
- 不添加工具包自有 checksum 清单或校验逻辑，使用官方安装器和包管理器自身的完整性机制。

## 编辑和验证

- 保持改动聚焦；只在确认代码不可达或无效时移除代码。
- 只能在隔离目录和命令 stub 中测试部署脚本，不得从开发环境操作真实 `/srv/paseo`、`/etc`、`/var` 或 systemd。
- 按改动范围运行语法检查、针对性行为测试、当前 Paseo 配置解析和 ZIP 内容/权限检查。
- `VALIDATION.md` 只记录实际执行的检查；明确注明未做真实 VPS 服务启动或 Relay 配对的情况。
- ZIP 必须从包含工具包的干净 Git commit 构建：把该 commit 导出为 tar，在 `umask 022` 下解压后再创建 ZIP，以保留 Unix 权限位。验证 ZIP 完整性、唯一顶层目录、内容和执行权限；不要使用可能丢失普通文件读取权限的 `git archive --format=zip`。
- 当前工作区若 `.git` 是无效占位目录，不要执行 `git init`；使用有效 Git 克隆作为发布构建来源。除非用户明确要求，不推送或对外发布。
