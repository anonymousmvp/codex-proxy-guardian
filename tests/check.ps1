[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $project 'scripts\Config.psm1') -Force
function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
}
$base = 'https://127.0.0.1:43871/0123456789abcdef0123456789abcdef/backend-api/codex'
$legacyBase = 'http://127.0.0.1:43871/0123456789abcdef0123456789abcdef/backend-api/codex'
Assert-True (((Get-OwnedUrlVariants -BaseUrl $base) -join ' ') -eq "$base $legacyBase") 'Owned URL variants must include the legacy http entry.'
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
$legacy = '# Codex-only proxy guardian; reads the current Windows system proxy on each connection.' + "`r`nopenai_base_url = `"$legacyBase`"`r`nnotify = []`r`n"
$migrated = Set-GuardianConfig -Text $legacy -BaseUrl $base
Assert-True (-not $migrated.Contains('reads the current')) 'Legacy config comment was not migrated.'
Assert-True (-not $migrated.Contains($legacyBase) -and (Get-TopLevelProxyUrl $migrated) -eq $base) 'Legacy single http entry was not migrated to https.'
$plainHttp = "# BEGIN CodexProxyGuardian`r`nopenai_base_url = `"$legacyBase`"`r`nchatgpt_base_url = `"$($legacyBase.Substring(0,$legacyBase.Length-6))`"`r`n# END CodexProxyGuardian`r`nnotify = []`r`n[desktop]`r`nname = `"keep`"`r`n"
$upgraded = Set-GuardianConfig -Text $plainHttp -BaseUrl $base
Assert-True (-not $upgraded.Contains('http://') -and (Get-TopLevelProxyUrl $upgraded) -eq $base -and (Get-TopLevelProxyUrl -Text $upgraded -Key chatgpt_base_url) -eq $base.Substring(0,$base.Length-6)) 'Plain-HTTP installation was not migrated to https.'
Assert-True ($upgraded.Contains('name = "keep"') -and $upgraded.Contains('notify = []')) 'Migration changed unrelated configuration.'
Assert-True ((Remove-GuardianConfig -Text $plainHttp -BaseUrl $base) -ceq "notify = []`r`n[desktop]`r`nname = `"keep`"`r`n") 'Uninstall did not remove the legacy http entries.'
$otherRoute = 'http://127.0.0.1:43871/ffffffffffffffffffffffffffffffff/backend-api/codex'
$rejected = $false
try { Set-GuardianConfig -Text ('openai_base_url = "' + $otherRoute + '"' + "`r`n") -BaseUrl $base | Out-Null } catch { $rejected=$true }
Assert-True $rejected 'A legacy entry with a different route must not be treated as owned.'
Write-Output 'Configuration checks passed: CRLF/LF, idempotence, round-trip, existing-provider protection, https migration of plain-http installations.'

$assembly = [Reflection.Assembly]::LoadFile((Join-Path $project 'build\CodexProxyGuardian.exe'))
$routing = $assembly.GetType('CodexProxyGuardian').GetMethods([Reflection.BindingFlags]'NonPublic,Static') | Where-Object { $_.Name -eq 'GetUpstreamPath' -and $_.GetParameters().Count -eq 2 }
$testRoute = '0123456789abcdef0123456789abcdef'
foreach($path in @('/backend-api/codex/responses','/backend-api/wham/remote/control/server','/backend-api/wham/remote/control/server/enroll','/backend-api/wham/remote/control/server/refresh','/backend-api/wham/remote/control/server/pair','/backend-api/wham/remote/control/client/list','/backend-api/ps/mcp','/backend-api/ps/mcp?client=codex')) {
    Assert-True ($routing.Invoke($null,[object[]]@("/$testRoute$path",$testRoute)) -eq $path) "Routing failed for $path"
}
Assert-True ($null -eq $routing.Invoke($null,[object[]]@("/$testRoute/unrelated",$testRoute))) 'Non-backend route was accepted.'
Assert-True ($null -eq $routing.Invoke($null,[object[]]@('/backend-api/codex/models',$testRoute))) 'The routed-only lookup accepted a desktop request.'
$routingWithFlag = $assembly.GetType('CodexProxyGuardian').GetMethods([Reflection.BindingFlags]'NonPublic,Static') | Where-Object { $_.Name -eq 'GetUpstreamPath' -and $_.GetParameters().Count -eq 3 }
foreach($case in @(@{Target="/$testRoute/backend-api/codex/responses";Path='/backend-api/codex/responses';Routed=$true},@{Target='/backend-api/wham/usage';Path='/backend-api/wham/usage';Routed=$false},@{Target='/backend-api/codex/responses?x=1';Path='/backend-api/codex/responses?x=1';Routed=$false})) {
    $arguments = [object[]]@($case.Target,$testRoute,$false)
    Assert-True (($routingWithFlag.Invoke($null,$arguments)) -eq $case.Path -and $arguments[2] -eq $case.Routed) "Desktop routing failed for $($case.Target)"
}
foreach($target in @('/backend-api','/backend-apix/codex','/unrelated','/','/other/backend-api/codex/responses')) {
    $arguments = [object[]]@($target,$testRoute,$false)
    Assert-True ($null -eq $routingWithFlag.Invoke($null,$arguments)) "Unrelated target was accepted: $target"
}
Write-Output 'Remote-control and desktop route checks passed.'

Add-Type -Path (Join-Path $PSScriptRoot 'HeaderTransportChecks.cs')
[GuardianTransportChecks]::Run($assembly)
Write-Output 'Header transport checks passed: real 21-second response, original 20-second failure, total deadlines, fragmented HTTP/chunked/WebSocket bytes, 64 KiB limits.'

$checkDirectory = Join-Path $project ('build\check-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $checkDirectory | Out-Null
$authDirectory = Join-Path $checkDirectory 'synthetic-codex'
New-Item -ItemType Directory -Path $authDirectory | Out-Null
$authFile = Join-Path $authDirectory 'auth.json'
$guardian = $assembly.GetType('CodexProxyGuardian')
$privateStatic = [Reflection.BindingFlags]'NonPublic,Static'
$isMcp = $guardian.GetMethod('IsAppsMcpPath',$privateStatic)
$addMcpAuthorization = $guardian.GetMethod('AddAppsMcpAuthorization',$privateStatic)
$settingsField = $guardian.GetField('Settings',$privateStatic)
$originalSettings = $settingsField.GetValue($null)
$testSettings = [Activator]::CreateInstance($assembly.GetType('GuardianSettings'))
$testSettings.CodexConfigDirectory = $authDirectory

function New-TestHeaders {
    # Preserve the generic list as one object even when it is empty.
    return ,(New-Object 'System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,string]]')
}
function Add-TestHeader($Headers,[string]$Name,[string]$Value) {
    $Headers.Add([Collections.Generic.KeyValuePair[string,string]]::new($Name,$Value))
}
function Invoke-McpAuthorization([string]$Path,$Headers) {
    # Windows PowerShell wraps the generic list returned by New-Object in PSObject;
    # reflection requires its underlying List<KeyValuePair<string,string>> instance.
    $addMcpAuthorization.Invoke($null,[object[]]@($Path,$Headers.PSObject.BaseObject)) | Out-Null
}
function Write-TestAuth($Auth) {
    $Auth | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $authFile -Encoding UTF8
}
function Assert-McpUnauthorized($Headers,[string]$Message) {
    $rejected = $false
    try { Invoke-McpAuthorization '/backend-api/ps/mcp' $Headers } catch {
        if ($_.Exception.GetBaseException() -is [UnauthorizedAccessException]) { $rejected = $true } else { throw }
    }
    Assert-True $rejected $Message
    Assert-True (@($Headers | Where-Object { $_.Key -ieq 'Authorization' }).Count -eq 0) 'Rejected authentication added an Authorization header.'
}

try {
    # Every auth read below is explicitly redirected to this isolated fixture directory.
    $settingsField.SetValue($null,$testSettings)
    foreach($path in @('/backend-api/ps/mcp','/backend-api/ps/mcp?client=codex','/backend-api/ps/mcp?')) {
        Assert-True ($isMcp.Invoke($null,[object[]]@($path))) "Apps MCP path was not recognized: $path"
    }
    foreach($path in @('/backend-api/codex/responses','/backend-api/wham/remote/control/server','/backend-api/ps/mcp/','/backend-api/ps/mcp/tools','/backend-api/ps/mcp-other','/backend-api/ps/mcpx','/backend-api/PS/mcp','/backend-api/ps/mcp#fragment')) {
        Assert-True (-not $isMcp.Invoke($null,[object[]]@($path))) "Unrelated path was recognized as Apps MCP: $path"
        $headers = New-TestHeaders
        Add-TestHeader $headers 'X-Test' 'preserve'
        Invoke-McpAuthorization $path $headers
        Assert-True ($headers.Count -eq 1 -and $headers[0].Value -ceq 'preserve') 'Unrelated route authentication was changed.'
    }

    # A missing fixture must not be read when callers already supplied authentication.
    foreach($authorization in @('Bearer caller-token','Bearer second-caller-token')) {
        $headers = New-TestHeaders
        Add-TestHeader $headers 'authorization' $authorization
        Add-TestHeader $headers 'chatgpt-account-id' 'caller-account'
        Invoke-McpAuthorization '/backend-api/ps/mcp' $headers
        Assert-True ($headers.Count -eq 2 -and $headers[0].Value -ceq $authorization -and $headers[1].Value -ceq 'caller-account') 'Caller authentication must be preserved verbatim.'
    }
    Assert-McpUnauthorized (New-TestHeaders) 'Missing auth.json must fail closed.'
    '{malformed-json' | Set-Content -LiteralPath $authFile -Encoding UTF8
    Assert-McpUnauthorized (New-TestHeaders) 'Malformed auth.json must fail closed.'

    $invalidAuth = @(
        @{Label='empty document'; Auth=@{}},
        @{Label='missing login mode'; Auth=@{tokens=@{access_token='fixture-token';account_id='fixture-account'}}},
        @{Label='API key login'; Auth=@{auth_mode='apikey';OPENAI_API_KEY='fixture-key';tokens=@{access_token='fixture-token';account_id='fixture-account'}}},
        @{Label='missing tokens'; Auth=@{auth_mode='chatgpt'}},
        @{Label='missing access token'; Auth=@{auth_mode='chatgpt';tokens=@{account_id='fixture-account'}}},
        @{Label='missing account ID'; Auth=@{auth_mode='chatgpt';tokens=@{access_token='fixture-token'}}},
        @{Label='empty access token'; Auth=@{auth_mode='chatgpt';tokens=@{access_token='';account_id='fixture-account'}}},
        @{Label='empty account ID'; Auth=@{auth_mode='chatgpt';tokens=@{access_token='fixture-token';account_id=''}}},
        @{Label='blank access token'; Auth=@{auth_mode='chatgpt';tokens=@{access_token='   ';account_id='fixture-account'}}},
        @{Label='blank account ID'; Auth=@{auth_mode='chatgpt';tokens=@{access_token='fixture-token';account_id='   '}}},
        @{Label='access token CRLF'; Auth=@{auth_mode='chatgpt';tokens=@{access_token="fixture-token`r`nX-Injected: bad";account_id='fixture-account'}}},
        @{Label='account ID CRLF'; Auth=@{auth_mode='chatgpt';tokens=@{access_token='fixture-token';account_id="fixture-account`r`nX-Injected: bad"}}}
    )
    foreach($fixture in $invalidAuth) {
        Write-TestAuth $fixture.Auth
        Assert-McpUnauthorized (New-TestHeaders) "Invalid authentication must fail closed: $($fixture.Label)"
    }

    Write-TestAuth @{auth_mode='chatgpt';tokens=@{access_token='fixture-token-one';account_id='fixture-account'}}
    foreach($path in @('/backend-api/ps/mcp','/backend-api/ps/mcp?client=codex')) {
        $headers = New-TestHeaders
        Add-TestHeader $headers 'X-Test' 'preserve'
        Invoke-McpAuthorization $path $headers
        $authorization = @($headers | Where-Object { $_.Key -ieq 'Authorization' })
        $account = @($headers | Where-Object { $_.Key -ieq 'ChatGPT-Account-ID' })
        Assert-True ($headers.Count -eq 3 -and $headers[0].Value -ceq 'preserve') 'MCP authentication changed unrelated headers.'
        Assert-True ($authorization.Count -eq 1 -and $authorization[0].Value -ceq 'Bearer fixture-token-one') 'MCP bearer authentication was not added exactly once.'
        Assert-True ($account.Count -eq 1 -and $account[0].Value -ceq 'fixture-account') 'MCP account ID was not added exactly once.'
    }
    $headers = New-TestHeaders
    Add-TestHeader $headers 'chatgpt-account-id' 'fixture-account'
    Invoke-McpAuthorization '/backend-api/ps/mcp' $headers
    Assert-True ($headers.Count -eq 2 -and @($headers | Where-Object { $_.Key -ieq 'ChatGPT-Account-ID' }).Count -eq 1) 'Matching caller account ID must not be duplicated.'

    $headers = New-TestHeaders
    Add-TestHeader $headers 'ChatGPT-Account-ID' 'other-account'
    Assert-McpUnauthorized $headers 'Mismatched caller account ID must fail closed.'
    Assert-True ($headers.Count -eq 1 -and $headers[0].Value -ceq 'other-account') 'Mismatched caller account ID was overwritten.'

    $headers = New-TestHeaders
    Add-TestHeader $headers 'ChatGPT-Account-ID' 'fixture-account'
    Add-TestHeader $headers 'chatgpt-account-id' 'fixture-account'
    Assert-McpUnauthorized $headers 'Duplicate caller account IDs must fail closed.'
    Assert-True ($headers.Count -eq 2) 'Duplicate caller account IDs were silently rewritten.'

    Write-TestAuth @{auth_mode='chatgpt';tokens=@{access_token='fixture-token-two';account_id='fixture-account'}}
    $headers = New-TestHeaders
    Invoke-McpAuthorization '/backend-api/ps/mcp' $headers
    Assert-True (@($headers | Where-Object { $_.Key -ieq 'Authorization' })[0].Value -ceq 'Bearer fixture-token-two') 'MCP authentication reused a stale cached token.'
    Write-Output 'Apps MCP authentication checks passed: exact paths, caller-header preservation, isolated login fixtures, invalid credentials, account matching, token refresh.'
} finally {
    $settingsField.SetValue($null,$originalSettings)
}

$exe = Join-Path $checkDirectory 'CodexProxyGuardian.exe'
Copy-Item -LiteralPath (Join-Path $project 'build\CodexProxyGuardian.exe') -Destination $exe
$probe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
$probe.Start()
$port = $probe.LocalEndpoint.Port
$probe.Stop()
$route = [Guid]::NewGuid().ToString('N')
@{Port=$port;Route=$route;CodexConfigDirectory=(Join-Path $checkDirectory 'missing-listener-codex')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $checkDirectory 'settings.json') -Encoding UTF8
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
    Assert-True ((Request-Status "GET /unrelated HTTP/1.1`r`nHost: localhost`r`n`r`n") -eq '404') 'Requests outside /backend-api must be rejected.'
    Assert-True ((Request-Status "GET /$testRoute/unrelated HTTP/1.1`r`nHost: localhost`r`n`r`n") -eq '404') 'Routed requests outside /backend-api must be rejected.'
    Assert-True ((Request-Status "GET /backend-api/wham/usage HTTP/1.1`r`nHost: localhost`r`nOrigin: https://example.com`r`n`r`n") -eq '403') 'Desktop requests must pass routing but still reject browser origins.'
    Assert-True ((Request-Status "GET /$route/backend-api/codex/models HTTP/1.1`r`nHost: localhost`r`nOrigin: https://example.com`r`n`r`n") -eq '403') 'Browser-origin request must be rejected.'
    Assert-True ((Request-Status "GET /$route/backend-api/wham/remote/control/server HTTP/1.1`r`nHost: localhost`r`nOrigin: https://example.com`r`n`r`n") -eq '403') 'Remote-control browser-origin request must be rejected.'
    Assert-True ((Request-Status "POST /$route/backend-api/ps/mcp HTTP/1.1`r`nHost: localhost`r`nOrigin: https://example.com`r`nContent-Length: 0`r`n`r`n") -eq '403') 'Apps MCP browser-origin requests must be rejected.'
    Assert-True ((Request-Status "TRACE /$route/backend-api/ps/mcp HTTP/1.1`r`nHost: localhost`r`n`r`n") -eq '405') 'Apps MCP must reject unsupported methods before accessing credentials.'
    Assert-True ((Request-Status "POST /$route/backend-api/ps/mcp HTTP/1.1`r`nHost: localhost`r`nAuthorization: `r`nContent-Length: 0`r`n`r`n") -eq '400') 'Apps MCP must reject an empty Authorization header.'
    Assert-True ((Request-Status "POST /$route/backend-api/ps/mcp HTTP/1.1`r`nHost: localhost`r`nAuthorization: Bearer fixture-one`r`nauthorization: Bearer fixture-two`r`nContent-Length: 0`r`n`r`n") -eq '400') 'Apps MCP must reject duplicate Authorization headers.'
    Assert-True ((Request-Status "POST /$route/backend-api/ps/mcp HTTP/1.1`r`nHost: localhost`r`nContent-Length: 0`r`n`r`n") -eq '401') 'Apps MCP requests without local authentication must return 401.'
    Assert-True ((Request-Status "GET / HTTP/1.0`r`n`r`n") -eq '400') 'Unsupported HTTP version must be rejected.'
    $state = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json
    Assert-True ($state.requests -eq 0) 'Rejected requests reached upstream routing.'
    Write-Output 'Listener checks passed: private route, desktop path, browser-origin rejection, MCP method/authentication validation, protocol validation, no upstream requests.'
} finally {
    if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
}

# HTTPS listener: a temporary certificate in the current user's personal store,
# never trusted in any root store and removed afterwards.
Add-Type -Path (Join-Path $PSScriptRoot 'TlsListenerChecks.cs')
Import-Module (Join-Path $project 'scripts\Certificate.psm1') -Force
$tlsDirectory = Join-Path $checkDirectory 'tls'
New-Item -ItemType Directory -Path $tlsDirectory | Out-Null
Copy-Item -LiteralPath (Join-Path $project 'build\CodexProxyGuardian.exe') -Destination (Join-Path $tlsDirectory 'CodexProxyGuardian.exe')
$probe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
$probe.Start()
$tlsPort = $probe.LocalEndpoint.Port
$probe.Stop()
$tlsCertificate = New-GuardianCertificate
$tlsProcess = $null
try {
    Assert-True ($tlsCertificate.HasPrivateKey -and $tlsCertificate.Subject -eq 'CN=Codex Proxy Guardian') 'Certificate creation failed.'
    Assert-True ((Get-GuardianCertificate -Thumbprint $tlsCertificate.Thumbprint).Thumbprint -eq $tlsCertificate.Thumbprint) 'Certificate lookup by thumbprint failed.'
    Assert-True (Test-GuardianCertificateCurrent -Certificate $tlsCertificate) 'A fresh certificate was reported as expiring.'
    Assert-True (-not (Test-GuardianCertificateTrusted -Thumbprint $tlsCertificate.Thumbprint)) 'The check certificate must not be trusted.'
    $san = ($tlsCertificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }).Format($false)
    Assert-True ($san -match '127\.0\.0\.1' -and $san -match 'localhost') 'Certificate lacks the loopback names.'
    @{Port=$tlsPort;Route=$route;CodexConfigDirectory=(Join-Path $checkDirectory 'missing-listener-codex');CertificateThumbprint=$tlsCertificate.Thumbprint} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $tlsDirectory 'settings.json') -Encoding UTF8
    $tlsProcess = Start-Process -FilePath (Join-Path $tlsDirectory 'CodexProxyGuardian.exe') -WindowStyle Hidden -PassThru
    $tlsStatus = Join-Path $tlsDirectory 'status.json'
    for($i=0; $i -lt 50 -and -not (Test-Path -LiteralPath $tlsStatus); $i++) { Start-Sleep -Milliseconds 100 }
    Assert-True (Test-Path -LiteralPath $tlsStatus) 'TLS listener failed to start.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $tlsDirectory 'guardian.log') -Raw) -match ('started 127\.0\.0\.1:' + $tlsPort + ' tls=True')) 'TLS listener did not report TLS mode.'
    $presented = $null
    $status = [GuardianTlsChecks]::Request($tlsPort, $tlsCertificate.Thumbprint, "GET /unrelated HTTP/1.1`r`nHost: 127.0.0.1`r`n`r`n", [ref]$presented)
    Assert-True ($presented -eq $tlsCertificate.Thumbprint) 'TLS listener presented a different certificate.'
    Assert-True ($status.Split(' ')[1] -eq '404') 'TLS request outside /backend-api was not rejected.'
    $status = [GuardianTlsChecks]::Request($tlsPort, $tlsCertificate.Thumbprint, "GET /$route/backend-api/codex/models HTTP/1.1`r`nHost: 127.0.0.1`r`nOrigin: https://example.com`r`n`r`n", [ref]$presented)
    Assert-True ($status.Split(' ')[1] -eq '403') 'TLS browser-origin request was not rejected.'
    $status = [GuardianTlsChecks]::Request($tlsPort, $tlsCertificate.Thumbprint, "POST /$route/backend-api/ps/mcp HTTP/1.1`r`nHost: 127.0.0.1`r`nContent-Length: 0`r`n`r`n", [ref]$presented)
    Assert-True ($status.Split(' ')[1] -eq '401') 'TLS MCP request without local authentication must return 401.'
    Assert-True ([GuardianTlsChecks]::PlainHttpRejected($tlsPort)) 'Plaintext HTTP was answered on the TLS listener.'
    $wrong = $false
    try { [GuardianTlsChecks]::Request($tlsPort, '0000000000000000000000000000000000000000', "GET /unrelated HTTP/1.1`r`n`r`n", [ref]$presented) | Out-Null } catch { $wrong = $true }
    Assert-True $wrong 'The TLS check client accepted an unexpected certificate.'
    Start-Sleep -Milliseconds 300
    $tlsState = Get-Content -LiteralPath $tlsStatus -Raw | ConvertFrom-Json
    Assert-True ($tlsState.requests -eq 0 -and $tlsState.tls -eq $true) 'TLS checks reached upstream routing or lost the TLS flag.'
    Write-Output 'HTTPS listener checks passed: local certificate, TLS handshake, private route and desktop paths over TLS, plaintext rejection, no upstream requests.'
} finally {
    if ($tlsProcess -and -not $tlsProcess.HasExited) { $tlsProcess.Kill(); $tlsProcess.WaitForExit() }
    $removedFrom = Remove-GuardianCertificate -Thumbprint $tlsCertificate.Thumbprint
    Assert-True (($removedFrom -join ',') -eq 'My' -and $null -eq (Get-GuardianCertificate -Thumbprint $tlsCertificate.Thumbprint)) 'Check certificate was not removed from the personal store.'
}
$packageDirectory = Join-Path $project ('build\package-check-' + [Guid]::NewGuid().ToString('N'))
$setup = Start-Process -FilePath (Join-Path $project 'build\CodexProxyGuardian-Setup.exe') -ArgumentList @('--verify-package',('"'+$packageDirectory+'"')) -WindowStyle Hidden -Wait -PassThru
Assert-True ($setup.ExitCode -eq 0) 'Installer package extraction failed.'
$payload = @{
    'Guardian.exe' = 'build\CodexProxyGuardian.exe'
    'install.ps1' = 'install.ps1'
    'uninstall.ps1' = 'uninstall.ps1'
    'scripts\Config.psm1' = 'scripts\Config.psm1'
    'scripts\Certificate.psm1' = 'scripts\Certificate.psm1'
}
foreach($file in $payload.Keys) {
    $actual = Get-FileHash -LiteralPath (Join-Path $packageDirectory $file) -Algorithm SHA256
    $expected = Get-FileHash -LiteralPath (Join-Path $project $payload[$file]) -Algorithm SHA256
    Assert-True ($actual.Hash -eq $expected.Hash) "Embedded payload differs from source: $file"
}
$badArguments = Start-Process -FilePath (Join-Path $project 'build\CodexProxyGuardian-Setup.exe') -ArgumentList @('--install','--unknown-switch') -WindowStyle Hidden -Wait -PassThru
Assert-True ($badArguments.ExitCode -eq 2) 'Installer must reject unknown command-line switches without acting.'
Write-Output 'Single-file installer package check passed: embedded EXE, installation components and command-line validation.'
Write-Output 'All checks passed. Test artifacts remain under build/ (gitignored).'
