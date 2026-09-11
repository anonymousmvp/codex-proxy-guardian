Set-StrictMode -Version Latest
$beginMarker = '# BEGIN CodexProxyGuardian'
$endMarker = '# END CodexProxyGuardian'
$legacyComment = '# Codex-only proxy guardian; reads the current Windows system proxy on each connection.'

function Get-TopLevelProxyUrl {
    param([string]$Text, [ValidateSet('openai_base_url','chatgpt_base_url')][string]$Key='openai_base_url')
    $top = ($Text -split '(?m)^\s*\[', 2)[0]
    $matchesFound = [regex]::Matches($top, '(?m)^[ \t]*'+$Key+'[ \t]*=[ \t]*["'']([^"''\r\n]+)["''][ \t]*(?:#[^\r\n]*)?\r?$')
    if ($matchesFound.Count -gt 1) { throw "Duplicate $Key entries; resolve them manually." }
    if ($matchesFound.Count -eq 1) { return $matchesFound[0].Groups[1].Value }
    if ($top -match ('(?m)^\s*'+$Key+'\s*=')) { throw "Unsupported existing $Key syntax." }
    return $null
}

function Remove-OwnedUrl {
    param([string]$Text,[string]$BaseUrl,[string]$Key)
    $current = Get-TopLevelProxyUrl -Text $Text -Key $Key
    if ($current -ne $BaseUrl) { return $Text }
    $pattern = '(?m)^[ \t]*'+$Key+'[ \t]*=[ \t]*["'']' + [regex]::Escape($BaseUrl) + '["''][ \t]*(?:#.*)?\r?\n?'
    $table = [regex]::Match($Text, '(?m)^\s*\[')
    $length = if ($table.Success) { $table.Index } else { $Text.Length }
    $top = [regex]::Replace($Text.Substring(0, $length), $pattern, '')
    foreach ($comment in @($beginMarker, $endMarker, $legacyComment)) {
        $top = [regex]::Replace($top, '(?m)^' + [regex]::Escape($comment) + '\r?\n?', '')
    }
    return $top + $Text.Substring($length)
}

function Remove-GuardianConfig {
    param([string]$Text, [Parameter(Mandatory=$true)][string]$BaseUrl)
    if (-not $BaseUrl.EndsWith('/codex')) { throw 'Model base URL must end in /codex.' }
    $chatgptUrl = $BaseUrl.Substring(0,$BaseUrl.Length-6)
    $clean = Remove-OwnedUrl -Text $Text -BaseUrl $BaseUrl -Key 'openai_base_url'
    return Remove-OwnedUrl -Text $clean -BaseUrl $chatgptUrl -Key 'chatgpt_base_url'
}

function Set-GuardianConfig {
    param([string]$Text, [Parameter(Mandatory=$true)][string]$BaseUrl)
    if (-not $BaseUrl.EndsWith('/codex')) { throw 'Model base URL must end in /codex.' }
    $chatgptUrl = $BaseUrl.Substring(0,$BaseUrl.Length-6)
    foreach ($entry in @(@{Key='openai_base_url';Value=$BaseUrl},@{Key='chatgpt_base_url';Value=$chatgptUrl})) {
        $current = Get-TopLevelProxyUrl -Text $Text -Key $entry.Key
        if ($current -and $current -ne $entry.Value) { throw "A different $($entry.Key) exists. No configuration was changed." }
    }
    $clean = Remove-GuardianConfig -Text $Text -BaseUrl $BaseUrl
    return "$beginMarker`r`nopenai_base_url = `"$BaseUrl`"`r`nchatgpt_base_url = `"$chatgptUrl`"`r`n$endMarker`r`n$clean"
}

Export-ModuleMember -Function Get-TopLevelProxyUrl,Set-GuardianConfig,Remove-GuardianConfig
