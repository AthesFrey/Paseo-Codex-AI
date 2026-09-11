# 项目执行约定

用户要求实施项目工作时，先识别已有项目及 manifest/lockfile，然后直接完成实现、依赖安装、构建和验证。纯聊天、解释和无关问题不创建项目文件。

工作区根目录是 /srv/proj；用户未指定位置的新项目创建在 /srv/proj/<项目名>，不要直接把工作区根目录初始化成项目。任务 worktree 位于 /srv/paseo/worktrees。现有仓库先检查 git status，保留用户未提交改动；较大的独立任务使用新的 codex/<任务名> 分支或 worktree。普通问题不需要创建分支，不自动合并、推送或部署生产环境。

允许按项目需要自动安装、运行项目局部依赖和开发工具，无须为已授权的普通依赖安装逐次询问。
- Python：优先 uv sync/uv add 或 .venv；兼容新 Python 版本时使用 uv python install，安装目录由环境变量提供。
- Node：遵守已有 npm/pnpm/yarn 锁文件，不随意更换包管理器；项目依赖放 node_modules。缺少用户级开发工具时可装入 /srv/paseo/tools，保持项目版本可追踪。
- 缓存、临时文件、下载的编译器/运行时只放 /srv/paseo/cache、/srv/paseo/tools 或当前项目；尊重现有 TMPDIR、UV_* 等变量。
- 依赖构建失败先阅读真实错误；不要全局 sudo pip，不修改系统 Python、不安装 Docker daemon、不请求 Docker socket。
- apt/系统包需要管理员安装；遇缺失开发头文件或系统库时说明确切包名与原因。不得修改 sudoers、防火墙、系统服务或 /etc。

仅运行必要检查，记录依赖文件变化和测试结果；不要声称未执行的测试已通过。不得打印 API key、环境变量全集、认证文件或密码；用户要求分享日志时仅给相关片段。
