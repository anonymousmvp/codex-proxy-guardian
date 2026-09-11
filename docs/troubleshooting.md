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

## 提示“请确保仅有一个 ChatGPT 实例在运行”

这个界面提示不足以单独确定原因。先检查是否确实启动了多个桌面主实例。任务管理器中多个 `ChatGPT.exe` 也可能是同一个应用的渲染、GPU 或网络子进程，不能仅按数量判断多开，也不要批量结束它们。

本项目的一次实际排查中，只有一个主实例，后台日志却记录了远程控制 WebSocket 连接超时（Windows 错误 `10060`）。补齐远程控制代理并重启后连接成功。这是已验证的个案，其他机器仍需根据实际日志排查。

## HTTP 返回码和连接失败

| 现象 | 如何解读 |
| --- | --- |
| `101 Switching Protocols` | WebSocket 握手成功；还应确认是哪条通道、设备是否真正可用。 |
| 远程 WebSocket 地址返回 `426` | 普通 HTTP 探测已到达要求升级的接口，不代表已完成登录或配对。 |
| `401` | 请求缺少有效授权；无登录信息的连通性探测可以出现此响应。 |
| 本程序返回 `502` | 读取系统代理、建立隧道、TLS 或转发过程中失败，结合 `request-error` 日志排查。 |
| 上游其他 `4xx`/`5xx` | 请求可能已到达服务器，但被拒绝或处理失败；`failures=0` 不能排除这些情况。 |

程序只使用当前显式 HTTP/HTTPS 系统代理。代理关闭、PAC-only 配置、SOCKS 配置或需要认证的代理不受支持；代理软件应在使用 Codex 时保持运行。

## 端口与更新

`43871` 是默认本机入口，`7897` 只是常见代理软件端口的示例。代理端口变化后，新连接会读取新值；已建立的连接不会被强制迁移。

安装位置独立于 Codex 版本目录，所以正常应用更新不会删除守护程序。若未来 Codex 改变接口或配置行为，仍需要兼容性验证。安装新版本守护程序会中断现有连接，应在空闲时操作。

安装文件、配置备份与运行数据保留在本机。向他人反馈问题时，不要直接分享真实 `settings.json`、Codex 账户文件或完整配置；本机路由、登录凭据与账户信息不应提交到 GitHub。
