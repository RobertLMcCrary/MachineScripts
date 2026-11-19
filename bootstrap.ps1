$ErrorActionPreference = 'Stop'

# Invoke-WebRequest's progress bar makes downloads many times slower on
# Windows PowerShell 5.1.
$ProgressPreference = 'SilentlyContinue'

# Older Windows / .NET defaults to TLS 1.0, which GitHub and Tailscale refuse.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor
    [Net.SecurityProtocolType]::Tls12

# Let downloads go through an authenticating corporate proxy if there is one.
try {
    [Net.WebRequest]::DefaultWebProxy.Credentials =
        [Net.CredentialCache]::DefaultNetworkCredentials
}
catch { }

$PublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIrh/O8dmsER+IapRrf0jflrWu603Z9Iq/JzMu0VLHi8 colmena-hetzner'

$TailscaleV4 = '100.64.0.0/10'
$TailscaleV6 = 'fd7a:115c:a1e0::/48'

$KeyBlob = ($PublicKey -split '\s+')[1]

$AuthorizedKey = "from=`"$TailscaleV4,$TailscaleV6`" $PublicKey"

$SshCapability = 'OpenSSH.Server~~~~0.0.1.0'

# Write text files as UTF-8 without a BOM; sshd rejects a BOM.
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

# ============================================================
# Helpers
# ============================================================

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message"
}

function Write-Note([string]$Message) {
    Write-Host "    $Message"
}

# Run a native program and return its exit code. Output goes to the screen.
# Windows PowerShell 5.1 can turn native stderr into a terminating error
# under ErrorActionPreference = Stop, so relax it for the call.
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    $ErrorActionPreference = 'Continue'
    & $FilePath @Arguments | Out-Host
    return $LASTEXITCODE
}

# Run a native program and return its stdout lines (stderr discarded).
function Get-NativeOutput {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    $ErrorActionPreference = 'Continue'
    $output = & $FilePath @Arguments 2>$null
    return @($output | ForEach-Object { "$_" })
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Get-OSArchitecture {
    $arch =
        if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 }
        else { $env:PROCESSOR_ARCHITECTURE }

    switch ($arch.ToUpperInvariant()) {
        'AMD64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        'X86'   { return 'x86' }
        default { throw "Unsupported architecture: $arch" }
    }
}

# Path of the executable a service runs, or $null if there is no such service.
# ImagePath can be quoted or unquoted, with or without arguments.
function Get-ServiceExePath([string]$Name) {
    $service = Get-CimInstance Win32_Service -Filter "Name='$Name'" `
        -ErrorAction SilentlyContinue

    if (-not $service -or -not $service.PathName) {
        return $null
    }

    $match = [regex]::Match($service.PathName, '^\s*"?(.+?\.exe)', 'IgnoreCase')

    if ($match.Success) {
        return [Environment]::ExpandEnvironmentVariables($match.Groups[1].Value)
    }

    return $null
}

function Install-Msi([string]$Path, [string[]]$ExtraArguments = @()) {
    $arguments = @('/i', "`"$Path`"", '/qn', '/norestart') + $ExtraArguments

    $process = Start-Process msiexec.exe -ArgumentList $arguments -Wait -PassThru

    switch ($process.ExitCode) {
        0    { return }
        3010 { return }
        1618 { throw 'Another installation is in progress (msiexec 1618). Wait for it to finish (or reboot) and run this again.' }
        default { throw "Installing $(Split-Path $Path -Leaf) failed (msiexec exit code $($process.ExitCode))." }
    }
}

function Save-Download([string]$Url, [string]$FileName) {
    $dir = Join-Path $env:TEMP ('team-bootstrap-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $path = Join-Path $dir $FileName
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $path
    return $path
}

# ============================================================
# Preflight
# ============================================================

if (-not (Test-Administrator)) {
    throw 'Run PowerShell as Administrator and run this again.'
}

# A 32-bit PowerShell on 64-bit Windows sees a redirected System32 that has
# no OpenSSH or DISM for the real OS, so everything below would misbehave.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    throw 'This is 32-bit PowerShell. Open the normal (64-bit) "Windows PowerShell" as Administrator and run this again.'
}

$TargetUser = $env:USERNAME

# Domain accounts log in as DOMAIN\user; local accounts as plain user.
$SshLoginUser =
    if ($env:USERDOMAIN -and $env:USERDOMAIN -ne $env:COMPUTERNAME) {
        "$env:USERDOMAIN\$env:USERNAME"
    }
    else {
        $env:USERNAME
    }

$OsArch = Get-OSArchitecture

# ============================================================
# OpenSSH Server
#
# First choice is the built-in Windows feature. It is downloaded
# from Windows Update, which fails with 0x800f0954 on machines
# whose updates come from WSUS / SCCM / Intune, and does not
# exist on older Windows. In those cases fall back to Microsoft's
# Win32-OpenSSH MSI from GitHub.
# ============================================================

function Install-OpenSshCapability {

    $dism = Join-Path $env:WINDIR 'System32\dism.exe'

    if (-not (Test-Path $dism)) {
        return $false
    }

    Write-Note 'Trying the built-in Windows feature (this can take a few minutes)...'

    $process = Start-Process $dism `
        -ArgumentList @('/Online', '/Add-Capability', "/CapabilityName:$SshCapability", '/NoRestart', '/Quiet') `
        -WindowStyle Hidden `
        -PassThru

    # Reading Handle makes ExitCode available after WaitForExit on PS 5.1.
    $null = $process.Handle

    # On some WSUS-managed machines DISM hangs instead of failing.
    if (-not $process.WaitForExit(10 * 60 * 1000)) {
        Write-Note 'The Windows feature install timed out.'
        try { $process.Kill() } catch { }
        return $false
    }

    $code = $process.ExitCode

    if ($code -eq 0 -or $code -eq 3010) {
        return $true
    }

    $hex = '0x{0:x8}' -f $code

    if ($hex -eq '0x800f0954') {
        Write-Note "Windows could not download the feature ($hex): this machine gets updates from WSUS/SCCM, not Windows Update."
    }
    else {
        Write-Note "The Windows feature install failed ($hex)."
    }

    return $false
}

function Install-OpenSshMsi {

    $assetArch =
        switch ($OsArch) {
            'amd64' { 'Win64' }
            'arm64' { 'ARM64' }
            'x86'   { 'Win32' }
        }

    Write-Note 'Installing OpenSSH Server from Microsoft''s Win32-OpenSSH release instead...'

    $releases = Invoke-RestMethod -UseBasicParsing `
        -Uri 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases?per_page=20' `
        -Headers @{ 'User-Agent' = 'MachineScripts-bootstrap' }

    $pattern = "^OpenSSH-$assetArch(-v[0-9.]+)?\.msi$"

    $asset = $null

    # Prefer full releases; use a prerelease only if nothing else has an MSI.
    foreach ($wantPrerelease in @($false, $true)) {
        foreach ($release in $releases) {
            if ([bool]$release.prerelease -ne $wantPrerelease -or $release.draft) {
                continue
            }

            $asset = $release.assets |
                Where-Object { $_.name -match $pattern } |
                Select-Object -First 1

            if ($asset) { break }
        }

        if ($asset) { break }
    }

    if (-not $asset) {
        throw "Could not find a Win32-OpenSSH MSI for $assetArch on GitHub."
    }

    Write-Note "Downloading $($asset.name)"

    $msiPath = Save-Download $asset.browser_download_url $asset.name

    try {
        Install-Msi $msiPath @('ADDLOCAL=Server')
    }
    finally {
        Remove-Item (Split-Path $msiPath) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Step 'Installing OpenSSH Server'

if (Get-Service sshd -ErrorAction SilentlyContinue) {
    Write-Note 'OpenSSH Server is already installed.'
}
else {
    $installed = Install-OpenSshCapability

    if (-not $installed -or -not (Get-Service sshd -ErrorAction SilentlyContinue)) {
        Install-OpenSshMsi
    }

    if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
        throw 'OpenSSH Server installed but the sshd service does not exist. A reboot may be needed; reboot and run this again.'
    }
}

$sshdExe = Get-ServiceExePath 'sshd'

if (-not $sshdExe -or -not (Test-Path $sshdExe)) {
    throw "Could not find sshd.exe for the sshd service (service path: $sshdExe)."
}

Write-Note "Using $sshdExe"

$sshDir = Join-Path $env:ProgramData 'ssh'
$sshdConfig = Join-Path $sshDir 'sshd_config'

Set-Service -Name sshd -StartupType Automatic

# The first start creates sshd_config and the host keys.
Start-Service sshd

for ($i = 0; $i -lt 20 -and -not (Test-Path $sshdConfig); $i++) {
    Start-Sleep -Milliseconds 500
}

if (-not (Test-Path $sshdConfig)) {
    $defaultConfig = Join-Path (Split-Path $sshdExe) 'sshd_config_default'

    if (-not (Test-Path $defaultConfig)) {
        throw "sshd did not create $sshdConfig and no sshd_config_default was found."
    }

    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    Copy-Item $defaultConfig $sshdConfig
}

# ============================================================
# Authorized key
#
# Administrators' keys are read from administrators_authorized_keys
# (via the "Match Group administrators" block in the default config).
# ============================================================

Write-Step "Installing team SSH key for $TargetUser"

$authorizedKeys = Join-Path $sshDir 'administrators_authorized_keys'

$existingLines = @()

if (Test-Path $authorizedKeys) {
    $existingLines = @(Get-Content $authorizedKeys)
}

# Remove old copy of this exact key.
$newLines = @(
    @($existingLines | Where-Object { $_ -notlike "*$KeyBlob*" }) +
    $AuthorizedKey
)

[IO.File]::WriteAllLines($authorizedKeys, [string[]]$newLines, $Utf8NoBom)

# Locale-safe Administrators and SYSTEM SIDs. sshd ignores this file
# unless only those two can access it.
$icaclsExit = Invoke-Native icacls.exe @(
    $authorizedKeys, '/inheritance:r',
    '/grant', '*S-1-5-32-544:F',
    '/grant', '*S-1-5-18:F'
)

if ($icaclsExit -ne 0) {
    throw "Failed to configure ACLs on $authorizedKeys"
}

# Make sure the config still routes administrators to that file.
$configText = [IO.File]::ReadAllText($sshdConfig)

if ($configText -notmatch '(?im)^\s*Match\s+Group\s+administrators') {

    Write-Note 'Adding the "Match Group administrators" block to sshd_config.'

    $configText = $configText.TrimEnd() + "`r`n`r`nMatch Group administrators`r`n       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys`r`n"

    [IO.File]::WriteAllText($sshdConfig, $configText, $Utf8NoBom)
}

# ============================================================
# sshd_config
# ============================================================

function Set-SshdDirective {

    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $lines = @(Get-Content $Path)

    # Global directives must come before the first Match block.
    $matchIndex = $lines.Count

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*Match\s+') {
            $matchIndex = $i
            break
        }
    }

    $escapedName = [regex]::Escape($Name)
    $found = $false

    for ($i = 0; $i -lt $matchIndex; $i++) {
        if ($lines[$i] -match "^\s*$escapedName\s+") {
            $lines[$i] = "$Name $Value"
            $found = $true
            break
        }
    }

    if (-not $found) {
        $before = @()
        $after = @()

        if ($matchIndex -gt 0) {
            $before = @($lines[0..($matchIndex - 1)])
        }

        if ($matchIndex -lt $lines.Count) {
            $after = @($lines[$matchIndex..($lines.Count - 1)])
        }

        $lines = @($before + "$Name $Value" + $after)
    }

    [IO.File]::WriteAllLines($Path, [string[]]$lines, $Utf8NoBom)
}

Write-Step 'Configuring SSH for public-key-only authentication'

$sshdBackup = "$sshdConfig.team-bootstrap.bak"

if (-not (Test-Path $sshdBackup)) {
    Copy-Item $sshdConfig $sshdBackup
}

Set-SshdDirective -Path $sshdConfig -Name 'PubkeyAuthentication' -Value 'yes'
Set-SshdDirective -Path $sshdConfig -Name 'PasswordAuthentication' -Value 'no'

if ((Invoke-Native $sshdExe @('-t', '-f', $sshdConfig)) -ne 0) {
    Copy-Item $sshdBackup $sshdConfig -Force
    throw 'Invalid sshd_config. Original configuration restored.'
}

Restart-Service sshd

# ============================================================
# Windows Firewall
#
# Disable the all-interface SSH rules that Windows / the MSI
# create and replace them with one that permits SSH from
# Tailscale addresses only.
# ============================================================

Write-Step 'Restricting SSH firewall access to Tailscale'

$ruleName = 'Team-OpenSSH-Tailscale-Only'

Get-NetFirewallRule -Direction Inbound -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -ne $ruleName -and (
            $_.Name -like 'OpenSSH*' -or
            $_.DisplayName -like '*OpenSSH*' -or
            $_.DisplayName -like '*(sshd)*'
        )
    } |
    Disable-NetFirewallRule -ErrorAction SilentlyContinue

Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

New-NetFirewallRule `
    -Name $ruleName `
    -DisplayName 'OpenSSH Server - Tailscale only' `
    -Enabled True `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 22 `
    -RemoteAddress @($TailscaleV4, $TailscaleV6) `
    -Action Allow `
    -Profile Any |
    Out-Null

# Group Policy can tell Windows to ignore locally created rules.
$FirewallWarning = $null

$ignoringLocal = @(
    Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
        Where-Object { "$($_.AllowLocalFirewallRules)" -eq 'False' -and "$($_.Enabled)" -eq 'True' }
)

if ($ignoringLocal.Count -gt 0) {
    $FirewallWarning =
        "Group Policy ignores local firewall rules on the $(($ignoringLocal.Name) -join '/') profile(s). " +
        'SSH may be blocked until IT allows inbound TCP 22 from 100.64.0.0/10.'
    Write-Note "WARNING: $FirewallWarning"
}

# ============================================================
# Tailscale
# ============================================================

function Get-TailscaleExe {
    $serviceExe = Get-ServiceExePath 'Tailscale'

    if ($serviceExe) {
        $candidate = Join-Path (Split-Path $serviceExe) 'tailscale.exe'
        if (Test-Path $candidate) { return $candidate }
    }

    $candidate = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (Test-Path $candidate) { return $candidate }

    return $null
}

$tailscaleExe = Get-TailscaleExe

if (-not $tailscaleExe) {

    Write-Step 'Installing Tailscale'

    $packagePage = (
        Invoke-WebRequest -UseBasicParsing -Uri 'https://pkgs.tailscale.com/stable/'
    ).Content

    $match = [regex]::Match(
        $packagePage,
        "tailscale-setup-([0-9]+\.[0-9]+\.[0-9]+)-$OsArch\.msi"
    )

    if (-not $match.Success) {
        throw "Could not locate current Tailscale MSI for $OsArch"
    }

    Write-Note "Downloading $($match.Value)"

    $msiPath = Save-Download "https://pkgs.tailscale.com/stable/$($match.Value)" $match.Value

    try {
        Install-Msi $msiPath @('TS_UNATTENDEDMODE=always')
    }
    finally {
        Remove-Item (Split-Path $msiPath) -Recurse -Force -ErrorAction SilentlyContinue
    }

    $tailscaleExe = Get-TailscaleExe

    if (-not $tailscaleExe) {
        throw 'Tailscale installed but tailscale.exe was not found.'
    }
}

Set-Service -Name Tailscale -StartupType Automatic
Start-Service Tailscale -ErrorAction SilentlyContinue

function Get-TailscaleBackendState {
    try {
        $jsonText = (Get-NativeOutput $tailscaleExe @('status', '--json')) -join "`n"
        if (-not $jsonText) { return $null }
        return ($jsonText | ConvertFrom-Json).BackendState
    }
    catch {
        return $null
    }
}

# Give a freshly started service time to come up.
$backendState = $null

for ($i = 0; $i -lt 30; $i++) {
    $backendState = Get-TailscaleBackendState
    if ($backendState -and $backendState -ne 'NoState') { break }
    Start-Sleep -Seconds 1
}

if ($backendState -ne 'Running') {

    Write-Step 'Connecting this machine to Tailscale'

    if ($env:TS_AUTH_KEY) {

        # Optional noninteractive provisioning.
        # TS_AUTH_KEY should come from the environment,
        # NEVER from this public repository.

        $keyFile = [IO.Path]::GetTempFileName()

        try {
            [IO.File]::WriteAllText($keyFile, $env:TS_AUTH_KEY, [Text.Encoding]::ASCII)

            $upExit = Invoke-Native $tailscaleExe @('up', '--unattended', "--auth-key=file:$keyFile")
        }
        finally {
            Remove-Item $keyFile -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        Write-Note 'Open the login link below in a browser to add this machine to the tailnet.'

        $upExit = Invoke-Native $tailscaleExe @('up', '--unattended')
    }

    if ($upExit -ne 0) {
        throw 'tailscale up failed'
    }
}
else {
    Write-Step 'Tailscale is already connected'

    # Ensure it survives logout/reboot.
    $null = Invoke-Native $tailscaleExe @('set', '--unattended=true')
}

# ============================================================
# Verify
# ============================================================

# Report-only from here on; don't let anything abort the summary.
$ErrorActionPreference = 'Continue'

Write-Step 'Checking the result'

$problems = New-Object System.Collections.Generic.List[string]

$sshdService = Get-Service sshd -ErrorAction SilentlyContinue

if (-not $sshdService -or $sshdService.Status -ne 'Running') {
    $problems.Add('The sshd service is not running.')
}

$listening = @(
    Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue
)

if ($listening.Count -eq 0) {
    $problems.Add('Nothing is listening on TCP port 22.')
}

$effective = (Get-NativeOutput $sshdExe @('-T', '-f', $sshdConfig)) -join "`n"

if ($effective -notmatch '(?im)^passwordauthentication\s+no\s*$') {
    $problems.Add('sshd does not report PasswordAuthentication no.')
}

if ($effective -notmatch '(?im)^pubkeyauthentication\s+yes\s*$') {
    $problems.Add('sshd does not report PubkeyAuthentication yes.')
}

if ((Get-TailscaleBackendState) -ne 'Running') {
    $problems.Add('Tailscale is not connected.')
}

$tailscaleIP = Get-NativeOutput $tailscaleExe @('ip', '-4') | Select-Object -First 1

if (-not $tailscaleIP) {
    $problems.Add('Tailscale has no IPv4 address.')
}

$hostAlias = $env:COMPUTERNAME.ToLowerInvariant()

Write-Host ''
Write-Host '============================================================'

if ($problems.Count -eq 0) {
    Write-Host ' SERVER BOOTSTRAP COMPLETE'
}
else {
    Write-Host ' NOT READY'
}

Write-Host '============================================================'

foreach ($problem in $problems) {
    Write-Host "  - $problem"
}

if ($FirewallWarning) {
    Write-Host "  ! $FirewallWarning"
}

Write-Host ''
Write-Host "OS:             Windows"
Write-Host "SSH user:       $SshLoginUser"
Write-Host "Tailscale IPv4: $tailscaleIP"

Write-Host ''
Write-Host 'Tailscale status:'
$null = Invoke-Native $tailscaleExe @('status')

Write-Host ''
Write-Host 'On the computer you connect from, add this to ~/.ssh/config:'
Write-Host ''
Write-Host "Host $hostAlias"
Write-Host "    HostName $tailscaleIP"
Write-Host "    User $SshLoginUser"
Write-Host '    IdentityFile ~/.ssh/colmena_hetzner'
Write-Host '    IdentitiesOnly yes'
Write-Host ''
Write-Host "Then: ssh $hostAlias"
Write-Host ''
Write-Host 'SSH password authentication is disabled.'
Write-Host 'The team SSH key is restricted to Tailscale addresses.'

if ($problems.Count -gt 0) {
    $ErrorActionPreference = 'Stop'
    throw 'Bootstrap finished with problems (see NOT READY above).'
}
