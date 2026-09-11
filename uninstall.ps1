[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\Config.psm1') -Force
$installDirectory = Join-Path $env:LOCALAPPDATA 'OpenAI\CodexProxyGuardian'
$settingsPath = Join-Path $installDirectory 'settings.json'
if (-not (Test-Path -LiteralPath $settingsPath)) { throw 'Guardian settings were not found; nothing was changed.' }
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
$baseUrl = 'http://127.0.0.1:' + $settings.Port + '/' + $settings.Route + '/backend-api/codex'
$codexDirectory = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$configPath = Join-Path $codexDirectory 'config.toml'
if (Test-Path -LiteralPath $configPath) {
    $original = [IO.File]::ReadAllText($configPath)
    $updated = Remove-GuardianConfig -Text $original -BaseUrl $baseUrl
    if ([IO.File]::ReadAllText($configPath) -ne $original) { throw 'Config changed concurrently. Run uninstall again.' }
    [IO.File]::WriteAllText($configPath,$updated,(New-Object Text.UTF8Encoding($false)))
}
if (Get-ScheduledTask -TaskName 'CodexProxyGuardian' -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName 'CodexProxyGuardian'
    Unregister-ScheduledTask -TaskName 'CodexProxyGuardian' -Confirm:$false
}
$executable = Join-Path $installDirectory 'CodexProxyGuardian.exe'
Get-Process CodexProxyGuardian -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $executable } | Stop-Process
Write-Output 'Disabled and removed the owned Codex override. Installation files and backups were preserved. Restart Codex.'
