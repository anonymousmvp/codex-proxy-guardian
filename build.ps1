[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $compiler)) { throw 'Install .NET Framework 4.8 first.' }
$outputDirectory = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$outputFile = Join-Path $outputDirectory 'CodexProxyGuardian.exe'
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ /r:System.Web.Extensions.dll "/out:$outputFile" (Join-Path $PSScriptRoot 'src\CodexProxyGuardian.cs')
if ($LASTEXITCODE -ne 0) { throw 'C# compilation failed.' }
Write-Output "Built $outputFile"
$setupFile = Join-Path $outputDirectory 'CodexProxyGuardian-Setup.exe'
$resources = @(
    "/resource:$outputFile,Guardian.exe",
    "/resource:$(Join-Path $PSScriptRoot 'install.ps1'),install.ps1",
    "/resource:$(Join-Path $PSScriptRoot 'uninstall.ps1'),uninstall.ps1",
    "/resource:$(Join-Path $PSScriptRoot 'scripts\Config.psm1'),Config.psm1",
    "/resource:$(Join-Path $PSScriptRoot 'scripts\Certificate.psm1'),Certificate.psm1"
)
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll "/out:$setupFile" @resources (Join-Path $PSScriptRoot 'src\Setup.cs')
if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
# Smart App Control judges every unsigned build by its hash; a rejected file cannot
# start later, so surface that here instead of during installation.
foreach ($built in @($outputFile,$setupFile)) {
    try { [Reflection.Assembly]::LoadFile($built) | Out-Null }
    catch { throw "Windows application control blocked the freshly built $built. Run build.ps1 again to produce a new file: $($_.Exception.GetBaseException().Message)" }
}
Write-Output "Built $setupFile"
