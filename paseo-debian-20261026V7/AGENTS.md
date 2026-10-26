# Paseo Debian 工具包开发约定

## 发布标识

- 当前发布目录为 `paseo-debian-20261026V7`；目录名只用于发布和文档定位。
- 运行时内部标识固定为 `paseo-debian`，私有 npm manifest 版本固定为 `1.0.0`。
- 安装器运行时解析官方当前版本；`VALIDATION.md` 只记录实际核验的版本和结果。

## 部署行为

- 面向 Debian 12/13 全新安装。
- 保留 GitHub curl 安装入口、`--force` 覆盖安装和 `00` 至 `03` 多步部署。
- 保留更新事务回滚、托管资源卸载和卸载前的服务停止检查。Codex standalone 只可在确认服务停止后更新。
- `99-uninstall.sh` 必须支持本地文件和 stdin 管道执行；安装中断后仍可清理工具管理的资源。
- 只卸载本工具管理的 Codex 命令链接，不删除 `/srv/paseo/tools` 中的其他文件。保留项目、worktrees、非托管工具、缓存、paseo 用户及其他 systemd drop-in。
- Paseo 使用原生 systemd；不添加 Docker 依赖。
- Relay 检查器必须从 `/srv/paseo/runtime` 加载已安装依赖，不得从工具包目录猜测 `node_modules` 位置。

## 编辑和验证

- 仅移除确认不可达、重复且无用途的代码；保持安装、更新、回滚和卸载行为完整。
- 只能在隔离目录和命令 stub 中测试部署脚本，不得从开发环境操作真实 `/srv/paseo`、`/etc`、`/var` 或 systemd。
- 按改动范围运行语法检查、针对性行为测试、当前 Paseo 配置解析和 ZIP 内容/权限检查。
- `VALIDATION.md` 只记录实际执行的检查；明确注明未做真实 VPS 服务启动或 Relay 配对的项目。
- 发布 ZIP 必须从包含全部发布内容的干净 Git commit 构建。构建前若 `git status --porcelain` 非空，立即拒绝构建。
- 使用 `git archive --format=tar <完整提交 SHA>` 导出，在 `umask 022` 下解压后创建 ZIP，以保留 Unix 权限位；构建两次并比较 checksum。
- 记录完整提交 SHA、ZIP SHA-256 和构建工具版本。验证 ZIP 完整性、单一顶层目录、文件清单和模式位。
- 当前工作区若 `.git` 是无效占位目录，不执行 `git init`；使用有效 Git 克隆作为构建源。不推送、不打 tag。
