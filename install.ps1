[CmdletBinding()]
param([ValidateRange(1024,65535)][int]$Port = 43871)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\Config.psm1') -Force
$installDirectory = Join-Path $env:LOCALAPPDATA 'OpenAI\CodexProxyGuardian'
$executable = Join-Path $installDirectory 'CodexProxyGuardian.exe'
$settingsPath = Join-Path $installDirectory 'settings.json'
$codexDirectory = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$configPath = Join-Path $codexDirectory 'config.toml'
$original = if (Test-Path -LiteralPath $configPath) { [IO.File]::ReadAllText($configPath) } else { '' }
if (Test-Path -LiteralPath $settingsPath) {
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    if ($settings.Port -ne $Port) { throw 'Existing installation uses a different port. Uninstall it before changing ports.' }
} else { $settings = @{Port=$Port; Route=[Guid]::NewGuid().ToString('N')} }
if ($settings.Route -notmatch '^[a-fA-F0-9]{32,}$') { throw 'Invalid existing route in settings.json.' }
$baseUrl = 'http://127.0.0.1:' + $Port + '/' + $settings.Route + '/backend-api/codex'
# Validate ownership before changing the running service or files.
$updated = Set-GuardianConfig -Text $original -BaseUrl $baseUrl
& (Join-Path $PSScriptRoot 'build.ps1')
New-Item -ItemType Directory -Path $installDirectory,$codexDirectory -Force | Out-Null
$backupDirectory = Join-Path $installDirectory 'backups'
New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
if (Test-Path -LiteralPath $configPath) {
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $backupDirectory ('config-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.toml'))
}
$previousTask = Get-ScheduledTask -TaskName 'CodexProxyGuardian' -ErrorAction SilentlyContinue
if ($previousTask) { Stop-ScheduledTask -TaskName 'CodexProxyGuardian' }
Get-Process CodexProxyGuardian -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $executable } | Stop-Process
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'build\CodexProxyGuardian.exe') -Destination $executable -Force
$settings | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute $executable -WorkingDirectory $installDirectory
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$options = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'CodexProxyGuardian' -Action $action -Trigger $trigger -Principal $principal -Settings $options -Description 'Codex model requests through the current Windows system proxy.' -Force | Out-Null
Start-ScheduledTask -TaskName 'CodexProxyGuardian'
$ready = $false
for ($i=0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 200
    $process = Get-Process CodexProxyGuardian -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $executable }
    $listener = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($process -and $listener -and $listener.OwningProcess -in $process.Id) { $ready=$true; break }
}
if (-not $ready) { throw 'Guardian did not start. Codex configuration was not changed; inspect guardian.log.' }
$latest = if (Test-Path -LiteralPath $configPath) { [IO.File]::ReadAllText($configPath) } else { '' }
if ($latest -ne $original) { throw 'Codex configuration changed during installation. Run the installer again.' }
[IO.File]::WriteAllText($configPath, $updated, (New-Object Text.UTF8Encoding($false)))
Write-Output 'Installed. Fully quit and reopen Codex once; use your normal Codex icon afterward.'
