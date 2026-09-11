[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $project 'scripts\Config.psm1') -Force
function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
}
$base = 'http://127.0.0.1:43871/0123456789abcdef0123456789abcdef/backend-api/codex'
foreach ($newline in @("`r`n","`n")) {
    $original = 'notify = []' + $newline + '[desktop]' + $newline + 'name = "keep"' + $newline
    $once = Set-GuardianConfig -Text $original -BaseUrl $base
    Assert-True ((Get-TopLevelProxyUrl $once) -eq $base) 'Could not read configured URL.'
    Assert-True ((Get-TopLevelProxyUrl -Text $once -Key chatgpt_base_url) -eq $base.Substring(0,$base.Length-6)) 'Remote control URL was not configured.'
    Assert-True ((Set-GuardianConfig -Text $once -BaseUrl $base) -ceq $once) 'Installation is not idempotent.'
    Assert-True ((Remove-GuardianConfig -Text $once -BaseUrl $base) -ceq $original) 'Uninstall changed unrelated configuration.'
}
$external = 'openai_base_url = "https://example.com/v1"' + "`r`n[desktop]`r`n"
$rejected = $false
try { Set-GuardianConfig -Text $external -BaseUrl $base | Out-Null } catch { $rejected=$true }
Assert-True $rejected 'Installer must preserve a different existing provider.'
Assert-True ((Remove-GuardianConfig -Text $external -BaseUrl $base) -ceq $external) 'Uninstaller removed a foreign provider.'
$externalRemote = 'chatgpt_base_url = "https://example.com/backend-api"' + "`r`n"
$rejected = $false
try { Set-GuardianConfig -Text $externalRemote -BaseUrl $base | Out-Null } catch { $rejected=$true }
Assert-True $rejected 'Installer must preserve a foreign remote-control backend.'
Assert-True ((Remove-GuardianConfig -Text $externalRemote -BaseUrl $base) -ceq $externalRemote) 'Uninstaller removed a foreign remote backend.'
$legacy = '# Codex-only proxy guardian; reads the current Windows system proxy on each connection.' + "`r`nopenai_base_url = `"$base`"`r`nnotify = []`r`n"
$migrated = Set-GuardianConfig -Text $legacy -BaseUrl $base
Assert-True (-not $migrated.Contains('reads the current')) 'Legacy config comment was not migrated.'
Write-Output 'Configuration checks passed: CRLF/LF, idempotence, round-trip, existing-provider protection, migration.'

$assembly = [Reflection.Assembly]::LoadFile((Join-Path $project 'build\CodexProxyGuardian.exe'))
$routing = $assembly.GetType('CodexProxyGuardian').GetMethod('GetUpstreamPath',[Reflection.BindingFlags]'NonPublic,Static')
$testRoute = '0123456789abcdef0123456789abcdef'
foreach($path in @('/backend-api/codex/responses','/backend-api/wham/remote/control/server','/backend-api/wham/remote/control/server/enroll','/backend-api/wham/remote/control/server/refresh','/backend-api/wham/remote/control/server/pair','/backend-api/wham/remote/control/client/list')) {
    Assert-True ($routing.Invoke($null,[object[]]@("/$testRoute$path",$testRoute)) -eq $path) "Routing failed for $path"
}
Assert-True ($null -eq $routing.Invoke($null,[object[]]@("/$testRoute/unrelated",$testRoute))) 'Non-backend route was accepted.'
Write-Output 'Remote-control route checks passed.'

$checkDirectory = Join-Path $project ('build\check-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $checkDirectory | Out-Null
$exe = Join-Path $checkDirectory 'CodexProxyGuardian.exe'
Copy-Item -LiteralPath (Join-Path $project 'build\CodexProxyGuardian.exe') -Destination $exe
$probe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
$probe.Start()
$port = $probe.LocalEndpoint.Port
$probe.Stop()
$route = [Guid]::NewGuid().ToString('N')
@{Port=$port;Route=$route} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $checkDirectory 'settings.json') -Encoding UTF8
function Request-Status([string]$Raw) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1',$port)
        $client.ReceiveTimeout = 5000
        $stream = $client.GetStream()
        $bytes = [Text.Encoding]::ASCII.GetBytes($Raw)
        $stream.Write($bytes,0,$bytes.Length)
        $reader = New-Object IO.StreamReader($stream,[Text.Encoding]::ASCII)
        return $reader.ReadLine().Split(' ')[1]
    } finally { $client.Close() }
}
$process = Start-Process -FilePath $exe -WindowStyle Hidden -PassThru
try {
    $statusFile = Join-Path $checkDirectory 'status.json'
    for($i=0; $i -lt 50 -and -not (Test-Path -LiteralPath $statusFile); $i++) { Start-Sleep -Milliseconds 100 }
    Assert-True (Test-Path -LiteralPath $statusFile) 'Test listener failed to start.'
    Assert-True ((Request-Status "GET /backend-api/codex/models HTTP/1.1`r`nHost: localhost`r`n`r`n") -eq '404') 'Requests without private route must be rejected.'
    Assert-True ((Request-Status "GET /$route/backend-api/codex/models HTTP/1.1`r`nHost: localhost`r`nOrigin: https://example.com`r`n`r`n") -eq '403') 'Browser-origin request must be rejected.'
    Assert-True ((Request-Status "GET /$route/backend-api/wham/remote/control/server HTTP/1.1`r`nHost: localhost`r`nOrigin: https://example.com`r`n`r`n") -eq '403') 'Remote-control browser-origin request must be rejected.'
    Assert-True ((Request-Status "GET / HTTP/1.0`r`n`r`n") -eq '400') 'Unsupported HTTP version must be rejected.'
    $state = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json
    Assert-True ($state.requests -eq 0) 'Rejected requests reached upstream routing.'
    Write-Output 'Listener checks passed: private route, browser-origin rejection, protocol validation, no upstream requests.'
} finally {
    if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
}
Write-Output 'All checks passed. Test artifacts remain under build/ (gitignored).'
