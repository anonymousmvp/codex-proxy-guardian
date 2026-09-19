[CmdletBinding()]
param(
    [ValidateRange(1024,65535)][int]$Port = 43871,
    [string]$PrebuiltExecutable,
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'OpenAI\CodexProxyGuardian'),
    [string]$CodexConfigDirectory,
    [string]$ScheduledTaskName = 'CodexProxyGuardian',
    # The installer EXE and the automated checks add the root-store trust themselves.
    [switch]$SkipCertificateTrust
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'scripts\Certificate.psm1') -Force
$executable = Join-Path $installDirectory 'CodexProxyGuardian.exe'
$settingsPath = Join-Path $installDirectory 'settings.json'
$codexDirectory = if ($CodexConfigDirectory) { $CodexConfigDirectory } elseif ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$codexDirectory = [IO.Path]::GetFullPath($codexDirectory)
$configPath = Join-Path $codexDirectory 'config.toml'
$original = if (Test-Path -LiteralPath $configPath) { [IO.File]::ReadAllText($configPath) } else { '' }
$settings = @{}
if (Test-Path -LiteralPath $settingsPath) {
    $existing = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    foreach ($property in $existing.PSObject.Properties) { $settings[$property.Name] = $property.Value }
    if ($settings.Port -ne $Port) { throw 'Existing installation uses a different port. Uninstall it before changing ports.' }
} else { $settings = @{Port=$Port; Route=[Guid]::NewGuid().ToString('N')} }
if ($settings.Route -notmatch '^[a-fA-F0-9]{32,}$') { throw 'Invalid existing route in settings.json.' }
$baseUrl = 'https://127.0.0.1:' + $Port + '/' + $settings.Route + '/backend-api/codex'
# Validate ownership before changing the running service or files.
$updated = Set-GuardianConfig -Text $original -BaseUrl $baseUrl
# The scheduled task may not inherit the installing shell's CODEX_HOME.
# Persist only the directory, never a token or a copy of auth.json.
$settings.CodexConfigDirectory = $codexDirectory
if ($PrebuiltExecutable) {
    if (-not (Test-Path -LiteralPath $PrebuiltExecutable -PathType Leaf)) { throw 'Embedded guardian executable is missing.' }
    $builtExecutable = (Resolve-Path -LiteralPath $PrebuiltExecutable).Path
} else {
    & (Join-Path $PSScriptRoot 'build.ps1')
    $builtExecutable = Join-Path $PSScriptRoot 'build\CodexProxyGuardian.exe'
}
# Reuse the existing local certificate; create a new one only when it is missing or near expiry.
$previousThumbprint = if ($settings.ContainsKey('CertificateThumbprint')) { [string]$settings.CertificateThumbprint } else { '' }
$certificate = Get-GuardianCertificate -Thumbprint $previousThumbprint
if (-not (Test-GuardianCertificateCurrent -Certificate $certificate)) {
    $certificate = New-GuardianCertificate
    if ($previousThumbprint -and $previousThumbprint -ne $certificate.Thumbprint) {
        try { Remove-GuardianCertificate -Thumbprint $previousThumbprint | Out-Null } catch { Write-Warning "Previous certificate $previousThumbprint was not removed: $($_.Exception.Message)" }
    }
}
$settings.CertificateThumbprint = $certificate.Thumbprint
if (-not $SkipCertificateTrust) {
    try { Add-GuardianCertificateTrust -Certificate $certificate }
    catch { throw "The local certificate must be trusted for Codex to connect. Windows asked for confirmation and it was not granted: $($_.Exception.Message)" }
}
New-Item -ItemType Directory -Path $installDirectory,$codexDirectory -Force | Out-Null
$backupDirectory = Join-Path $installDirectory 'backups'
New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
if (Test-Path -LiteralPath $configPath) {
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $backupDirectory ('config-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.toml'))
}
$previousTask = Get-ScheduledTask -TaskName $ScheduledTaskName -ErrorAction SilentlyContinue
if ($previousTask) { Stop-ScheduledTask -TaskName $ScheduledTaskName }
Get-Process CodexProxyGuardian -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $executable } | ForEach-Object { $_.Kill(); $_.WaitForExit() }
Copy-Item -LiteralPath $builtExecutable -Destination $executable -Force
$settings | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute $executable -WorkingDirectory $installDirectory
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$options = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $ScheduledTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $options -Description 'Codex model and remote-control requests through the current Windows system proxy.' -Force | Out-Null
Start-ScheduledTask -TaskName $ScheduledTaskName
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
