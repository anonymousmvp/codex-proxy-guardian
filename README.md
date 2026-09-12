# Codex Proxy Guardian

让 Windows 上的 Codex 模型连接、“控制此电脑”的远程控制连接及内置应用连接器自动使用 Windows 系统代理。登录 Windows 后，独立 EXE 在后台常驻；Codex 仍从原来的图标启动，无需专用启动脚本。

## 在新电脑上安装

1. 下载[最新安装包](https://github.com/anonymousmvp/codex-proxy-guardian/releases/latest/download/CodexProxyGuardian-Setup.exe) `CodexProxyGuardian-Setup.exe`，或把已有的安装 EXE 复制到新电脑；版本记录见 [Releases](https://github.com/anonymousmvp/codex-proxy-guardian/releases/latest)。
2. 在当前 Windows 用户下双击 EXE。安装界面会自动执行安装，无须下载源码或手动运行 PowerShell。
3. 出现“安装完成”后，完整退出并重新打开 Codex。保持 Windows 系统代理开启，再使用模型对话或进入“连接 → 控制此电脑”设置远程控制。

安装包内含守护程序和安装组件，安装过程不下载依赖。目标电脑需已有 .NET Framework 4.8 和 Windows PowerShell 5.1；它不会安装 Codex、代理软件，也不会迁移原电脑的登录账户、代理节点或配对设备。每台电脑都会读取自己的系统代理，并生成自己的本机路由值。

这是未签名的自制安装包。企业管理策略可能限制执行；它不会关闭或修改这些策略。仓库及 Release 公开，无须登录即可下载。

```text
Codex → 127.0.0.1:43871（本程序）→ Windows 系统代理（例如 127.0.0.1:7897）→ chatgpt.com
```

`43871` 是本程序的本机入口。系统代理软件已经占用 `7897`，两个程序不能监听同一地址的同一端口。每次建立新的上游连接时，本程序重新读取系统代理，所以代理端口改变后无须修改 Codex 的入口。

## 支持范围

- Windows 10/11，.NET Framework 4.8，Windows PowerShell 5.1。
- 显式 HTTP/HTTPS 系统代理，通过 HTTP CONNECT 隧道连接服务器；TLS 证书校验保持开启。
- Codex 模型请求、HTTP 流式响应和 WebSocket。
- 远程控制的注册、令牌刷新、配对、设备接口与 WebSocket。
- Gmail、GitHub 等通过 Codex 内置 `codex_apps` MCP 使用的应用连接器，需使用 ChatGPT 登录并将凭据保存在对应 Codex 配置目录的 `auth.json` 中。
- 使用同一份用户配置的 Codex 桌面应用和 Codex CLI。
- 用户登录后自启动；进程异常退出后，计划任务每分钟尝试重新启动，最多 999 次。
- 不更改全局代理环境变量，不注入其他进程，不安装证书或网络驱动。

仅转发到 `chatgpt.com/backend-api` 下的接口。模型连接使用 `openai_base_url`，远程控制、内置应用 MCP 和相关账户接口使用 `chatgpt_base_url`；仅设置前者无法代理远程控制。浏览器、更新下载、SSH、独立 MCP 服务器等其他连接不在此范围。该项目不是通用代理工具，也不是 OpenAI 官方组件。

Codex 不会向 localhost MCP 地址自动发送 ChatGPT 登录凭据。为兼容这个安全边界，本程序仅在固定的 `/backend-api/ps/mcp` 接口缺少 `Authorization` 时，从当前 Codex 配置目录读取已有的 ChatGPT 访问令牌和账户 ID，向固定的官方服务器附带它们。每个请求重新读取，跟随登录、账户切换和令牌更新；不会复制、缓存、刷新或记录令牌。已有授权原样保留，账户冲突或登录文件不可用时返回 `401`。仅存放在系统钥匙串中、没有 `auth.json` 的登录暂不支持自动补齐；本程序不会更改凭据存储方式。

## 构建和检查

在 Windows PowerShell 中进入项目目录：

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\build.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\check.ps1
```

使用 Windows 自带的 .NET Framework C# 编译器，无须下载 NuGet 包或安装 .NET SDK。构建生成：

| 文件 | 用途 |
| --- | --- |
| `build\CodexProxyGuardian-Setup.exe` | 单文件安装包，复制到新电脑后双击即可安装。 |
| `build\CodexProxyGuardian.exe` | 后台程序本体，需由安装工具生成配套配置，不应直接作为安装包分发。 |

`CodexProxyGuardian.csproj` 用于在 Visual Studio 中编辑和构建后台程序；完整安装包通过 `build.ps1` 构建，安装界面源码为 `src/Setup.cs`。

自动检查覆盖两个服务器地址的配置增删、重复安装、保留其他配置、旧配置迁移、远程控制路径、MCP 凭据范围与轮换、本机入口的请求限制，以及安装包内嵌文件与原始构建结果的 SHA-256 一致性。测试使用随机端口和临时目录中的合成登录文件，不读取真实登录凭据、不修改系统代理、不调用真实模型、不停止当前安装的守护程序。GitHub Actions 在 Windows 上执行相同检查。

可选的完整安装检查：`powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\install-smoke.ps1`。它会创建独立的测试目录、随机端口和临时计划任务，测试首次安装、重复安装与卸载，然后清理测试任务；不会重装正在使用的守护程序。测试文件保留在被 Git 忽略的 `build` 目录中。

## 自动发布安装包

每次推送到 `main`，GitHub Actions 都会在 Windows 上运行 `build.ps1` 和 `tests/check.ps1`。全部成功后，为该提交创建 `build-<完整提交 SHA>` 的 Release，上传同一个经过检查的 `CodexProxyGuardian-Setup.exe` 和 `SHA256SUMS.txt` 并标记为 Latest。发布说明包含源码提交、构建记录和安装包 SHA-256；失败的构建不会替换已有安装包。

下载入口固定为 [releases/latest/download/CodexProxyGuardian-Setup.exe](https://github.com/anonymousmvp/codex-proxy-guardian/releases/latest/download/CodexProxyGuardian-Setup.exe)，会跟随最新成功发布的版本更新。其他网站可以长期引用这个入口；使用下载中转时，应让中转服务请求这个完整地址。

PR 和其他分支只构建、检查；发布任务仅对 `main` 开放写权限。并发更新会取消旧运行，发布前再次检查远端 `main`，避免旧提交覆盖 Latest。重新运行同一提交会复用已发布的安装包，未完成的草稿则继续上传和发布。也可在 Actions 的 `Build, check and release` 页面选择 `main` 手动运行，无须本机打包或手动打标签。

## 从源码安装与升级

先确认 Windows 系统代理已经打开，再执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\install.ps1
```

安装工具会构建 EXE，保存到 `%LOCALAPPDATA%\OpenAI\CodexProxyGuardian`，创建 `CodexProxyGuardian` 登录计划任务，并在 Codex 用户配置中设置 `openai_base_url` 和 `chatgpt_base_url`。默认配置文件为 `%USERPROFILE%\.codex\config.toml`；若设置了 `CODEX_HOME`，则使用对应目录。安装时将配置目录保存为本机 `settings.json` 的 `CodexConfigDirectory`，确保计划任务使用同一份登录文件；不会把登录凭据写进该设置文件。

安装后完整退出并重新打开 Codex 一次。之后使用原来的桌面、开始菜单或任务栏图标。安装脚本仅在安装或升级时运行，日常后台运行不依赖 PowerShell。

默认端口为 `43871`；首次安装可通过 `-Port` 指定其他端口。已有安装会保留自己的随机路由值，禁止无意覆盖用户已有的其他 `openai_base_url` 或 `chatgpt_base_url`。安装前会在安装目录的 `backups` 中备份配置。第一次从仅模型代理版本升级后，远程控制可能需要重新添加设备，因为 Codex 按连接地址保存配对状态。

升级本程序时双击新的安装 EXE，或重新运行源码安装工具。升级会短暂重启守护程序并中断现有模型和远程控制连接，应在 Codex 空闲时进行。整理或拉取这个 Git 仓库本身不会更新正在运行的程序。

## 运行行为与限制

- 只监听 `127.0.0.1`，不是局域网服务；请求必须包含本机生成的随机路由值。
- 拒绝带 `Origin` 的浏览器请求，不接受任意目标地址，不记录对话内容、请求头或登录凭据。
- 代理关闭、PAC-only 配置或代理不可用时返回连接失败，不自动退回直连。目前不支持 SOCKS、HTTPS-to-proxy 或需要认证的代理。
- 代理变化只对新连接生效；已有 WebSocket 断开重连后使用新代理。
- 普通 HTTP 请求采用单连接单请求，WebSocket 建立后双向转发；不提供通用 HTTP/2 代理或任意协议兼容保证。
- 自启动发生在当前用户登录 Windows 后，不是在登录前运行的系统服务。
- 程序不位于 Codex 更新目录中。正常更新不会覆盖它，但未来 Codex 若修改接口或配置语义，需要重新验证。

状态和简短日志位于安装目录的 `status.json` 与 `guardian.log`。`remoteControlRequests` 记录远程控制请求次数，`remoteControlUpgrades` 记录成功的远程控制 WebSocket 握手次数。这些数值在进程重启后归零，是累计记录，不表示当前在线设备数；`failures` 统计转发和本机 MCP 认证异常，不包含所有上游 HTTP 错误。模型握手成功不代表远程控制已连接。任务管理器中进程名为 `CodexProxyGuardian.exe`，任务计划程序中任务名为 `CodexProxyGuardian`。

`appsMcpRequests` 记录通过入口与方法检查的内置 MCP 请求，`appsMcpAuthenticatedRequests` 记录自动补齐登录的次数；后者不等于工具调用成功次数。MCP 响应日志标记 `appsMcp=True`，便于区分模型与连接器请求。`mcp-auth-error` 表示登录文件不可用或账户不匹配，也计入 `failures`，不会记录凭据、账户 ID 或文件内容。

遇到问题请查看 [故障排查](docs/troubleshooting.md)，其中说明了代理连通、WebSocket 握手和设备实际连接之间的区别。

## 停用

先完整退出 Codex，然后执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\uninstall.ps1
```

通过 EXE 安装、没有源码目录时，可在 PowerShell 中执行安装目录内的卸载工具：

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "$env:LOCALAPPDATA\OpenAI\CodexProxyGuardian\uninstall.ps1"
```

如果安装时使用了自定义 `CODEX_HOME`，卸载时应使用相同设置。开发测试中的自定义安装目录和任务名，也应通过对应参数传给卸载工具。

卸载工具只移除该程序拥有的 `openai_base_url` 和 `chatgpt_base_url`，保留其他 Codex 配置，结束后台进程并删除登录计划任务。安装文件和备份保留，便于检查或恢复。重新打开 Codex 后回到原来的连接方式。

## 已完成的连接验证

初始版本于 2026-09-12 在 Windows 上通过真实 Codex 对话验证，包含普通 HTTP 请求、WebSocket `101 Switching Protocols` 和模型回复 `OK`。另一次测试直接读取已保存的用户配置并成功完成对话。此验证是当时的运行结果，不代表所有代理或未来 Codex 版本都兼容。

补齐远程控制转发后，2026-09-12 04:51（北京时间）日志记录了 `101 Switching Protocols remoteControl=True`，Codex 的远程控制状态变为 `Connected`；用户随后确认远程连接可用。该记录同时验证了远程控制通道，不能用此前的模型测试代替。

单文件安装包已经完成内嵌文件校验，以及隔离环境下的首次安装、重复安装、登录计划任务启动和卸载验证。测试确认原有 Codex 配置、用户级代理环境变量和正在使用的守护进程没有被修改。

2026-09-12 修复了本机内置应用 MCP 因未携带 ChatGPT 登录而返回 `451 no_biscuit_no_service` 的问题。更新本机安装后，在请求端不主动提供授权的情况下，实际完成 MCP `initialize` 和 `tools/list`，当时列出 224 个工具（Gmail 21 个、GitHub 90 个），桌面日志记录 `codex_apps status=ready`，远程控制也重新完成 `101` 握手。这验证了 MCP 初始化、工具加载及远程通道，未执行邮件发送或仓库写入；工具数量随账户连接和版本变化。

Codex 提供的服务器地址配置见 [OpenAI 配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)。

## 项目内容与同步

源码、构建/安装工具、自动检查和文档保存在 Git 中。真实 `settings.json`、随机路由值、Codex 登录信息、个人配置、运行日志和编译产物不提交。

多端开发前先 `git fetch` 并安全同步；完成修改后执行构建和检查，再提交、推送。运行和测试依赖 Windows，Mac 或手机可通过 GitHub 阅读、编辑源码，但不能直接运行这个 Windows 程序。
