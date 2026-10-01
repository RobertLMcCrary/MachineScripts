$ErrorActionPreference = 'Stop'

$PublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIrh/O8dmsER+IapRrf0jflrWu603Z9Iq/JzMu0VLHi8 colmena-hetzner'

$TailscaleV4 = '100.64.0.0/10'
$TailscaleV6 = 'fd7a:115c:a1e0::/48'

$KeyBlob = ($PublicKey -split '\s+')[1]

$AuthorizedKey = "from=`"$TailscaleV4,$TailscaleV6`" $PublicKey"

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message"
}

function Test-Administrator {

    $identity =
        [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal =
        New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

if (-not (Test-Administrator)) {
    throw 'Run PowerShell as Administrator and run this again.'
}

$TargetUser = $env:USERNAME

# ============================================================
# OpenSSH
# ============================================================

Write-Step 'Installing OpenSSH Server'

$sshCapability =
    Get-WindowsCapability `
        -Online `
        -Name 'OpenSSH.Server~~~~0.0.1.0'

if ($sshCapability.State -ne 'Installed') {

    Add-WindowsCapability `
        -Online `
        -Name 'OpenSSH.Server~~~~0.0.1.0' |
        Out-Null
}

Set-Service `
    -Name sshd `
    -StartupType Automatic

Start-Service sshd

# ============================================================
# Authorized key
# ============================================================

Write-Step "Installing team SSH key for $TargetUser"

$sshDir =
    Join-Path `
        $env:ProgramData `
        'ssh'

$authorizedKeys =
    Join-Path `
        $sshDir `
        'administrators_authorized_keys'

New-Item `
    -ItemType Directory `
    -Path $sshDir `
    -Force |
    Out-Null

$existingLines = @()

if (Test-Path $authorizedKeys) {
    $existingLines = @(Get-Content $authorizedKeys)
}

# Remove old copy of this exact key.
$filteredLines = @(
    $existingLines |
    Where-Object {
        $_ -notlike "*$KeyBlob*"
    }
)

$newLines = @(
    $filteredLines +
    $AuthorizedKey
)

[IO.File]::WriteAllLines(
    $authorizedKeys,
    [string[]]$newLines,
    [Text.Encoding]::ASCII
)

# Locale-safe Administrators and SYSTEM SIDs.
& icacls.exe `
    $authorizedKeys `
    '/inheritance:r' `
    '/grant' `
    '*S-1-5-32-544:F' `
    '/grant' `
    '*S-1-5-18:F' |
    Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "Failed to configure ACLs on $authorizedKeys"
}

# ============================================================
# sshd_config
# ============================================================

function Set-SshdDirective {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $lines = @(Get-Content $Path)

    $matchIndex = $lines.Count

    for ($i = 0; $i -lt $lines.Count; $i++) {

        if ($lines[$i] -match '^\s*Match\s+') {

            $matchIndex = $i
            break

        }
    }

    $found = $false

    for ($i = 0; $i -lt $matchIndex; $i++) {

        $escapedName =
            [regex]::Escape($Name)

        if ($lines[$i] -match "^\s*$escapedName\s+") {

            $lines[$i] = "$Name $Value"

            $found = $true

            break
        }
    }

    if (-not $found) {

        if ($matchIndex -lt $lines.Count) {

            $before = @()
            $after = @()

            if ($matchIndex -gt 0) {

                $before =
                    @($lines[0..($matchIndex - 1)])

            }

            $after =
                @(
                    $lines[
                        $matchIndex..($lines.Count - 1)
                    ]
                )

            $lines =
                @(
                    $before +
                    "$Name $Value" +
                    $after
                )

        }
        else {

            $lines =
                @(
                    $lines +
                    "$Name $Value"
                )

        }
    }

    [IO.File]::WriteAllLines(
        $Path,
        [string[]]$lines,
        [Text.Encoding]::ASCII
    )
}

Write-Step 'Configuring SSH for public-key-only authentication'

$sshdConfig =
    Join-Path `
        $sshDir `
        'sshd_config'

$sshdBackup =
    "$sshdConfig.team-bootstrap.bak"

if (-not (Test-Path $sshdBackup)) {

    Copy-Item `
        $sshdConfig `
        $sshdBackup

}

Set-SshdDirective `
    -Path $sshdConfig `
    -Name 'PubkeyAuthentication' `
    -Value 'yes'

Set-SshdDirective `
    -Path $sshdConfig `
    -Name 'PasswordAuthentication' `
    -Value 'no'

$sshdExe =
    Join-Path `
        $env:WINDIR `
        'System32\OpenSSH\sshd.exe'

# With ErrorActionPreference = Stop, Windows PowerShell 5.1 throws on any
# native stderr output, which would skip the restore below.
$ErrorActionPreference = 'Continue'

& $sshdExe `
    -t `
    -f $sshdConfig

$sshdTestExitCode = $LASTEXITCODE

$ErrorActionPreference = 'Stop'

if ($sshdTestExitCode -ne 0) {

    Copy-Item `
        $sshdBackup `
        $sshdConfig `
        -Force

    throw 'Invalid sshd_config. Original configuration restored.'
}

Restart-Service sshd

# ============================================================
# Windows Firewall
#
# Disable Windows' default all-interface SSH rule and replace
# it with one that permits SSH from Tailscale addresses only.
# ============================================================

Write-Step 'Restricting SSH firewall access to Tailscale'

Get-NetFirewallRule `
    -Name 'OpenSSH-Server-In-TCP' `
    -ErrorAction SilentlyContinue |
    Disable-NetFirewallRule `
        -ErrorAction SilentlyContinue

$ruleName =
    'Team-OpenSSH-Tailscale-Only'

Get-NetFirewallRule `
    -Name $ruleName `
    -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule `
        -ErrorAction SilentlyContinue

New-NetFirewallRule `
    -Name $ruleName `
    -DisplayName 'OpenSSH Server - Tailscale only' `
    -Enabled True `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 22 `
    -RemoteAddress @(
        $TailscaleV4,
        $TailscaleV6
    ) `
    -Action Allow `
    -Profile Any |
    Out-Null

# ============================================================
# Tailscale
# ============================================================

$tailscaleExe =
    Join-Path `
        $env:ProgramFiles `
        'Tailscale\tailscale.exe'

if (-not (Test-Path $tailscaleExe)) {

    Write-Step 'Installing Tailscale'

    $actualArch =
        if ($env:PROCESSOR_ARCHITEW6432) {
            $env:PROCESSOR_ARCHITEW6432
        }
        else {
            $env:PROCESSOR_ARCHITECTURE
        }

    $packageArch =
        switch ($actualArch.ToUpperInvariant()) {

            'AMD64' {
                'amd64'
            }

            'ARM64' {
                'arm64'
            }

            'X86' {
                'x86'
            }

            default {
                throw "Unsupported architecture: $actualArch"
            }
        }

    $packagePage =
        (
            Invoke-WebRequest `
                -UseBasicParsing `
                'https://pkgs.tailscale.com/stable/'
        ).Content

    $pattern =
        "tailscale-setup-([0-9]+\.[0-9]+\.[0-9]+)-$packageArch\.msi"

    $match =
        [regex]::Match(
            $packagePage,
            $pattern
        )

    if (-not $match.Success) {

        throw "Could not locate current Tailscale MSI for $packageArch"

    }

    $msiName =
        $match.Value

    $msiUrl =
        "https://pkgs.tailscale.com/stable/$msiName"

    $msiPath =
        Join-Path `
            $env:TEMP `
            $msiName

    Invoke-WebRequest `
        -UseBasicParsing `
        $msiUrl `
        -OutFile $msiPath

    $process =
        Start-Process `
            msiexec.exe `
            -ArgumentList @(
                '/i',
                "`"$msiPath`"",
                '/qn',
                '/norestart'
            ) `
            -Wait `
            -PassThru

    Remove-Item `
        $msiPath `
        -Force `
        -ErrorAction SilentlyContinue

    if ($process.ExitCode -notin @(0, 3010)) {

        throw "Tailscale installation failed: $($process.ExitCode)"

    }
}

if (-not (Test-Path $tailscaleExe)) {

    throw "Could not find Tailscale at $tailscaleExe"

}

Set-Service `
    -Name Tailscale `
    -StartupType Automatic

Start-Service `
    Tailscale `
    -ErrorAction SilentlyContinue

# ============================================================
# Check Tailscale state
# ============================================================

function Get-TailscaleBackendState {

    try {

        $jsonText =
            (
                (
                    & $tailscaleExe `
                        status `
                        --json `
                        2>$null
                ) -join "`n"
            )

        if (-not $jsonText) {
            return $null
        }

        return (
            $jsonText |
            ConvertFrom-Json
        ).BackendState

    }
    catch {

        return $null

    }
}

# ============================================================
# Authenticate
# ============================================================

if ((Get-TailscaleBackendState) -ne 'Running') {

    Write-Step 'Connecting this machine to Tailscale'

    if ($env:TS_AUTH_KEY) {

        #
        # Optional noninteractive provisioning.
        # TS_AUTH_KEY should come from the environment,
        # NEVER from this public repository.
        #

        $keyFile =
            [IO.Path]::GetTempFileName()

        try {

            [IO.File]::WriteAllText(
                $keyFile,
                $env:TS_AUTH_KEY,
                [Text.Encoding]::ASCII
            )

            & $tailscaleExe `
                up `
                --unattended `
                "--auth-key=file:$keyFile"

            if ($LASTEXITCODE -ne 0) {
                throw 'tailscale up failed'
            }

        }
        finally {

            Remove-Item `
                $keyFile `
                -Force `
                -ErrorAction SilentlyContinue

        }

    }
    else {

        #
        # Normal interactive login.
        #

        & $tailscaleExe `
            up `
            --unattended

        if ($LASTEXITCODE -ne 0) {
            throw 'tailscale up failed'
        }

    }

}
else {

    Write-Step 'Tailscale is already connected'

    # Ensure it survives logout/reboot.
    & $tailscaleExe `
        set `
        --unattended=true

}

# ============================================================
# Result
# ============================================================

# Report-only from here on; don't let native stderr abort the summary.
$ErrorActionPreference = 'Continue'

$tailscaleIP =
    (
        & $tailscaleExe `
            ip `
            -4 `
            2>$null
    ) |
    Select-Object -First 1

Write-Host ''
Write-Host '============================================================'
Write-Host ' SERVER BOOTSTRAP COMPLETE'
Write-Host '============================================================'

Write-Host "OS:             Windows"
Write-Host "SSH user:       $TargetUser"
Write-Host "Tailscale IPv4: $tailscaleIP"

Write-Host ''
Write-Host 'Tailscale status:'

& $tailscaleExe status

Write-Host ''
Write-Host 'Connect from another tailnet machine with:'
Write-Host ''

Write-Host "  ssh $TargetUser@$tailscaleIP"

Write-Host ''
Write-Host 'SSH password authentication is disabled.'
Write-Host 'The team SSH key is restricted to Tailscale addresses.'
