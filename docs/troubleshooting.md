# 故障排查

以下命令在 Windows PowerShell 中执行，只读取状态；明确标注的启动或卸载操作除外。

## 查看运行状态

```powershell
Get-ScheduledTask -TaskName CodexProxyGuardian | Select-Object TaskName, State
Get-Process CodexProxyGuardian -ErrorAction SilentlyContinue
Get-Content "$env:LOCALAPPDATA\OpenAI\CodexProxyGuardian\status.json"
Get-Content "$env:LOCALAPPDATA\OpenAI\CodexProxyGuardian\guardian.log" -Tail 20
```

计划任务正常运行时显示 `Running`。如果任务已存在但没有运行，可以执行 `Start-ScheduledTask -TaskName CodexProxyGuardian`。若启动后立即退出，先检查日志，不要反复重装。

`remoteControlRequests` 是远程控制接口收到的请求数，`remoteControlUpgrades` 是成功的远程控制 WebSocket 握手数。二者是该进程启动以来的累计值；已有成功记录不能证明连接此刻仍然在线。`lastEvent` 和 `updatedUtc` 也不是实时心跳，程序不主动按固定间隔刷新它们。

`appsMcpRequests` 是通过本机路由、来源和方法检查后收到的内置 Apps MCP 请求数，包含随后因登录信息问题被拒绝的请求。`appsMcpAuthenticatedRequests` 是守护程序为其中缺少授权头的请求补入登录信息的次数；请求已有授权头时不会增加此值。两项也会在进程重启后归零，都不代表上游认证成功或工具调用成功。结合带有 `appsMcp=True` 的响应日志和实际工具使用情况判断。

## 安装 EXE 没有成功

点击安装窗口的“查看安装日志”，或打开 `%LOCALAPPDATA%\OpenAI\CodexProxyGuardian\setup.log`。若还未创建安装目录，错误日志可能位于 `%TEMP%\CodexProxyGuardian-Setup-error.log`。

目标电脑需要 .NET Framework 4.8 和 Windows PowerShell 5.1。安装包内含运行程序，不需要源码或 C# 编译器。安装程序只能为当前登录的 Windows 用户配置自启动，不能代替其他用户安装。

若提示已有不同的 `openai_base_url` 或 `chatgpt_base_url`，安装会停止，避免覆盖已有服务配置。先确定该配置的用途，再决定是否改用本程序。

## 模型能回复，远程控制仍无法启用

模型与远程控制使用不同的地址配置：

| 配置 | 本机入口形式 |
| --- | --- |
| `openai_base_url` | `http://127.0.0.1:端口/本机路由/backend-api/codex` |
| `chatgpt_base_url` | `http://127.0.0.1:端口/本机路由/backend-api` |

这些值由安装工具生成，不要直接复制表格中的占位文字。只有第一项时，模型连接可以正常工作，远程控制仍可能尝试原来的网络路径。

升级后完整退出并重新打开 Codex，再进入“连接 → 控制此电脑”启用或添加设备。只关闭一个任务页不等于退出应用。地址首次变化后可能需要重新配对。

检查日志中是否出现 `101 Switching Protocols remoteControl=True`，再确认 Codex 中设备已连接并能实际控制。新连接没有对应请求记录时，优先检查 Codex 是否已重启、是否使用了正确用户配置目录。

## 模型和远程控制正常，但 Gmail、GitHub 等内置工具不可用

本项目已确认一处兼容性问题：`chatgpt_base_url` 除了影响远程控制，也决定内置 Apps MCP 的地址。地址改为 localhost 后，Codex 不再把这个 MCP 来源视为受信任的 ChatGPT 服务，将认证方式从 ChatGPT 登录改为 OAuth，因此请求可能没有携带现有登录信息。此次故障表现为 `codex_apps` 初始化返回 `451`，响应包含 `no_biscuit_no_service`；手动携带同一登录的只读初始化请求经原有转发器能成功，说明该故障不在网络转发本身。可对照[匹配版本的 Codex MCP 源码](https://github.com/openai/codex/blob/rust-v0.154.0-alpha.6.2/codex-rs/codex-mcp/src/mcp/mod.rs)中的来源校验、认证选择及 MCP 地址生成逻辑。

修复后的守护程序仅为固定上游 `https://chatgpt.com/backend-api/ps/mcp` 的 `GET`、`POST`、`DELETE` 请求补齐缺失的登录信息，允许该路径后的查询参数。它先检查本机私有路由和浏览器来源，再从安装时选定的 Codex 配置目录读取当前 `auth.json`，仅在内存中附带 ChatGPT access token 和账户标识。已有授权头保持原样；其他接口不会获得自动附带的登录信息。程序不保存或刷新令牌，也不关闭上游 TLS 证书校验。

使用包含此修复的版本升级后，完整退出并重新打开 Codex，再检查内置工具。若看到本程序返回 `401` 且日志出现 `mcp-auth-error`，检查安装使用的 Codex 配置目录是否与实际登录一致，并通过 Codex 正常登录流程更新登录状态。文件缺失、无法读取、格式损坏、非 ChatGPT 登录或账户标识冲突都会被拒绝；守护程序不会改用其他账户。旧安装未记录配置目录时，依次使用守护进程的 `CODEX_HOME` 和当前用户的默认 `.codex` 目录。

如果登录仅保存在系统凭据库（keyring），没有可读取且有效的 ChatGPT `auth.json`，当前兼容方式无法自动补齐登录。Gmail、GitHub 等连接器自身的账户授权仍由 Codex 管理；MCP 初始化成功也不能证明每个连接器已完成授权。此修复针对内置 `codex_apps`，独立配置的第三方 MCP 服务器仍需按各自的地址和认证方式排查。

## 图片生成约 106 秒后返回本机 502

若图片工具报 `Codex proxy connection failed. Check the Windows system proxy.`，这是守护程序生成的错误正文，不能据此认定官方图片服务故障。旧版将读取上游响应头的等待也限制为 20 秒；图片生成尚未返回响应头时就会被本机切断。一次已确认的故障中，三次工具调用均在约 106 秒后失败，最后一次 `502` 与守护程序的 `TimeoutException` 时间对应，期间可见反复约 20 秒的等待和重试。

修复版本将上游响应头的总等待期限设为 10 分钟，保持连接建立、TLS、会话和远程控制路由不变。分块响应不能无限重置期限；响应头读完后，正文和 WebSocket 仍流式转发。升级不需要修改 Codex 地址、重新登录或重新配对，但守护程序重启会让现有连接短暂重连。

新的 `request-error` 仅增加阶段及远控/MCP分类，不记录 URL、请求头、图片提示词或凭据。`stage=response-header` 表示等待服务器响应头失败；`proxy-connect`、`connect-response`、`tls` 则分别指向系统代理连接、CONNECT 响应和 TLS 握手阶段。应同时对照错误类型和实际调用结果，避免把所有 `502` 都当作系统代理未开启。

## 提示“请确保仅有一个 ChatGPT 实例在运行”

这个界面提示不足以单独确定原因。先检查是否确实启动了多个桌面主实例。任务管理器中多个 `ChatGPT.exe` 也可能是同一个应用的渲染、GPU 或网络子进程，不能仅按数量判断多开，也不要批量结束它们。

本项目的一次实际排查中，只有一个主实例，后台日志却记录了远程控制 WebSocket 连接超时（Windows 错误 `10060`）。补齐远程控制代理并重启后连接成功。这是已验证的个案，其他机器仍需根据实际日志排查。

## HTTP 返回码和连接失败

| 现象 | 如何解读 |
| --- | --- |
| `101 Switching Protocols` | WebSocket 握手成功；还应确认是哪条通道、设备是否真正可用。 |
| 远程 WebSocket 地址返回 `426` | 普通 HTTP 探测已到达要求升级的接口，不代表已完成登录或配对。 |
| 本程序返回 `401`，并出现 `mcp-auth-error` | 内置 MCP 的本机登录文件不可用或账户不匹配，请检查配置目录和 Codex 登录状态。请求尚未转发到上游。 |
| 上游返回 `401` | 上游未接受请求授权，可能需要通过 Codex 更新登录；无授权的其他接口连通性探测也可能出现此响应。 |
| 内置 MCP 返回 `451`，内容为 `no_biscuit_no_service` | 此次已确认的故障中，请求未携带 ChatGPT 登录信息。检查是否使用修复后的守护程序，并结合 `appsMcp=True` 和登录信息补入计数判断；不能将所有 `451` 都归为同一原因。 |
| 本程序返回 `502` | 读取系统代理、建立隧道、TLS 或转发过程中失败，结合 `request-error` 日志排查。 |
| 上游其他 `4xx`/`5xx` | 请求可能已到达服务器，但被拒绝或处理失败；`failures=0` 不能排除这些情况。 |

程序只使用当前显式 HTTP/HTTPS 系统代理。代理关闭、PAC-only 配置、SOCKS 配置或需要认证的代理不受支持；代理软件应在使用 Codex 时保持运行。

## 端口与更新

`43871` 是默认本机入口，`7897` 只是常见代理软件端口的示例。代理端口变化后，新连接会读取新值；已建立的连接不会被强制迁移。

安装位置独立于 Codex 版本目录，所以正常应用更新不会删除守护程序。若未来 Codex 改变接口或配置行为，仍需要兼容性验证。安装新版本守护程序会中断现有连接，应在空闲时操作。

安装文件、配置备份与运行数据保留在本机。向他人反馈问题时，不要直接分享真实 `settings.json`、Codex 账户文件或完整配置；本机路由、登录凭据与账户信息不应提交到 GitHub。
