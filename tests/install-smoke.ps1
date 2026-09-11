# Optional Windows integration check. Creates and removes an isolated scheduled task.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$testId = [Guid]::NewGuid().ToString('N')
$testRoot = Join-Path $project ('build\install-check-' + $testId)
$payloadDirectory = Join-Path $testRoot 'payload'
$installDirectory = Join-Path $testRoot 'installed'
$configDirectory = Join-Path $testRoot 'codex-config'
$taskName = 'CodexProxyGuardian-Test-' + $testId
$exe = Join-Path $installDirectory 'CodexProxyGuardian.exe'
$existingProcesses = @(Get-Process CodexProxyGuardian -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$proxyBefore = @{}
foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY')) { $proxyBefore[$name]=[Environment]::GetEnvironmentVariable($name,'User') }
$liveConfigDirectory = if($env:CODEX_HOME) {$env:CODEX_HOME} else {Join-Path $env:USERPROFILE '.codex'}
$liveConfig = Join-Path $liveConfigDirectory 'config.toml'
$liveHash = if(Test-Path -LiteralPath $liveConfig) {(Get-FileHash -LiteralPath $liveConfig).Hash} else {$null}
$probe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
$probe.Start(); $port=$probe.LocalEndpoint.Port; $probe.Stop()
New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
$original = "model = `"keep-existing-model`"`r`n[desktop]`r`nname = `"keep-settings`"`r`n"
$configPath = Join-Path $configDirectory 'config.toml'
[IO.File]::WriteAllText($configPath,$original,(New-Object Text.UTF8Encoding($false)))
$setup = Start-Process -FilePath (Join-Path $project 'build\CodexProxyGuardian-Setup.exe') -ArgumentList @('--verify-package',('"'+$payloadDirectory+'"')) -WindowStyle Hidden -Wait -PassThru
if($setup.ExitCode -ne 0) {throw 'Package extraction failed.'}
try {
    $route = $null
    foreach($pass in 1..2) {
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File (Join-Path $payloadDirectory 'install.ps1') -PrebuiltExecutable (Join-Path $payloadDirectory 'Guardian.exe') -InstallDirectory $installDirectory -CodexConfigDirectory $configDirectory -ScheduledTaskName $taskName -Port $port
        if($LASTEXITCODE -ne 0) {throw "Installation pass $pass failed."}
        $settings = Get-Content -LiteralPath (Join-Path $installDirectory 'settings.json') -Raw | ConvertFrom-Json
        if($route -and $route -ne $settings.Route) {throw 'Reinstall changed the private route.'}
        $route = $settings.Route
        $content = [IO.File]::ReadAllText($configPath)
        if($content -notmatch 'openai_base_url' -or $content -notmatch 'chatgpt_base_url' -or -not $content.Contains('keep-existing-model')) {throw 'Installation damaged configuration.'}
        if((Get-ScheduledTask -TaskName $taskName).State -ne 'Running') {throw 'Test scheduled task is not running.'}
    }
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File (Join-Path $payloadDirectory 'uninstall.ps1') -InstallDirectory $installDirectory -CodexConfigDirectory $configDirectory -ScheduledTaskName $taskName
    if($LASTEXITCODE -ne 0) {throw 'Uninstallation failed.'}
    if([IO.File]::ReadAllText($configPath) -cne $original) {throw 'Uninstall did not restore the original configuration.'}
    if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {throw 'Uninstall left its task registered.'}
} finally {
    if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $taskName
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    Get-Process CodexProxyGuardian -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $exe} | ForEach-Object {$_.Kill();$_.WaitForExit()}
}
foreach($name in $proxyBefore.Keys) {if([Environment]::GetEnvironmentVariable($name,'User') -cne $proxyBefore[$name]) {throw 'User proxy environment changed.'}}
if($liveHash -and (Get-FileHash -LiteralPath $liveConfig).Hash -ne $liveHash) {throw 'Live Codex config changed during the check.'}
foreach($processId in $existingProcesses) {if(-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {throw 'An existing guardian process stopped.'}}
Write-Output 'Installation, repeat installation, scheduled autostart, uninstallation and isolation checks all passed.'
