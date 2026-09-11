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
& $compiler /nologo /target:winexe /optimize+ /r:System.Web.Extensions.dll "/out:$outputFile" (Join-Path $PSScriptRoot 'src\CodexProxyGuardian.cs')
if ($LASTEXITCODE -ne 0) { throw 'C# compilation failed.' }
Write-Output "Built $outputFile"
