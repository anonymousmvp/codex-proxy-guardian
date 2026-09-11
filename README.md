# Codex Proxy Guardian

让 Windows 上的 Codex 模型连接自动使用 Windows 系统代理。登录 Windows 后，独立 EXE 在后台常驻；Codex 仍从原来的图标启动，无需专用启动脚本。

```text
Codex → 127.0.0.1:43871（本程序）→ Windows 系统代理（例如 127.0.0.1:7897）→ chatgpt.com
```

`43871` 是本程序的本机入口。系统代理软件已经占用 `7897`，两个程序不能监听同一地址的同一端口。每次建立新的上游连接时，本程序重新读取系统代理，所以代理端口改变后无须修改 Codex 的入口。

## 支持范围

- Windows 10/11，.NET Framework 4.8，Windows PowerShell 5.1。
- 显式 HTTP/HTTPS 系统代理，通过 HTTP CONNECT 隧道连接服务器；TLS 证书校验保持开启。
- Codex 模型请求、HTTP 流式响应和 WebSocket。
- 使用同一份用户配置的 Codex 桌面应用和 Codex CLI。
- 用户登录后自启动；进程异常退出后，计划任务每分钟尝试重新启动，最多 999 次。
- 不更改全局代理环境变量，不注入其他进程，不安装证书或网络驱动。

仅转发 `chatgpt.com/backend-api/codex` 下的模型接口。浏览器、更新下载、MCP 工具和远程控制等其他连接不在此范围。该项目不是通用代理工具，也不是 OpenAI 官方组件。

## 构建和检查

在 Windows PowerShell 中进入项目目录：

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\build.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\check.ps1
```

使用 Windows 自带的 .NET Framework C# 编译器，无须下载 NuGet 包或安装 .NET SDK。输出为 `build\CodexProxyGuardian.exe`。也提供 `CodexProxyGuardian.csproj`，可使用具有 .NET Framework 4.8 开发工具的 Visual Studio 打开。

自动检查覆盖配置增删、重复安装、保留其他配置、旧配置迁移以及本机入口的请求限制。测试使用随机端口，不修改系统代理、不调用真实模型、不停止当前安装的守护程序。GitHub Actions 在 Windows 上执行相同检查。

## 安装

先确认 Windows 系统代理已经打开，再执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\install.ps1
```

安装工具会构建 EXE，保存到 `%LOCALAPPDATA%\OpenAI\CodexProxyGuardian`，创建 `CodexProxyGuardian` 登录计划任务，并在 Codex 用户配置中设置 `openai_base_url`。默认配置文件为 `%USERPROFILE%\.codex\config.toml`；若设置了 `CODEX_HOME`，则使用对应目录。

安装后完整退出并重新打开 Codex 一次。之后使用原来的桌面、开始菜单或任务栏图标。安装脚本仅在安装或升级时运行，日常后台运行不依赖 PowerShell。

默认端口为 `43871`；首次安装可通过 `-Port` 指定其他端口。已有安装会保留自己的随机路由值，禁止无意覆盖用户已有的其他 `openai_base_url`。安装前会在安装目录的 `backups` 中备份配置。

升级本程序时重新运行安装工具，会短暂重启守护程序并中断现有模型连接，应在 Codex 空闲时进行。整理或拉取这个 Git 仓库本身不会更新正在运行的程序。

## 运行行为与限制

- 只监听 `127.0.0.1`，不是局域网服务；请求必须包含本机生成的随机路由值。
- 拒绝带 `Origin` 的浏览器请求，不接受任意目标地址，不记录对话内容、请求头或登录凭据。
- 代理关闭、PAC-only 配置或代理不可用时返回连接失败，不自动退回直连。目前不支持 SOCKS、HTTPS-to-proxy 或需要认证的代理。
- 代理变化只对新连接生效；已有 WebSocket 断开重连后使用新代理。
- 普通 HTTP 请求采用单连接单请求，WebSocket 建立后双向转发；不提供通用 HTTP/2 代理或任意协议兼容保证。
- 自启动发生在当前用户登录 Windows 后，不是在登录前运行的系统服务。
- 程序不位于 Codex 更新目录中。正常更新不会覆盖它，但未来 Codex 若修改接口或配置语义，需要重新验证。

状态和简短日志位于安装目录的 `status.json` 与 `guardian.log`。任务管理器中进程名为 `CodexProxyGuardian.exe`，任务计划程序中任务名为 `CodexProxyGuardian`。

## 停用

先完整退出 Codex，然后执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\uninstall.ps1
```

卸载工具只移除该程序拥有的 `openai_base_url`，保留其他 Codex 配置，结束后台进程并删除登录计划任务。安装文件和备份保留，便于检查或恢复。重新打开 Codex 后回到原来的连接方式。

## 已完成的连接验证

初始版本于 2026-09-12 在 Windows 上通过真实 Codex 对话验证，包含普通 HTTP 请求、WebSocket `101 Switching Protocols` 和模型回复 `OK`。另一次测试直接读取已保存的用户配置并成功完成对话。此验证是当时的运行结果，不代表所有代理或未来 Codex 版本都兼容。

Codex 提供的服务器地址配置见 [OpenAI 配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)。

## 项目内容与同步

源码、构建/安装工具、自动检查和文档保存在 Git 中。真实 `settings.json`、随机路由值、Codex 登录信息、个人配置、运行日志和编译产物不提交。

多端开发前先 `git fetch` 并安全同步；完成修改后执行构建和检查，再提交、推送。运行和测试依赖 Windows，Mac 或手机可通过 GitHub 阅读、编辑源码，但不能直接运行这个 Windows 程序。
