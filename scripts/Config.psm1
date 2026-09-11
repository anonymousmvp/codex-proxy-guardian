Set-StrictMode -Version Latest
$beginMarker = '# BEGIN CodexProxyGuardian'
$endMarker = '# END CodexProxyGuardian'
$legacyComment = '# Codex-only proxy guardian; reads the current Windows system proxy on each connection.'

function Get-TopLevelProxyUrl {
    param([string]$Text)
    $top = ($Text -split '(?m)^\s*\[', 2)[0]
    $matchesFound = [regex]::Matches($top, '(?m)^[ \t]*openai_base_url[ \t]*=[ \t]*["'']([^"''\r\n]+)["''][ \t]*(?:#[^\r\n]*)?\r?$')
    if ($matchesFound.Count -gt 1) { throw 'Duplicate openai_base_url entries; resolve them manually.' }
    if ($matchesFound.Count -eq 1) { return $matchesFound[0].Groups[1].Value }
    if ($top -match '(?m)^\s*openai_base_url\s*=') { throw 'Unsupported existing openai_base_url syntax.' }
    return $null
}

function Remove-GuardianConfig {
    param([string]$Text, [Parameter(Mandatory=$true)][string]$BaseUrl)
    $current = Get-TopLevelProxyUrl $Text
    if ($current -ne $BaseUrl) { return $Text }
    $pattern = '(?m)^[ \t]*openai_base_url[ \t]*=[ \t]*["'']' + [regex]::Escape($BaseUrl) + '["''][ \t]*(?:#.*)?\r?\n?'
    $table = [regex]::Match($Text, '(?m)^\s*\[')
    $length = if ($table.Success) { $table.Index } else { $Text.Length }
    $top = [regex]::Replace($Text.Substring(0, $length), $pattern, '')
    foreach ($comment in @($beginMarker, $endMarker, $legacyComment)) {
        $top = [regex]::Replace($top, '(?m)^' + [regex]::Escape($comment) + '\r?\n?', '')
    }
    return $top + $Text.Substring($length)
}

function Set-GuardianConfig {
    param([string]$Text, [Parameter(Mandatory=$true)][string]$BaseUrl)
    $current = Get-TopLevelProxyUrl $Text
    if ($current -and $current -ne $BaseUrl) { throw 'A different openai_base_url exists. No configuration was changed.' }
    $clean = Remove-GuardianConfig -Text $Text -BaseUrl $BaseUrl
    return "$beginMarker`r`nopenai_base_url = `"$BaseUrl`"`r`n$endMarker`r`n$clean"
}

Export-ModuleMember -Function Get-TopLevelProxyUrl,Set-GuardianConfig,Remove-GuardianConfig
