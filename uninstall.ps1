[CmdletBinding()]
param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'OpenAI\CodexProxyGuardian'),
    [string]$CodexConfigDirectory,
    [string]$ScheduledTaskName = 'CodexProxyGuardian',
    # The installer EXE removes the certificate itself after this script succeeds.
    [switch]$SkipCertificateRemoval,
    # Delete the program files and logs; configuration backups are always kept.
    [switch]$RemoveFiles
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'scripts\Certificate.psm1') -Force
$settingsPath = Join-Path $installDirectory 'settings.json'
if (-not (Test-Path -LiteralPath $settingsPath)) { throw 'Guardian settings were not found; nothing was changed.' }
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
# Remove-GuardianConfig also removes the http:// entries written by earlier versions.
$baseUrl = 'https://127.0.0.1:' + $settings.Port + '/' + $settings.Route + '/backend-api/codex'
$codexDirectory = if ($CodexConfigDirectory) { $CodexConfigDirectory } elseif ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$configPath = Join-Path $codexDirectory 'config.toml'
if (Test-Path -LiteralPath $configPath) {
    $original = [IO.File]::ReadAllText($configPath)
    $updated = Remove-GuardianConfig -Text $original -BaseUrl $baseUrl
    if ([IO.File]::ReadAllText($configPath) -ne $original) { throw 'Config changed concurrently. Run uninstall again.' }
    [IO.File]::WriteAllText($configPath,$updated,(New-Object Text.UTF8Encoding($false)))
}
if (Get-ScheduledTask -TaskName $ScheduledTaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $ScheduledTaskName
    Unregister-ScheduledTask -TaskName $ScheduledTaskName -Confirm:$false
}
$executable = Join-Path $installDirectory 'CodexProxyGuardian.exe'
Get-Process CodexProxyGuardian -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $executable } | ForEach-Object { $_.Kill(); $_.WaitForExit() }
$thumbprint = if ($settings.PSObject.Properties['CertificateThumbprint']) { [string]$settings.CertificateThumbprint } else { '' }
if (-not $SkipCertificateRemoval -and $thumbprint) {
    $removed = Remove-GuardianCertificate -Thumbprint $thumbprint
    if ($removed.Count -gt 0) { Write-Output ('Removed the local certificate from: ' + ($removed -join ', ')) }
}
if ($RemoveFiles) {
    Get-ChildItem -LiteralPath $installDirectory -Force | Where-Object { $_.Name -ne 'backups' } | Remove-Item -Recurse -Force
    Write-Output 'Removed the Codex override, autostart task, process and program files. Configuration backups were kept. Restart Codex.'
} else {
    Write-Output 'Disabled and removed the owned Codex override. Installation files and backups were preserved. Restart Codex.'
}
