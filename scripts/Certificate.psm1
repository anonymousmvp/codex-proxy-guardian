Set-StrictMode -Version Latest
# Machine-local TLS certificate for the 127.0.0.1 listener. Codex only accepts an
# HTTPS chatgpt_base_url, so the certificate lives in the current user's personal
# store (private key, non-exportable) and its public part is trusted in the current
# user's root store. Nothing is written to machine-wide stores.
$subject = 'CN=Codex Proxy Guardian'
$friendlyName = 'Codex Proxy Guardian (127.0.0.1)'

function Get-GuardianCertificate {
    param([string]$Thumbprint)
    if (-not $Thumbprint -or $Thumbprint -notmatch '^[0-9A-Fa-f]{40}$') { return $null }
    $store = New-Object Security.Cryptography.X509Certificates.X509Store('My','CurrentUser')
    $store.Open('ReadOnly')
    try {
        foreach ($candidate in $store.Certificates.Find('FindByThumbprint',$Thumbprint,$false)) {
            if ($candidate.HasPrivateKey) { return $candidate }
        }
        return $null
    } finally { $store.Close() }
}

function Test-GuardianCertificateCurrent {
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    if (-not $Certificate) { return $false }
    # Renew well before expiry so a running installation never presents an expired certificate.
    return $Certificate.NotAfter -gt (Get-Date).AddDays(30)
}

function New-GuardianCertificate {
    # Built with the .NET Framework 4.7.2+ certificate APIs so it does not depend on the
    # PKI module or the Cert: drive, which are not always available to the hosted
    # PowerShell the installer EXE starts.
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    try {
        $request = New-Object Security.Cryptography.X509Certificates.CertificateRequest($subject, $rsa,
            [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $names = New-Object Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder
        $names.AddIpAddress([Net.IPAddress]::Loopback)
        $names.AddDnsName('localhost')
        $request.CertificateExtensions.Add($names.Build())
        $request.CertificateExtensions.Add((New-Object Security.Cryptography.X509Certificates.X509BasicConstraintsExtension($false,$false,0,$true)))
        $request.CertificateExtensions.Add((New-Object Security.Cryptography.X509Certificates.X509KeyUsageExtension(
            ([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment), $true)))
        $serverAuth = New-Object Security.Cryptography.OidCollection
        $serverAuth.Add((New-Object Security.Cryptography.Oid('1.3.6.1.5.5.7.3.1'))) | Out-Null
        $request.CertificateExtensions.Add((New-Object Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension($serverAuth,$false)))
        $request.CertificateExtensions.Add((New-Object Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension($request.PublicKey,$false)))
        $now = [DateTimeOffset]::UtcNow
        $ephemeral = $request.CreateSelfSigned($now.AddDays(-1), $now.AddYears(10))
        try {
            # Import the PFX without the Exportable flag: the persisted private key stays
            # inside the current user's key store and cannot be exported later.
            $password = [Guid]::NewGuid().ToString('N')
            $pfx = $ephemeral.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $password)
            $persisted = New-Object Security.Cryptography.X509Certificates.X509Certificate2($pfx, $password,
                ([Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet -bor [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet))
            $persisted.FriendlyName = $friendlyName
            $store = New-Object Security.Cryptography.X509Certificates.X509Store('My','CurrentUser')
            $store.Open('ReadWrite')
            try { $store.Add($persisted) } finally { $store.Close() }
        } finally { $ephemeral.Dispose() }
    } finally { $rsa.Dispose() }
    $created = Get-GuardianCertificate -Thumbprint $persisted.Thumbprint
    if (-not $created) { throw 'The local certificate was not stored with its private key.' }
    return $created
}

function Test-GuardianCertificateTrusted {
    param([Parameter(Mandatory=$true)][string]$Thumbprint)
    $store = New-Object Security.Cryptography.X509Certificates.X509Store('Root','CurrentUser')
    $store.Open('ReadOnly')
    try { return $store.Certificates.Find('FindByThumbprint',$Thumbprint,$false).Count -gt 0 }
    finally { $store.Close() }
}

function Add-GuardianCertificateTrust {
    # Windows shows its own security confirmation before a certificate enters the
    # user's root store. Declining it leaves the store unchanged and raises here.
    param([Parameter(Mandatory=$true)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    if (Test-GuardianCertificateTrusted -Thumbprint $Certificate.Thumbprint) { return }
    $public = New-Object Security.Cryptography.X509Certificates.X509Certificate2(,$Certificate.Export('Cert'))
    $store = New-Object Security.Cryptography.X509Certificates.X509Store('Root','CurrentUser')
    $store.Open('ReadWrite')
    try { $store.Add($public) } finally { $store.Close() }
    if (-not (Test-GuardianCertificateTrusted -Thumbprint $Certificate.Thumbprint)) {
        throw 'The local certificate was not added to the trusted root store.'
    }
}

function Remove-GuardianCertificate {
    # Removes the public trust first, then the private key. Windows may ask for
    # confirmation before deleting from the user's root store.
    param([Parameter(Mandatory=$true)][string]$Thumbprint)
    $removed = @()
    foreach ($storeName in @('Root','My')) {
        $store = New-Object Security.Cryptography.X509Certificates.X509Store($storeName,'CurrentUser')
        $store.Open('ReadWrite')
        try {
            foreach ($certificate in @($store.Certificates.Find('FindByThumbprint',$Thumbprint,$false))) {
                $store.Remove($certificate)
                $removed += $storeName
            }
        } finally { $store.Close() }
    }
    return ,$removed
}

Export-ModuleMember -Function Get-GuardianCertificate,Test-GuardianCertificateCurrent,New-GuardianCertificate,Test-GuardianCertificateTrusted,Add-GuardianCertificateTrust,Remove-GuardianCertificate
