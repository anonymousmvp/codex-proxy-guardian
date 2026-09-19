# Optional Windows integration check. Creates and removes an isolated scheduled task
# and a temporary local certificate; the certificate is never trusted in a root store.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $project 'scripts\Certificate.psm1') -Force
$testId = [Guid]::NewGuid().ToString('N')
$testRoot = Join-Path $project ('build\install-check-' + $testId)
$payloadDirectory = Join-Path $testRoot 'payload'
$installDirectory = Join-Path $testRoot 'installed'
$configDirectory = Join-Path $testRoot 'codex-config'
$taskName = 'CodexProxyGuardian-Test-' + $testId
$setupExe = Join-Path $project 'build\CodexProxyGuardian-Setup.exe'
$exe = Join-Path $installDirectory 'CodexProxyGuardian.exe'
$existingProcesses = @(Get-Process CodexProxyGuardian -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$proxyBefore = @{}
foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY')) { $proxyBefore[$name]=[Environment]::GetEnvironmentVariable($name,'User') }
$liveConfigDirectory = if($env:CODEX_HOME) {$env:CODEX_HOME} else {Join-Path $env:USERPROFILE '.codex'}
$liveConfig = Join-Path $liveConfigDirectory 'config.toml'
$liveHash = if(Test-Path -LiteralPath $liveConfig) {(Get-FileHash -LiteralPath $liveConfig).Hash} else {$null}
$liveSettings = Join-Path $env:LOCALAPPDATA 'OpenAI\CodexProxyGuardian\settings.json'
$liveSettingsHash = if(Test-Path -LiteralPath $liveSettings) {(Get-FileHash -LiteralPath $liveSettings).Hash} else {$null}
$probe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
$probe.Start(); $port=$probe.LocalEndpoint.Port; $probe.Stop()
New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
$original = "model = `"keep-existing-model`"`r`n[desktop]`r`nname = `"keep-settings`"`r`n"
$configPath = Join-Path $configDirectory 'config.toml'
[IO.File]::WriteAllText($configPath,$original,(New-Object Text.UTF8Encoding($false)))
$setup = Start-Process -FilePath $setupExe -ArgumentList @('--verify-package',('"'+$payloadDirectory+'"')) -WindowStyle Hidden -Wait -PassThru
if($setup.ExitCode -ne 0) {throw 'Package extraction failed.'}
$scriptArguments = @('-InstallDirectory',$installDirectory,'-CodexConfigDirectory',$configDirectory,'-ScheduledTaskName',$taskName)
$thumbprint = $null
function Assert-Installed([string]$Label) {
    $settings = Get-Content -LiteralPath (Join-Path $installDirectory 'settings.json') -Raw | ConvertFrom-Json
    if($settings.CodexConfigDirectory -ne [IO.Path]::GetFullPath($configDirectory)) {throw "$Label`: MCP credentials do not use the isolated Codex directory."}
    if($settings.CertificateThumbprint -notmatch '^[0-9A-F]{40}$') {throw "$Label`: settings.json has no certificate thumbprint."}
    $certificate = Get-GuardianCertificate -Thumbprint $settings.CertificateThumbprint
    if(-not $certificate) {throw "$Label`: the local certificate with its private key is missing."}
    if(Test-GuardianCertificateTrusted -Thumbprint $settings.CertificateThumbprint) {throw "$Label`: the check certificate must not be trusted."}
    $content = [IO.File]::ReadAllText($configPath)
    $expected = 'https://127.0.0.1:' + $port + '/' + $settings.Route + '/backend-api'
    if(-not $content.Contains('openai_base_url = "' + $expected + '/codex"') -or -not $content.Contains('chatgpt_base_url = "' + $expected + '"')) {throw "$Label`: configuration does not point at the HTTPS listener."}
    if($content.Contains('http://') -or -not $content.Contains('keep-existing-model') -or -not $content.Contains('keep-settings')) {throw "$Label`: installation damaged configuration."}
    if((Get-ScheduledTask -TaskName $taskName).State -ne 'Running') {throw "$Label`: test scheduled task is not running."}
    if(-not ((Get-Content -LiteralPath (Join-Path $installDirectory 'guardian.log') -Raw) -match ('started 127\.0\.0\.1:' + $port + ' tls=True'))) {throw "$Label`: the installed guardian is not serving TLS."}
    return $settings
}
try {
    $route = $null
    foreach($pass in 1..2) {
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File (Join-Path $payloadDirectory 'install.ps1') -PrebuiltExecutable (Join-Path $payloadDirectory 'Guardian.exe') -Port $port -SkipCertificateTrust @scriptArguments
        if($LASTEXITCODE -ne 0) {throw "Installation pass $pass failed."}
        $settings = Assert-Installed "Pass $pass"
        if($route -and $route -ne $settings.Route) {throw 'Reinstall changed the private route.'}
        if($thumbprint -and $thumbprint -ne $settings.CertificateThumbprint) {throw 'Reinstall replaced a valid certificate.'}
        $route = $settings.Route
        $thumbprint = $settings.CertificateThumbprint
    }
    # A plain-HTTP installation from an earlier version is migrated in place.
    $legacy = "# BEGIN CodexProxyGuardian`r`nopenai_base_url = `"http://127.0.0.1:$port/$route/backend-api/codex`"`r`nchatgpt_base_url = `"http://127.0.0.1:$port/$route/backend-api`"`r`n# END CodexProxyGuardian`r`n" + $original
    [IO.File]::WriteAllText($configPath,$legacy,(New-Object Text.UTF8Encoding($false)))
    $setup = Start-Process -FilePath $setupExe -ArgumentList (@('--install','--skip-certificate','--','-Port',$port) + $scriptArguments) -WindowStyle Hidden -Wait -PassThru
    if($setup.ExitCode -ne 0) {throw 'Installer EXE upgrade pass failed.'}
    $settings = Assert-Installed 'Installer EXE upgrade'
    if($settings.Route -ne $route -or $settings.CertificateThumbprint -ne $thumbprint) {throw 'Installer EXE upgrade replaced the route or certificate.'}
    foreach($file in @('uninstall.ps1','scripts\Config.psm1','scripts\Certificate.psm1')) {
        if(-not (Test-Path -LiteralPath (Join-Path $installDirectory $file))) {throw "Installer EXE did not keep $file for later removal."}
    }
    $setup = Start-Process -FilePath $setupExe -ArgumentList (@('--uninstall','--skip-certificate','--') + $scriptArguments) -WindowStyle Hidden -Wait -PassThru
    if($setup.ExitCode -ne 0) {throw 'Installer EXE uninstall failed.'}
    if([IO.File]::ReadAllText($configPath) -cne $original) {throw 'Uninstall did not restore the original configuration.'}
    if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {throw 'Uninstall left its task registered.'}
    $leftovers = @(Get-ChildItem -LiteralPath $installDirectory -Force | Where-Object { $_.Name -notin @('backups','setup.log') })
    if($leftovers.Count -ne 0) {throw ('Uninstall left program files: ' + (($leftovers | Select-Object -ExpandProperty Name) -join ', '))}
    if(-not (Test-Path -LiteralPath (Join-Path $installDirectory 'backups'))) {throw 'Uninstall removed the configuration backups.'}
    if(-not (Get-GuardianCertificate -Thumbprint $thumbprint)) {throw 'The --skip-certificate uninstall must leave the certificate for the caller to remove.'}
    $removed = Remove-GuardianCertificate -Thumbprint $thumbprint
    if(($removed -join ',') -ne 'My' -or (Get-GuardianCertificate -Thumbprint $thumbprint)) {throw 'The check certificate was not removed from the personal store.'}
    $thumbprint = $null
} finally {
    if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $taskName
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    Get-Process CodexProxyGuardian -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $exe} | ForEach-Object {$_.Kill();$_.WaitForExit()}
    if($thumbprint) { try { Remove-GuardianCertificate -Thumbprint $thumbprint | Out-Null } catch { Write-Warning "Check certificate $thumbprint was not removed: $($_.Exception.Message)" } }
}
foreach($name in $proxyBefore.Keys) {if([Environment]::GetEnvironmentVariable($name,'User') -cne $proxyBefore[$name]) {throw 'User proxy environment changed.'}}
if($liveHash -and (Get-FileHash -LiteralPath $liveConfig).Hash -ne $liveHash) {throw 'Live Codex config changed during the check.'}
if($liveSettingsHash -and (Get-FileHash -LiteralPath $liveSettings).Hash -ne $liveSettingsHash) {throw 'Live guardian settings changed during the check.'}
foreach($processId in $existingProcesses) {if(-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {throw 'An existing guardian process stopped.'}}
Write-Output 'Installation, repeat installation, plain-http migration through the installer EXE, scheduled autostart, TLS listener, uninstallation via the installer EXE and isolation checks all passed.'
